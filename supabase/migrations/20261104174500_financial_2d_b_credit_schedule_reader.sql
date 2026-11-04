-- 2D-B: tenant-safe credit schedule read. No new privileged client endpoint.
-- SECURITY INVOKER enforces existing tenant.read RLS on every joined table.
CREATE FUNCTION public.obtener_cronograma_credito_v1(p_venta_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY INVOKER
SET search_path=''
AS $fn$
DECLARE
 v_org uuid;
 v_sale_id bigint;
 v_account public.venta_cuentas_financieras%ROWTYPE;
 v_schedule public.venta_cronogramas%ROWTYPE;
 v_lines jsonb;
 v_line_sum numeric;
BEGIN
 IF p_venta_id IS NULL OR p_venta_id<=0 OR auth.uid() IS NULL
    OR private.has_permission('tenant.read') IS NOT TRUE THEN
  RETURN NULL;
 END IF;
 v_org:=private.require_current_organization_id();

 SELECT v.id INTO v_sale_id
 FROM public.ventas v
 WHERE v.organization_id=v_org AND v.id=p_venta_id AND v.fue_credito=true;
 IF NOT FOUND THEN RETURN NULL; END IF;

 SELECT cf.* INTO v_account
 FROM public.venta_cuentas_financieras cf
 WHERE cf.organization_id=v_org AND cf.venta_id=v_sale_id
   AND cf.estado_conciliacion='conciliada';
 IF NOT FOUND THEN RETURN NULL; END IF;

 SELECT cr.* INTO v_schedule
 FROM public.venta_cronogramas cr
 WHERE cr.organization_id=v_org AND cr.venta_id=v_sale_id AND cr.estado='vigente';
 IF NOT FOUND THEN RETURN NULL; END IF;

 -- All underlying tables have RLS. No caller-supplied organization identifier.
 WITH installment_rows AS (
   SELECT c.id,c.numero,c.vencimiento,c.importe_original,c.importe_vigente,
          COALESCE((SELECT SUM(m.importe_asignado)
                    FROM public.venta_cuota_movimientos m
                    WHERE m.organization_id=c.organization_id
                      AND m.venta_id=c.venta_id
                      AND m.cuota_id=c.id),0) AS paid
   FROM public.venta_cuotas c
   WHERE c.organization_id=v_org AND c.venta_id=v_sale_id
     AND c.cronograma_id=v_schedule.id
 ), normalized AS (
   SELECT i.*,i.importe_vigente-i.paid AS remaining
   FROM installment_rows i
 )
 SELECT COALESCE(jsonb_agg(jsonb_build_object(
   'id',i.id,'numero',i.numero,'vencimiento',i.vencimiento,
   'importe_original',i.importe_original,'importe_vigente',i.importe_vigente,
   'importe_cobrado',i.paid,'saldo_pendiente',i.remaining,
   'estado',CASE WHEN i.remaining=0 THEN 'pagada'
             WHEN i.paid>0 THEN 'parcial' ELSE 'pendiente' END,
   'vencida',i.remaining>0 AND i.vencimiento IS NOT NULL
       AND i.vencimiento<(now() AT TIME ZONE 'America/Lima')::date
 ) ORDER BY i.vencimiento NULLS LAST,i.numero),'[]'::jsonb),
 COALESCE(SUM(i.remaining),0)
 INTO v_lines,v_line_sum
 FROM normalized i;

 -- Do not silently serve a contradictory or empty credit schedule.
 IF jsonb_array_length(v_lines)=0 OR v_line_sum<>v_account.saldo_pendiente THEN
  RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Credit schedule is incomplete or not reconciled';
 END IF;
 RETURN jsonb_build_object(
   'venta_id',v_sale_id,'moneda',v_account.moneda,
   'exigible',v_account.exigible,'cobros_netos',v_account.cobros_netos,
   'saldo_pendiente',v_account.saldo_pendiente,
   'excedente',v_account.excedente,'revision',v_account.revision,
   'cronograma_id',v_schedule.id,'cronograma_version',v_schedule.version,
   'cuotas',v_lines
 );
END;
$fn$;

REVOKE ALL ON FUNCTION public.obtener_cronograma_credito_v1(bigint)
 FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.obtener_cronograma_credito_v1(bigint)
 TO authenticated;
COMMENT ON FUNCTION public.obtener_cronograma_credito_v1(bigint)
 IS '2D-B: lectura tenant-safe del cronograma vigente, sin datos de otros tenants y sin privilegio de escritura.';
