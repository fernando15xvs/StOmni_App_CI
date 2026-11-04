-- 2D-D: support financial NC preview/finalization ONLY for version-2 schedules
-- certified by 2D-C bank down-payment reversal. Does not issue fiscal documents
-- or validate bank evidence; those remain separate, blocked workflows.
-- Keep original NC monetary transition and compensating change journaling.
CREATE OR REPLACE FUNCTION private.financial_nc_apply_transition()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
 SET "TimeZone" TO 'UTC'
AS $function$
DECLARE
 a public.venta_cuentas_financieras%ROWTYPE;
 old_amount numeric; new_amount numeric; delta numeric; prior numeric;
 op uuid; ev uuid; origin uuid; seq bigint; remaining numeric; piece numeric; release numeric;
 schedule uuid; q record; change record; audit record;
 e numeric; c numeric; d numeric; f numeric; due numeric;
BEGIN
 SELECT * INTO a FROM public.venta_cuentas_financieras
 WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id FOR UPDATE;
 IF NOT FOUND THEN RETURN NEW; END IF;
 IF NOT EXISTS(SELECT 1 FROM private.financial_nc_intents i WHERE i.organization_id=NEW.organization_id
 AND i.venta_id=NEW.venta_id AND i.nota_credito_id=NEW.id AND i.tx_id=pg_catalog.pg_current_xact_id()) THEN
 RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Missing fiscal transaction intent'; END IF;
 old_amount:=CASE WHEN OLD.estado='aceptado' AND OLD.afecta_dinero AND OLD.estado_baja_tributaria<>'aceptada' THEN OLD.total ELSE 0 END;
 new_amount:=CASE WHEN NEW.estado='aceptado' AND NEW.afecta_dinero AND NEW.estado_baja_tributaria<>'aceptada' THEN NEW.total ELSE 0 END;
 delta:=old_amount-new_amount;
 IF delta=0 THEN RETURN NEW; END IF;
 IF NEW.moneda<>'PEN' OR a.moneda<>'PEN' OR a.estado_conciliacion<>'conciliada'
 OR NEW.total<=0 OR NEW.total>999999999999.99 OR NEW.total<>round(NEW.total,2)
 OR NEW.aceptado_at IS NULL OR NOT isfinite(NEW.aceptado_at) OR NEW.aceptado_at>clock_timestamp()
 OR (delta>0 AND (NEW.baja_aceptada_at IS NULL OR NOT isfinite(NEW.baja_aceptada_at) OR NEW.baja_aceptada_at<NEW.aceptado_at OR NEW.baja_aceptada_at>clock_timestamp())) THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Unreconciled fiscal transition'; END IF;
 SELECT coalesce(sum(delta_exigible),0) INTO prior FROM public.venta_eventos_financieros
 WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id AND nota_credito_id=NEW.id;
 IF prior IS DISTINCT FROM -old_amount THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Credit note history not reconciled'; END IF;
 SELECT * INTO audit FROM private.financial_2c_audit_sale(NEW.organization_id,NEW.venta_id);
 IF cardinality(array_remove(audit.bloqueos,'nc_pendiente_motor_canonico'))<>0 THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Account failed pre-transition audit'; END IF;
 e:=a.exigible+delta; c:=a.cobros_netos; d:=greatest(e-c,0); f:=greatest(c-e,0);
 IF e<0 THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Credit notes exceed original obligation'; END IF;
 SELECT id INTO schedule FROM public.venta_cronogramas WHERE organization_id=NEW.organization_id
 AND venta_id=NEW.venta_id AND estado='vigente' FOR UPDATE;
 IF schedule IS NOT NULL AND (
   SELECT CASE WHEN cr.version=1 THEN false
               WHEN cr.version=2 THEN
                 private.financial_2dc_supported_v2_schedule(NEW.organization_id,NEW.venta_id,cr.id) IS NOT TRUE
               ELSE true END
   FROM public.venta_cronogramas cr
   WHERE cr.id=schedule AND cr.organization_id=NEW.organization_id AND cr.venta_id=NEW.venta_id
 ) THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Credit note requires original v1 or provenance-certified v2 schedule';
 END IF;
 IF schedule IS NULL AND EXISTS(SELECT 1 FROM public.venta_cronogramas WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id) THEN
 RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Unsupported schedule version'; END IF;
 IF schedule IS NOT NULL THEN
 IF EXISTS(SELECT 1 FROM public.venta_cuotas cq WHERE cq.organization_id=NEW.organization_id AND cq.venta_id=NEW.venta_id AND cq.cronograma_id=schedule AND (cq.es_legado OR cq.vencimiento IS NULL))
 OR (SELECT sum(importe_vigente) FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL)) IS DISTINCT FROM a.exigible
 OR EXISTS(SELECT 1 FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL) iq WHERE iq.importe_cobrado<0 OR iq.saldo_pendiente<0)
 THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Invalid schedule obligations'; END IF;
 SELECT sum(saldo_pendiente) INTO due FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL);
 IF due IS DISTINCT FROM a.saldo_pendiente THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Installments fail reconciliation'; END IF;
 END IF;
 SELECT coalesce(max(secuencia),0)+1 INTO seq FROM public.venta_eventos_financieros
 WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id;
 IF delta>0 THEN SELECT id INTO origin FROM public.venta_eventos_financieros WHERE organization_id=NEW.organization_id
 AND venta_id=NEW.venta_id AND nota_credito_id=NEW.id AND tipo='nota_credito';
 IF origin IS NULL THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Missing original adjustment'; END IF; END IF;
 INSERT INTO public.venta_operaciones_financieras(organization_id,venta_id,tipo,request_id,payload_hash,resultado)
 VALUES(NEW.organization_id,NEW.venta_id,CASE WHEN delta<0 THEN 'nota_credito' ELSE 'reversion_ajuste' END,
 NEW.id,md5(NEW.id::text||':'||delta::text),'aplicado') RETURNING id INTO op;
 INSERT INTO public.venta_eventos_financieros(organization_id,venta_id,operacion_id,secuencia,tipo,delta_exigible,delta_cobros,efectivo_at,nota_credito_id,reversa_evento_id)
 VALUES(NEW.organization_id,NEW.venta_id,op,seq,CASE WHEN delta<0 THEN 'nota_credito' ELSE 'reversion_ajuste' END,
 delta,0,CASE WHEN delta<0 THEN NEW.aceptado_at ELSE coalesce(NEW.baja_aceptada_at,now()) END,NEW.id,origin) RETURNING id INTO ev;
 IF schedule IS NOT NULL AND delta<0 THEN
 remaining:=-delta;
 -- First unpaid balances, then paid allocations, in reverse due-date order.
 FOR q IN SELECT * FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL)
 ORDER BY vencimiento DESC,numero DESC LOOP
 IF q.saldo_pendiente<0 OR q.importe_cobrado<0 THEN RAISE EXCEPTION 'Invalid installment'; END IF;
 piece:=least(remaining,q.saldo_pendiente);
 IF piece>0 THEN
 UPDATE public.venta_cuotas SET importe_vigente=importe_vigente-piece WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id AND id=q.cuota_id;
 INSERT INTO private.financial_nc_quota_changes VALUES(NEW.organization_id,NEW.venta_id,ev,q.cuota_id,'pendiente',piece,0);
 remaining:=remaining-piece; END IF;
 END LOOP;
 FOR q IN SELECT * FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL)
 ORDER BY vencimiento DESC,numero DESC LOOP
 piece:=least(remaining,q.importe_cobrado);
 IF piece>0 THEN
 UPDATE public.venta_cuotas SET importe_vigente=importe_vigente-piece WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id AND id=q.cuota_id;
 -- A quota used in the unpaid pass cannot be used here unless it is now fully paid;
 -- combine records before insertion by retaining separate event-level reduction rows.
 INSERT INTO public.venta_cuota_movimientos(organization_id,venta_id,cuota_id,evento_id,tipo,importe_asignado)
 VALUES(NEW.organization_id,NEW.venta_id,q.cuota_id,ev,'liberacion_nc',-piece);
 INSERT INTO private.financial_nc_quota_changes VALUES(NEW.organization_id,NEW.venta_id,ev,q.cuota_id,'liberado',piece,piece);
 remaining:=remaining-piece; END IF;
 END LOOP;
 IF remaining<>0 THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='NC exceeds scheduled obligations'; END IF;
 ELSIF schedule IS NOT NULL AND delta>0 THEN
 FOR change IN SELECT * FROM private.financial_nc_quota_changes WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id AND evento_id=origin LOOP
 UPDATE public.venta_cuotas SET importe_vigente=importe_vigente+change.reduccion WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id AND id=change.cuota_id;
 END LOOP;
 -- A later NC may have released more cash. Reassign the currently available
 -- collected money, not a stale snapshot of allocations from this NC.
 SELECT least(c,e)-coalesce(sum(importe_cobrado),0) INTO remaining
 FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL);
 IF remaining<0 THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Invalid compensated allocations'; END IF;
 FOR q IN SELECT * FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL)
 ORDER BY vencimiento,numero LOOP
 piece:=least(remaining,q.saldo_pendiente);
 IF piece>0 THEN
 INSERT INTO public.venta_cuota_movimientos(organization_id,venta_id,cuota_id,evento_id,tipo,importe_asignado)
 VALUES(NEW.organization_id,NEW.venta_id,q.cuota_id,ev,'ajuste',piece);
 remaining:=remaining-piece;
 END IF; END LOOP;
 IF remaining<>0 THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Incomplete compensated allocations'; END IF;
 END IF;
 UPDATE public.venta_cuentas_financieras SET exigible=e,saldo_pendiente=d,excedente=f,revision=revision+1,actualizado_at=clock_timestamp()
 WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id;
 UPDATE private.financial_nc_intents SET etapa='ledger' WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id AND nota_credito_id=NEW.id AND tx_id=pg_catalog.pg_current_xact_id();
 UPDATE public.ventas SET saldo=d,estado=CASE WHEN d=0 THEN 'pagado' ELSE 'pendiente' END WHERE organization_id=NEW.organization_id AND id=NEW.venta_id;
 UPDATE private.financial_nc_intents SET etapa='fiscal' WHERE organization_id=NEW.organization_id AND venta_id=NEW.venta_id AND nota_credito_id=NEW.id AND tx_id=pg_catalog.pg_current_xact_id();
 IF schedule IS NOT NULL THEN
 SELECT sum(saldo_pendiente) INTO due FROM private.financial_2c4_installments(NEW.organization_id,NEW.venta_id,NULL);
 IF due IS DISTINCT FROM d THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Post-transition installments mismatch'; END IF;
 END IF;
 SELECT * INTO audit FROM private.financial_2c_audit_sale(NEW.organization_id,NEW.venta_id);
 IF cardinality(array_remove(audit.bloqueos,'nc_pendiente_motor_canonico'))<>0 THEN RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Post-transition canonical audit failed'; END IF;
 RETURN NEW;
