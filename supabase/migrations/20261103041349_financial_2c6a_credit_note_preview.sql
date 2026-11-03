-- 2C6A: snapshot-only analysis of the first monetary credit note.
-- Never authorizes a write, certifies history, reserves surplus or pays money.
CREATE FUNCTION private.financial_2c6a_preview_credit_note(
 p_organization_id uuid, p_venta_id bigint, p_nota_credito_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path=''
SET "TimeZone"='UTC'
AS $fn$
DECLARE
 v_nc public.notas_credito%ROWTYPE;
 v_sale public.ventas%ROWTYPE;
 v_audit record;
 v_schedule public.venta_cronogramas%ROWTYPE;
 v_quota record;
 v_blockers text[];
 v_count bigint;
 v_min integer;
 v_max integer;
 v_due numeric:=0;
 v_remaining numeric;
 v_piece numeric;
 v_e numeric;
 v_d numeric;
 v_f numeric;
 v_plan jsonb:='[]'::jsonb;
BEGIN
 IF p_organization_id IS NULL OR p_venta_id IS NULL OR p_nota_credito_id IS NULL
    OR auth.uid() IS NULL THEN
   RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Identidad JWT y origen NC requeridos';
 END IF;
 IF private.current_organization_id() IS DISTINCT FROM p_organization_id
    OR private.has_permission('tenant.admin') IS NOT TRUE THEN
   RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Requiere administrador activo de la empresa';
 END IF;
 SELECT nc.* INTO v_nc FROM public.notas_credito nc
 WHERE nc.organization_id=p_organization_id AND nc.venta_id=p_venta_id
   AND nc.id=p_nota_credito_id;
 IF NOT FOUND THEN
   RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='NC no pertenece a la venta y empresa';
 END IF;
 SELECT s.* INTO v_sale FROM public.ventas s
 WHERE s.organization_id=p_organization_id AND s.id=p_venta_id;
 IF NOT FOUND OR v_sale.estado NOT IN ('pendiente','pagado')
    OR v_sale.fecha IS NULL THEN
   RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Venta no elegible para preanalisis';
 END IF;
 IF v_nc.estado IS DISTINCT FROM 'aceptado' OR v_nc.afecta_dinero IS NOT TRUE
    OR v_nc.moneda IS DISTINCT FROM 'PEN'
    OR v_nc.estado_baja_tributaria IS DISTINCT FROM 'ninguna'
    OR v_nc.baja_aceptada_at IS NOT NULL
    OR v_nc.aceptado_at IS NULL OR NOT isfinite(v_nc.aceptado_at)
    OR v_nc.aceptado_at<v_sale.fecha OR v_nc.aceptado_at>now()
    OR v_nc.total IS NULL OR v_nc.total<=0 OR v_nc.total>999999999999.99
    OR v_nc.total<>round(v_nc.total,2) THEN
   RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='NC monetaria aceptada PEN sin baja requerida';
 END IF;
 -- This delivery analyzes only the first effective NC, before any adjustment.
 -- Never remove the NC guard from the shared audit or payment writers.
 IF EXISTS (
   SELECT 1 FROM public.notas_credito n
   WHERE n.organization_id=p_organization_id AND n.venta_id=p_venta_id
     AND n.id<>p_nota_credito_id AND n.afecta_dinero
     AND n.estado='aceptado'
 ) OR EXISTS (
   SELECT 1 FROM public.venta_eventos_financieros ev
   WHERE ev.organization_id=p_organization_id AND ev.venta_id=p_venta_id
     AND (ev.nota_credito_id IS NOT NULL
          OR ev.tipo NOT IN ('apertura','cobro','reverso'))
 ) THEN
   RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Ajustes previos o multiples NC requieren conciliacion';
 END IF;
 SELECT * INTO v_audit FROM private.financial_2c_audit_sale(p_organization_id,p_venta_id);
 v_blockers:=array_remove(v_audit.bloqueos,'nc_pendiente_motor_canonico');
 IF cardinality(v_blockers) IS DISTINCT FROM 0
    OR v_audit.moneda IS DISTINCT FROM 'PEN'
    OR v_audit.exigible_eventos IS DISTINCT FROM v_sale.total
    OR v_nc.total>v_audit.exigible_eventos THEN
   RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Historial no conciliado o NC supera exigible';
 END IF;
 v_e:=v_audit.exigible_eventos-v_nc.total;
 v_d:=greatest(v_e-v_audit.cobros_eventos,0);
 v_f:=greatest(v_audit.cobros_eventos-v_e,0);
 v_remaining:=least(v_nc.total,v_audit.saldo_calculado);
 SELECT cr.* INTO v_schedule FROM public.venta_cronogramas cr
 WHERE cr.organization_id=p_organization_id AND cr.venta_id=p_venta_id AND cr.estado='vigente';
 IF NOT FOUND THEN
   IF EXISTS(SELECT 1 FROM public.venta_cronogramas cr
      WHERE cr.organization_id=p_organization_id AND cr.venta_id=p_venta_id) THEN
     RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Cronograma sin version vigente';
   END IF;
 ELSE
   IF v_schedule.version<>1 OR EXISTS (
     SELECT 1 FROM public.venta_cronogramas cr
     WHERE cr.organization_id=p_organization_id AND cr.venta_id=p_venta_id
       AND cr.id<>v_schedule.id
   ) THEN
     RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Versionado de cuotas requiere conciliacion';
   END IF;
   SELECT count(*),min(c.numero),max(c.numero) INTO v_count,v_min,v_max
   FROM public.venta_cuotas c WHERE c.organization_id=p_organization_id
     AND c.venta_id=p_venta_id AND c.cronograma_id=v_schedule.id;
   IF v_count=0 OR v_min<>1 OR v_max<>v_count THEN
     RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Cronograma incompleto';
   END IF;
   -- Validate EVERY installment, including paid and unmodified installments.
   FOR v_quota IN
     SELECT c.*,coalesce(sum(m.importe_asignado),0) AS asignado
     FROM public.venta_cuotas c
     LEFT JOIN public.venta_cuota_movimientos m
       ON m.organization_id=c.organization_id AND m.venta_id=c.venta_id AND m.cuota_id=c.id
     WHERE c.organization_id=p_organization_id AND c.venta_id=p_venta_id
       AND c.cronograma_id=v_schedule.id
     GROUP BY c.id
     ORDER BY c.vencimiento DESC,c.numero DESC
   LOOP
     IF v_quota.es_legado OR v_quota.vencimiento IS NULL
        OR NOT isfinite(v_quota.vencimiento)
        OR v_quota.importe_vigente<=0
        OR v_quota.importe_vigente<>round(v_quota.importe_vigente,2)
        OR v_quota.asignado<0 OR v_quota.asignado>v_quota.importe_vigente THEN
       RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Cuota o asignacion inconsistente';
     END IF;
     v_due:=v_due+v_quota.importe_vigente-v_quota.asignado;
     v_piece:=least(v_remaining,v_quota.importe_vigente-v_quota.asignado);
     IF v_piece>0 THEN
       v_plan:=v_plan||jsonb_build_array(jsonb_build_object(
         'cuota_id',v_quota.id,'numero',v_quota.numero,'vencimiento',v_quota.vencimiento,
         'reduccion_pendiente',v_piece,
         'saldo_propuesto',v_quota.importe_vigente-v_quota.asignado-v_piece));
       v_remaining:=v_remaining-v_piece;
     END IF;
   END LOOP;
   IF v_due<>v_audit.saldo_calculado OR v_remaining<>0 THEN
     RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Cuotas no concilian con deuda canonica';
   END IF;
 END IF;
 RETURN jsonb_build_object(
   'estado','simulacion_sin_escrituras','venta_id',p_venta_id,'nota_credito_id',p_nota_credito_id,
   'moneda','PEN','revision_observada',v_audit.revision,
   'exigible_propuesto',v_e,'cobros_netos_sin_cambio',v_audit.cobros_eventos,
   'saldo_propuesto',v_d,'excedente_propuesto',v_f,
   'reduccion_deuda',least(v_nc.total,v_audit.saldo_calculado),
   'incremento_excedente',v_f-v_audit.excedente_calculado,
   'sin_cronograma',v_schedule.id IS NULL,'reducciones_cuotas',v_plan,
   'aplicado',false,'autoriza_escritura',false,'excedente_reservado',false,'dinero_entregado',false);
END;
$fn$;
REVOKE ALL ON FUNCTION private.financial_2c6a_preview_credit_note(uuid,bigint,uuid)
 FROM PUBLIC,anon,authenticated,service_role;
COMMENT ON FUNCTION private.financial_2c6a_preview_credit_note(uuid,bigint,uuid)
 IS '2C6A: simulacion privada STABLE de primera NC. Sin locks/escrituras/autorizacion; revalidar todo bajo bloqueo en futuro escritor.';
