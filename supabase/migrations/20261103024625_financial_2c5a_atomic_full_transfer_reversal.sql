-- 2C5A: cancelación contable completa de un cobro erróneo por TRANSFERENCIA.
-- No mueve efectivo; no es devolución. Pagos y movimientos antiguos se conservan.
CREATE FUNCTION private.financial_2c5a_reverse_transfer_payment(
 p_organization_id uuid,
 p_venta_id bigint,
 p_request_id uuid,
 p_original_event_id uuid,
 p_efectivo_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path=''
SET "TimeZone"='UTC'
AS $writer$
DECLARE
 v_account public.venta_cuentas_financieras%ROWTYPE;
 v_sale public.ventas%ROWTYPE;
 v_original public.venta_eventos_financieros%ROWTYPE;
 v_payment public.pagos_venta%ROWTYPE;
 v_existing public.venta_operaciones_financieras%ROWTYPE;
 v_schedule public.venta_cronogramas%ROWTYPE;
 v_op_id uuid;
 v_event_id uuid;
 v_secuencia bigint;
 v_saldo numeric(14,2);
 v_total_previous numeric:=0;
 v_total_reversed numeric:=0;
 v_movement record;
 v_check record;
 v_payload text;
 v_hash text;
 v_result jsonb;
 v_now timestamptz:=clock_timestamp();
BEGIN
 IF p_organization_id IS NULL OR p_venta_id IS NULL OR
    p_request_id IS NULL OR p_original_event_id IS NULL OR
    p_efectivo_at IS NULL THEN
   RAISE EXCEPTION USING ERRCODE='22023',
    MESSAGE='Reverso de transferencia requiere identificadores y fecha efectiva';
 END IF;
 IF p_efectivo_at>v_now THEN
   RAISE EXCEPTION USING ERRCODE='23514',
    MESSAGE='No se permiten reversos efectivos en el futuro';
 END IF;

 v_payload:=pg_catalog.jsonb_build_object(
   'organization_id',p_organization_id,'venta_id',p_venta_id,
   'original_event_id',p_original_event_id,
   'efectivo_at',p_efectivo_at,'tipo','reverso_transferencia_total'
 )::text;
 v_hash:=pg_catalog.encode(extensions.digest(v_payload,'sha256'),'hex');

 PERFORM pg_catalog.pg_advisory_xact_lock(
   pg_catalog.hashtextextended(
    p_organization_id::text||':financial-2c5a:'||p_request_id::text,0)
 );
 SELECT op.* INTO v_existing
 FROM public.venta_operaciones_financieras op
 WHERE op.organization_id=p_organization_id AND op.tipo='reverso'
   AND op.request_id=p_request_id;
 IF FOUND THEN
   IF v_existing.venta_id IS DISTINCT FROM p_venta_id
      OR v_existing.payload_hash IS DISTINCT FROM v_hash
      OR v_existing.resultado<>'aplicado'
      OR v_existing.resultado_payload IS NULL THEN
      RAISE EXCEPTION USING ERRCODE='23505',
        MESSAGE='Solicitud de reverso reutilizada con diferente contenido';
   END IF;
   RETURN v_existing.resultado_payload||'{"idempotent":true}'::jsonb;
 END IF;

 SELECT cf.* INTO v_account
 FROM public.venta_cuentas_financieras cf
 WHERE cf.organization_id=p_organization_id
   AND cf.venta_id=p_venta_id
 FOR UPDATE;
 IF NOT FOUND THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cuenta financiera inexistente para reverso';
 END IF;

 SELECT v.* INTO v_sale
 FROM public.ventas v
 WHERE v.organization_id=p_organization_id AND v.id=p_venta_id
 FOR UPDATE;
 IF NOT FOUND THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Venta inexistente para reverso';
 END IF;

 SELECT * INTO v_check
 FROM private.financial_2c_audit_sale(p_organization_id,p_venta_id);
 IF NOT COALESCE(v_check.apta_para_motor,false)
    OR v_account.moneda<>'PEN'
    OR v_account.excedente<>0
    OR v_account.estado_conciliacion<>'conciliada' THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cuenta con discrepancias o moneda no autorizada para reverso';
 END IF;

 SELECT ev.* INTO v_original
 FROM public.venta_eventos_financieros ev
 JOIN public.venta_operaciones_financieras op
   ON op.organization_id=ev.organization_id
   AND op.venta_id=ev.venta_id AND op.id=ev.operacion_id
 WHERE ev.organization_id=p_organization_id
   AND ev.venta_id=p_venta_id AND ev.id=p_original_event_id
   AND ev.tipo='cobro' AND ev.delta_exigible=0
   AND ev.delta_cobros>0 AND ev.pago_id IS NOT NULL
   AND op.tipo='cobro' AND op.resultado='aplicado'
 FOR UPDATE OF ev;
 IF NOT FOUND OR p_efectivo_at<v_original.efectivo_at THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cobro original inexistente o fecha de reverso anterior';
 END IF;

 SELECT pv.* INTO v_payment FROM public.pagos_venta pv
 WHERE pv.organization_id=p_organization_id
   AND pv.venta_id=p_venta_id AND pv.id=v_original.pago_id;
 IF NOT FOUND OR lower(btrim(v_payment.metodo))<>'transferencia'
   OR v_payment.cash_session_id IS NOT NULL
   OR v_payment.cash_register_id IS NOT NULL
   OR v_payment.monto<>v_original.delta_cobros
   OR v_payment.monto<>round(v_payment.monto,2) THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Solo se admite reverso íntegro de transferencia sin caja';
 END IF;

 IF EXISTS (
  SELECT 1 FROM public.venta_eventos_financieros rv
  WHERE rv.organization_id=p_organization_id
    AND rv.venta_id=p_venta_id AND rv.tipo='reverso'
    AND rv.reversa_evento_id=v_original.id
 ) THEN
   RAISE EXCEPTION USING ERRCODE='23505',
     MESSAGE='El cobro de transferencia ya tiene reverso';
 END IF;

 IF v_account.cobros_netos<v_payment.monto
    OR v_account.saldo_pendiente+v_payment.monto>999999999999.99 THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Reverso dejaría cobros negativos o saldo fuera de rango';
 END IF;
 v_saldo:=(v_account.saldo_pendiente+v_payment.monto)::numeric(14,2);

 -- Si la venta tuvo cuotas, el reverso deshace exactamente las
 -- asignaciones del pago original (no reordena pagos más recientes).
 SELECT cr.* INTO v_schedule
 FROM public.venta_cronogramas cr
 WHERE cr.organization_id=p_organization_id
   AND cr.venta_id=p_venta_id AND cr.estado='vigente'
 FOR UPDATE;
 IF FOUND AND v_schedule.version<>1 THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cronograma versionado requiere transferencia de asignaciones';
 END IF;
 IF NOT FOUND AND EXISTS (
   SELECT 1 FROM public.venta_cronogramas cr
   WHERE cr.organization_id=p_organization_id AND cr.venta_id=p_venta_id
 ) THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='No hay cronograma vigente para reverso';
 END IF;

 IF v_schedule.id IS NOT NULL THEN
   SELECT COALESCE(SUM(m.importe_asignado),0) INTO v_total_previous
   FROM public.venta_cuota_movimientos m
   JOIN public.venta_cuotas c
     ON c.organization_id=m.organization_id
    AND c.venta_id=m.venta_id AND c.id=m.cuota_id
   WHERE m.organization_id=p_organization_id
     AND m.venta_id=p_venta_id AND m.evento_id=v_original.id
     AND m.tipo='cobro' AND c.cronograma_id=v_schedule.id
     AND NOT EXISTS (
       SELECT 1 FROM public.venta_cuota_movimientos rm
       WHERE rm.organization_id=m.organization_id
         AND rm.venta_id=m.venta_id
         AND rm.tipo='reverso' AND rm.reversa_movimiento_id=m.id
     );
   IF v_total_previous<>v_payment.monto
      OR EXISTS (
       SELECT 1 FROM public.venta_cuota_movimientos m
       WHERE m.organization_id=p_organization_id
         AND m.venta_id=p_venta_id AND m.evento_id=v_original.id
         AND m.tipo<>'cobro'
      ) THEN
      RAISE EXCEPTION USING ERRCODE='23514',
        MESSAGE='Asignaciones del cobro original incompletas o ya revertidas';
   END IF;
 ELSIF EXISTS (
   SELECT 1 FROM public.venta_cuota_movimientos m
   WHERE m.organization_id=p_organization_id
     AND m.venta_id=p_venta_id AND m.evento_id=v_original.id
 ) THEN
   RAISE EXCEPTION USING ERRCODE='23514',
      MESSAGE='Cobro tiene asignaciones pero no cronograma vigente';
 END IF;

 SELECT COALESCE(MAX(ev.secuencia),0)+1 INTO v_secuencia
 FROM public.venta_eventos_financieros ev
 WHERE ev.organization_id=p_organization_id AND ev.venta_id=p_venta_id;

 INSERT INTO public.venta_operaciones_financieras(
  organization_id,venta_id,tipo,request_id,payload_hash,resultado,
  creado_at,actualizado_at
 ) VALUES (
  p_organization_id,p_venta_id,'reverso',p_request_id,v_hash,'pendiente',
  v_now,v_now
 ) RETURNING id INTO v_op_id;

 INSERT INTO private.financial_2c2_write_intents(
  organization_id,venta_id,tx_id,operation_id,request_id,monto,
  metodo,fecha,saldo_despues,etapa,pago_id
 ) VALUES (
  p_organization_id,p_venta_id,pg_catalog.pg_current_xact_id(),
  v_op_id,p_request_id,v_payment.monto,'reverso_transferencia',
  p_efectivo_at,v_saldo,'update_sale',v_payment.id
 );

 INSERT INTO public.venta_eventos_financieros(
  organization_id,venta_id,operacion_id,secuencia,tipo,
  delta_exigible,delta_cobros,efectivo_at,registrado_at,
  pago_id,reversa_evento_id
 ) VALUES (
  p_organization_id,p_venta_id,v_op_id,v_secuencia,'reverso',
  0,-v_payment.monto,p_efectivo_at,v_now,v_payment.id,v_original.id
 ) RETURNING id INTO v_event_id;

 IF v_schedule.id IS NOT NULL THEN
   FOR v_movement IN
     SELECT m.id,m.cuota_id,m.importe_asignado
     FROM public.venta_cuota_movimientos m
     JOIN public.venta_cuotas c
       ON c.organization_id=m.organization_id
      AND c.venta_id=m.venta_id AND c.id=m.cuota_id
     WHERE m.organization_id=p_organization_id
       AND m.venta_id=p_venta_id AND m.evento_id=v_original.id
       AND m.tipo='cobro' AND c.cronograma_id=v_schedule.id
     ORDER BY c.vencimiento DESC,c.numero DESC,m.id
   LOOP
     INSERT INTO public.venta_cuota_movimientos(
       organization_id,venta_id,cuota_id,evento_id,tipo,
       importe_asignado,reversa_movimiento_id
     ) VALUES (
       p_organization_id,p_venta_id,v_movement.cuota_id,v_event_id,
       'reverso',-v_movement.importe_asignado,v_movement.id
     );
     v_total_reversed:=v_total_reversed+v_movement.importe_asignado;
   END LOOP;
   IF v_total_reversed<>v_payment.monto THEN
     RAISE EXCEPTION USING ERRCODE='23514',
       MESSAGE='Movimientos de reverso no suman importe original';
   END IF;
 END IF;

 UPDATE public.venta_cuentas_financieras
 SET cobros_netos=cobros_netos-v_payment.monto,
     saldo_pendiente=v_saldo,revision=revision+1,
     actualizado_at=v_now
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id;

 UPDATE public.ventas
 SET saldo=v_saldo,estado='pendiente'
 WHERE organization_id=p_organization_id AND id=p_venta_id;

 IF NOT EXISTS(
   SELECT 1 FROM private.financial_2c_audit_sale(
     p_organization_id,p_venta_id) a
   WHERE a.apta_para_motor AND a.saldo_calculado=v_saldo
     AND a.revision=v_account.revision+1
 ) THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Reverso no concilia tras escritura';
 END IF;

 IF v_schedule.id IS NOT NULL AND (
   SELECT COALESCE(SUM(c.importe_vigente),0)
       -COALESCE(SUM((
          SELECT COALESCE(SUM(m.importe_asignado),0)
          FROM public.venta_cuota_movimientos m
          WHERE m.organization_id=c.organization_id
            AND m.venta_id=c.venta_id AND m.cuota_id=c.id
       )),0)
   FROM public.venta_cuotas c
   WHERE c.organization_id=p_organization_id
     AND c.venta_id=p_venta_id AND c.cronograma_id=v_schedule.id
 ) IS DISTINCT FROM v_saldo THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Reverso no concilia con saldo total de cuotas';
 END IF;

 DELETE FROM private.financial_2c2_write_intents
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id
   AND tx_id=pg_catalog.pg_current_xact_id();

 v_result:=pg_catalog.jsonb_build_object(
  'success',true,'idempotent',false,'request_id',p_request_id,
  'venta_id',p_venta_id,'operacion_id',v_op_id,
  'evento_reverso_id',v_event_id,
  'evento_original_id',v_original.id,
  'pago_id',v_payment.id,'metodo','transferencia',
  'tipo','reverso_total','moneda','PEN',
  'importe',v_payment.monto,'fecha',p_efectivo_at,
  'saldo',v_saldo,'revision',v_account.revision+1
 );

 UPDATE public.venta_operaciones_financieras
 SET resultado='aplicado',resultado_payload=v_result,
   actualizado_at=clock_timestamp()
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id
   AND id=v_op_id;

 RETURN v_result;
END;
$writer$;

REVOKE ALL ON FUNCTION private.financial_2c5a_reverse_transfer_payment(
 uuid,bigint,uuid,uuid,timestamptz
) FROM PUBLIC,anon,authenticated,service_role;
COMMENT ON FUNCTION private.financial_2c5a_reverse_transfer_payment(
 uuid,bigint,uuid,uuid,timestamptz
) IS '2C5A: reverso contable total de TRANSFERENCIA, solo interno. No mueve efectivo y no es devolución.';