END $function$;

CREATE OR REPLACE FUNCTION private.financial_2c6a_preview_credit_note(p_organization_id uuid, p_venta_id bigint, p_nota_credito_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
 SET "TimeZone" TO 'UTC'
AS $function$
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
   IF (v_schedule.version=1 AND EXISTS (
     SELECT 1 FROM public.venta_cronogramas cr
     WHERE cr.organization_id=p_organization_id AND cr.venta_id=p_venta_id
       AND cr.id<>v_schedule.id
   )) OR (v_schedule.version=2 AND
     private.financial_2dc_supported_v2_schedule(
       p_organization_id,p_venta_id,v_schedule.id) IS NOT TRUE)
   OR v_schedule.version NOT IN (1,2) THEN
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
$function$;

-- Fail closed for NULL permissions in the existing SECURITY DEFINER sale RPC.
-- Preserve all other invariants and existing grants; no elevated permissions.
CREATE OR REPLACE FUNCTION public.process_sale_credit_v5(p_request_id uuid, p_cliente_id bigint, p_total numeric, p_fecha timestamp with time zone, p_es_credito boolean, p_monto_abono numeric, p_detalles jsonb, p_pagos jsonb, p_cotizacion_id bigint, p_vendedor_id bigint, p_tipo_comprobante text, p_descuento_global_porcentaje numeric, p_descuento_global_monto numeric, p_motivo_descuento text, p_subtotal_bruto numeric, p_descuento_autorizado_por bigint, p_credit_terms jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET "TimeZone" TO 'UTC'
AS $function$
DECLARE
 v_org uuid; v_actor uuid:=auth.uid(); v_sale bigint; v_sale_row public.ventas%ROWTYPE;
 v_due numeric; v_paid numeric; v_count integer; v_fingerprint text; v_open public.venta_operaciones_financieras%ROWTYPE;
 v_result jsonb; v_op uuid; v_event uuid; v_schedule uuid; v_seq bigint:=1;
 v_payment record; v_term jsonb; v_configured boolean:=false; v_audit record;
BEGIN
 IF v_actor IS NULL OR public.app_tiene_permiso('sales.create') IS NOT TRUE THEN
  RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Authorized seller required';
 END IF;
 v_org:=private.require_current_organization_id();
 IF v_org IS NULL OR private.current_organization_id() IS DISTINCT FROM v_org
    OR p_request_id IS NULL OR p_es_credito IS DISTINCT FROM true
    OR lower(btrim(coalesce(p_tipo_comprobante,''))) NOT IN ('ticket_interno','ticket') THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Credit v5 requires tenant, request and internal ticket; electronic credit is not enabled';
 END IF;
 -- Enforce exact fractions before the legacy engine can round the financial inputs.
 v_due:=private.financial_2d_validate_terms(p_fecha,p_total,p_monto_abono,p_pagos,p_credit_terms);
 IF p_detalles IS NULL OR jsonb_typeof(p_detalles)<>'array' OR jsonb_array_length(p_detalles)=0 THEN
  RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Sale lines required';
 END IF;
 v_fingerprint:=encode(extensions.digest(jsonb_build_object(
  'org',v_org,'actor',v_actor,'request',p_request_id,'customer',p_cliente_id,
  'total',p_total,'date',p_fecha,'credit',p_es_credito,'down',p_monto_abono,
  'details',p_detalles,'payments',p_pagos,'terms',p_credit_terms,
  'quotation',p_cotizacion_id,'seller',p_vendedor_id,'document','ticket_interno',
  'discount_pct',p_descuento_global_porcentaje,'discount_amount',p_descuento_global_monto,
  'discount_reason',p_motivo_descuento,'gross_subtotal',p_subtotal_bruto,
  'discount_authorizer',p_descuento_autorizado_por
 )::text,'sha256'),'hex');

 -- Acquire the same request lock as process_sale_v3 to prevent two sale creations.
 PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text,0));
 SELECT id INTO v_sale FROM public.ventas WHERE organization_id=v_org AND request_id=p_request_id;
 IF FOUND THEN
  SELECT * INTO v_open FROM public.venta_operaciones_financieras
   WHERE organization_id=v_org AND venta_id=v_sale AND tipo='apertura'
   AND request_id=p_request_id AND resultado='aplicado';
  IF NOT FOUND OR v_open.payload_hash<>v_fingerprint OR v_open.resultado_payload IS NULL THEN
   RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='Sale request is already used or credit terms differ';
  END IF;
  RETURN v_open.resultado_payload||jsonb_build_object('idempotent',true);
 END IF;

 SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(p_detalles) d
   WHERE d ? 'unit_profile_revision') INTO v_configured;
 IF v_configured THEN
  v_result:=public.process_sale_with_units_v4(
   p_request_id,p_cliente_id,p_total,p_fecha,true,p_monto_abono,p_detalles,p_pagos,
   p_cotizacion_id,p_vendedor_id,'ticket_interno',
   p_descuento_global_porcentaje,p_descuento_global_monto,
   p_motivo_descuento,p_subtotal_bruto,p_descuento_autorizado_por);
 ELSE
  v_result:=public.process_sale_v4(
   p_request_id,p_cliente_id,p_total,p_fecha,true,p_monto_abono,p_detalles,p_pagos,
   p_cotizacion_id,p_vendedor_id,'ticket_interno',
   p_descuento_global_porcentaje,p_descuento_global_monto,
   p_motivo_descuento,p_subtotal_bruto,p_descuento_autorizado_por);
 END IF;
 IF v_result->>'success'<>'true' OR v_result->>'idempotent'<>'false'
    OR v_result->>'venta_id' IS NULL THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Unexpected sale writer result; sale rolled back';
 END IF;
 v_sale:=(v_result->>'venta_id')::bigint;
 SELECT * INTO v_sale_row FROM public.ventas
  WHERE organization_id=v_org AND id=v_sale AND request_id=p_request_id FOR UPDATE;
 IF NOT FOUND OR v_sale_row.total IS DISTINCT FROM p_total
    OR v_sale_row.saldo IS DISTINCT FROM v_due THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Sale engine amount diverged from exact credit contract';
 END IF;
 -- Legacy v3 stores the outstanding balance but does not set fue_credito.
 -- Preserve existing UI, aging and reports semantics for the new v5 credit sale.
 UPDATE public.ventas SET fue_credito=true
 WHERE organization_id=v_org AND id=v_sale;
 SELECT coalesce(sum(monto),0),count(*) INTO v_paid,v_count FROM public.pagos_venta
  WHERE organization_id=v_org AND venta_id=v_sale;
 IF v_paid<>p_monto_abono OR v_count<>jsonb_array_length(p_pagos)
    OR EXISTS(SELECT 1 FROM public.venta_cuentas_financieras
      WHERE organization_id=v_org AND venta_id=v_sale) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Sale payment amounts or financial identity inconsistent';
 END IF;

 INSERT INTO public.venta_cuentas_financieras
  (organization_id,venta_id,moneda,estado_conciliacion,
   exigible,cobros_netos,saldo_pendiente,excedente,revision)
 VALUES(v_org,v_sale,'PEN','conciliada',p_total,v_paid,v_due,0,1);
 INSERT INTO public.venta_operaciones_financieras
  (organization_id,venta_id,tipo,request_id,actor_id,payload_hash,resultado,metadata_apertura)
 VALUES(v_org,v_sale,'apertura',p_request_id,v_actor,v_fingerprint,'aplicado',
  jsonb_build_object('cobertura','historico_auditado','origen','venta_credito_v5'))
 RETURNING id INTO v_op;
 INSERT INTO public.venta_eventos_financieros
  (organization_id,venta_id,operacion_id,secuencia,tipo,delta_exigible,delta_cobros,efectivo_at)
 VALUES(v_org,v_sale,v_op,v_seq,'apertura',p_total,0,p_fecha) RETURNING id INTO v_event;

 FOR v_payment IN
  SELECT id,monto,fecha FROM public.pagos_venta
  WHERE organization_id=v_org AND venta_id=v_sale ORDER BY id
 LOOP
  v_seq:=v_seq+1;
  INSERT INTO public.venta_eventos_financieros
   (organization_id,venta_id,operacion_id,secuencia,tipo,delta_exigible,delta_cobros,efectivo_at,pago_id)
  VALUES(v_org,v_sale,v_op,v_seq,'cobro',0,v_payment.monto,
    coalesce(v_payment.fecha,p_fecha),v_payment.id);
 END LOOP;
 INSERT INTO public.venta_cronogramas
  (organization_id,venta_id,version,estado,origen_evento_id,creado_por)
 VALUES(v_org,v_sale,1,'vigente',v_event,v_actor) RETURNING id INTO v_schedule;
 FOR v_term IN SELECT value FROM jsonb_array_elements(p_credit_terms) LOOP
  INSERT INTO public.venta_cuotas
   (organization_id,venta_id,cronograma_id,numero,vencimiento,
    es_legado,importe_original,importe_vigente)
  VALUES(v_org,v_sale,v_schedule,(v_term->>'number')::integer,
    (v_term->>'due_date')::date,false,(v_term->>'amount')::numeric,(v_term->>'amount')::numeric);
 END LOOP;
 SELECT * INTO v_audit FROM private.financial_2c_audit_sale(v_org,v_sale);
 IF v_audit.apta_para_motor IS DISTINCT FROM true THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Credit sale financial audit failed; all writes rolled back',
    DETAIL=array_to_string(v_audit.bloqueos,',');
 END IF;
 v_result:=v_result||jsonb_build_object('credit_schedule_id',v_schedule,'credit_schedule_version',1,
   'currency','PEN','balance',v_due,'initial_payment',v_paid);
 UPDATE public.venta_operaciones_financieras
  SET resultado_payload=v_result WHERE id=v_op AND organization_id=v_org AND venta_id=v_sale;
 RETURN v_result;
END $function$;
