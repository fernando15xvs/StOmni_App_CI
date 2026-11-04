-- 2D-C DEV-only internal reversal of v5 initial bank down-payment.
-- No public RPC. No real bank payout. The trusted backend must independently
-- verify any bank reversal before invoking this private bookkeeping operation.
-- Do not generally enable versioned schedules. Only a known second version
-- created by full reversal of a v5 opening transfer, with zero old allocations.
CREATE FUNCTION private.financial_2dc_supported_v2_schedule(
 p_org uuid,p_sale bigint,p_schedule uuid
) RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $helper$
 SELECT EXISTS (
  SELECT 1
  FROM public.venta_cronogramas current_v2
  JOIN public.venta_cronogramas old_v1
    ON old_v1.organization_id=current_v2.organization_id
   AND old_v1.venta_id=current_v2.venta_id
   AND old_v1.version=1 AND old_v1.estado='sustituido'
  JOIN public.venta_eventos_financieros r
    ON r.organization_id=current_v2.organization_id
   AND r.venta_id=current_v2.venta_id
   AND r.id=current_v2.origen_evento_id
   AND r.tipo='reverso' AND r.delta_cobros<0
  JOIN public.venta_operaciones_financieras op
    ON op.organization_id=r.organization_id
   AND op.venta_id=r.venta_id AND op.id=r.operacion_id
   AND op.tipo='reverso' AND op.resultado='aplicado'
   AND op.metadata_apertura->>'origen'='reverso_abono_inicial_v5'
  JOIN public.venta_eventos_financieros original
    ON original.organization_id=r.organization_id
   AND original.venta_id=r.venta_id AND original.id=r.reversa_evento_id
   AND original.tipo='cobro' AND original.pago_id=r.pago_id
  JOIN public.venta_operaciones_financieras opening
    ON opening.organization_id=original.organization_id
   AND opening.venta_id=original.venta_id AND opening.id=original.operacion_id
   AND opening.tipo='apertura'
   AND opening.metadata_apertura->>'origen'='venta_credito_v5'
  WHERE current_v2.organization_id=p_org AND current_v2.venta_id=p_sale
    AND current_v2.id=p_schedule
    AND current_v2.estado='vigente' AND current_v2.version=2
    AND NOT EXISTS (
      SELECT 1 FROM public.venta_cuota_movimientos m
      JOIN public.venta_cuotas c
        ON c.organization_id=m.organization_id AND c.venta_id=m.venta_id
       AND c.id=m.cuota_id
      WHERE c.organization_id=p_org AND c.venta_id=p_sale
        AND c.cronograma_id=old_v1.id
    )
 );
$helper$;
REVOKE ALL ON FUNCTION private.financial_2dc_supported_v2_schedule(uuid,bigint,uuid)
 FROM PUBLIC,anon,authenticated,service_role;


-- Internal-only accounting reversal. Must be called by trusted backend after
-- independently verifying bank reversal evidence; it never transfers money.
CREATE FUNCTION private.financial_2dc_reverse_initial_transfer(
 p_organization_id uuid,p_venta_id bigint,p_request_id uuid,
 p_original_event_id uuid,p_efectivo_at timestamptz,p_bank_reversal_ref text
) RETURNS jsonb LANGUAGE plpgsql SECURITY INVOKER
SET search_path='' SET "TimeZone"='UTC' AS $body$
DECLARE
 v_actor uuid:=auth.uid();
 v_account public.venta_cuentas_financieras%ROWTYPE;
 v_sale public.ventas%ROWTYPE;
 v_op public.venta_operaciones_financieras%ROWTYPE;
 v_open public.venta_operaciones_financieras%ROWTYPE;
 v_origin public.venta_eventos_financieros%ROWTYPE;
 v_payment public.pagos_venta%ROWTYPE;
 v_old public.venta_cronogramas%ROWTYPE;
 v_event uuid; v_new_id uuid; v_op_id uuid;
 v_hash text; v_result jsonb;
 v_count int; v_seq bigint; v_old_total numeric;
 v_last_date date; v_last_number int; v_after numeric;
 v_now timestamptz:=clock_timestamp();
BEGIN
 IF p_organization_id IS NULL OR p_venta_id IS NULL OR p_request_id IS NULL
    OR p_original_event_id IS NULL OR p_efectivo_at IS NULL
    OR p_bank_reversal_ref IS NULL
    OR p_bank_reversal_ref !~ '^[A-Za-z0-9._:/-]{8,120}$'
    OR p_efectivo_at>v_now THEN
   RAISE EXCEPTION USING ERRCODE='22023',
     MESSAGE='Reverso inicial requiere solicitud, fecha pasada y referencia bancaria segura';
 END IF;
 IF v_actor IS NULL
   OR private.require_current_organization_id() IS DISTINCT FROM p_organization_id
   OR public.app_tiene_permiso('sales.collect') IS NOT TRUE THEN
   RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Operador de cobros y organización válidos requeridos';
 END IF;
 v_hash:=pg_catalog.encode(extensions.digest(pg_catalog.jsonb_build_object(
   'org',p_organization_id,'sale',p_venta_id,'request',p_request_id,
   'original',p_original_event_id,'effective',p_efectivo_at,
   'evidence',p_bank_reversal_ref,'actor',v_actor,
   'reason','reversal_initial_v5'
 )::text,'sha256'),'hex');
 PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
   p_organization_id::text||':financial-2dc:'||p_request_id::text,0));
 SELECT * INTO v_op FROM public.venta_operaciones_financieras
 WHERE organization_id=p_organization_id AND tipo='reverso' AND request_id=p_request_id;
 IF FOUND THEN
  IF v_op.venta_id IS DISTINCT FROM p_venta_id
    OR v_op.payload_hash IS DISTINCT FROM v_hash
    OR v_op.resultado<>'aplicado' OR v_op.resultado_payload IS NULL THEN
   RAISE EXCEPTION USING ERRCODE='23505',MESSAGE='Identificador de reverso reutilizado con diferente contenido';
  END IF;
  RETURN v_op.resultado_payload||'{"idempotent":true}'::jsonb;
 END IF;

 SELECT * INTO v_account FROM public.venta_cuentas_financieras
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id FOR UPDATE;
 SELECT * INTO v_sale FROM public.ventas
 WHERE organization_id=p_organization_id AND id=p_venta_id FOR UPDATE;
 IF v_account.venta_id IS NULL OR v_sale.id IS NULL
    OR v_account.moneda<>'PEN' OR v_account.estado_conciliacion<>'conciliada'
    OR v_account.excedente<>0 OR v_sale.fue_credito IS NOT TRUE
    OR v_sale.total IS DISTINCT FROM v_account.exigible THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Venta o cuenta no elegible para reverso inicial';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM private.financial_2c_audit_sale(p_organization_id,p_venta_id)
   WHERE apta_para_motor) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Cuenta sin auditoría canónica';
 END IF;

 SELECT * INTO v_open FROM public.venta_operaciones_financieras
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id
   AND tipo='apertura' AND resultado='aplicado'
   AND metadata_apertura->>'origen'='venta_credito_v5' FOR UPDATE;
 IF NOT FOUND OR EXISTS (
    SELECT 1 FROM public.venta_operaciones_financieras op
    WHERE op.organization_id=p_organization_id AND op.venta_id=p_venta_id
      AND op.id<>v_open.id
 ) THEN
  RAISE EXCEPTION USING ERRCODE='23514',
    MESSAGE='Reverso inicial solo sin operaciones financieras posteriores';
 END IF;
 SELECT * INTO v_origin FROM public.venta_eventos_financieros
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id
   AND id=p_original_event_id AND operacion_id=v_open.id
   AND tipo='cobro' AND delta_exigible=0 AND delta_cobros>0
   AND pago_id IS NOT NULL FOR UPDATE;
 IF NOT FOUND OR p_efectivo_at<v_origin.efectivo_at THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Evento de anticipo no válido o fecha anterior';
 END IF;
 SELECT * INTO v_payment FROM public.pagos_venta
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id
   AND id=v_origin.pago_id;
 IF NOT FOUND OR lower(btrim(v_payment.metodo))<>'transferencia'
   OR v_payment.cash_register_id IS NOT NULL OR v_payment.cash_session_id IS NOT NULL
   OR v_payment.monto IS DISTINCT FROM v_origin.delta_cobros
   OR v_payment.monto<=0 OR v_payment.monto<>round(v_payment.monto,2)
   OR v_account.cobros_netos IS DISTINCT FROM v_payment.monto
   OR v_account.saldo_pendiente+v_payment.monto IS DISTINCT FROM v_account.exigible
   OR EXISTS(SELECT 1 FROM public.pagos_venta p
       WHERE p.organization_id=p_organization_id AND p.venta_id=p_venta_id
       AND p.id<>v_payment.id)
   OR EXISTS(SELECT 1 FROM public.venta_eventos_financieros ev
       WHERE ev.organization_id=p_organization_id AND ev.venta_id=p_venta_id
       AND ev.tipo='cobro' AND ev.id<>v_origin.id) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Solo anticipo inicial íntegro, único y bancario';
 END IF;
 SELECT * INTO v_old FROM public.venta_cronogramas
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id
   AND version=1 AND estado='vigente' FOR UPDATE;
 IF NOT FOUND OR EXISTS(SELECT 1 FROM public.venta_cronogramas
     WHERE organization_id=p_organization_id AND venta_id=p_venta_id
       AND id<>v_old.id) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Solo cronograma original v1 vigente';
 END IF;
 IF EXISTS (SELECT 1 FROM public.venta_cuota_movimientos m
     WHERE m.organization_id=p_organization_id AND m.venta_id=p_venta_id) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Cronograma con asignaciones no permite reverso inicial';
 END IF;
 SELECT COUNT(*),COALESCE(SUM(importe_vigente),0),MAX(numero),MAX(vencimiento)
 INTO v_count,v_old_total,v_last_number,v_last_date
 FROM public.venta_cuotas WHERE organization_id=p_organization_id
  AND venta_id=p_venta_id AND cronograma_id=v_old.id;
 IF v_count<1 OR v_count>119 OR v_old_total<>v_account.saldo_pendiente
   OR v_last_number<>v_count OR v_last_date IS NULL
   OR EXISTS(SELECT 1 FROM public.venta_cuotas
     WHERE organization_id=p_organization_id AND venta_id=p_venta_id
       AND cronograma_id=v_old.id
       AND (es_legado OR vencimiento IS NULL OR importe_vigente<=0
         OR importe_vigente<>round(importe_vigente,2))) THEN
   RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Cuotas originales no conciliadas';
 END IF;
 v_after:=v_account.saldo_pendiente+v_payment.monto;
 SELECT coalesce(max(secuencia),0)+1 INTO v_seq
 FROM public.venta_eventos_financieros
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id;
 INSERT INTO public.venta_operaciones_financieras(
   organization_id,venta_id,tipo,request_id,actor_id,payload_hash,
   resultado,metadata_apertura
 ) VALUES (
   p_organization_id,p_venta_id,'reverso',p_request_id,v_actor,v_hash,
   'pendiente',jsonb_build_object('origen','reverso_abono_inicial_v5',
      'referencia_bancaria',p_bank_reversal_ref)
 ) RETURNING id INTO v_op_id;

 INSERT INTO private.financial_2c2_write_intents(
   organization_id,venta_id,tx_id,operation_id,request_id,
   monto,metodo,fecha,saldo_despues,etapa,pago_id
 ) VALUES(
   p_organization_id,p_venta_id,pg_catalog.pg_current_xact_id(),
   v_op_id,p_request_id,v_payment.monto,'reverso_transferencia',
   p_efectivo_at,v_after,'update_sale',v_payment.id
 );
 INSERT INTO public.venta_eventos_financieros(
   organization_id,venta_id,operacion_id,secuencia,tipo,
   delta_exigible,delta_cobros,efectivo_at,pago_id,reversa_evento_id
 ) VALUES(
   p_organization_id,p_venta_id,v_op_id,v_seq,'reverso',
   0,-v_payment.monto,p_efectivo_at,v_payment.id,v_origin.id
 ) RETURNING id INTO v_event;

 UPDATE public.venta_cuentas_financieras
 SET cobros_netos=0,saldo_pendiente=v_after,revision=revision+1,
     actualizado_at=v_now
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id;
 UPDATE public.ventas SET saldo=v_after,estado='pendiente'
 WHERE organization_id=p_organization_id AND id=p_venta_id;

 UPDATE public.venta_cronogramas SET estado='sustituido' WHERE id=v_old.id
   AND organization_id=p_organization_id AND venta_id=p_venta_id;
 INSERT INTO public.venta_cronogramas(
  organization_id,venta_id,version,estado,origen_evento_id,creado_por
 ) VALUES(p_organization_id,p_venta_id,2,'vigente',v_event,v_actor)
 RETURNING id INTO v_new_id;
 INSERT INTO public.venta_cuotas(
  organization_id,venta_id,cronograma_id,numero,obligacion_id,
  vencimiento,es_legado,importe_original,importe_vigente
 )
 SELECT p_organization_id,p_venta_id,v_new_id,c.numero,c.obligacion_id,
     c.vencimiento,false,c.importe_original,c.importe_vigente
 FROM public.venta_cuotas c
 WHERE c.organization_id=p_organization_id AND c.venta_id=p_venta_id
   AND c.cronograma_id=v_old.id
 ORDER BY c.numero;
 INSERT INTO public.venta_cuotas(
   organization_id,venta_id,cronograma_id,numero,vencimiento,
   es_legado,importe_original,importe_vigente
 ) VALUES(p_organization_id,p_venta_id,v_new_id,v_last_number+1,v_last_date,
          false,v_payment.monto,v_payment.monto);

 IF (SELECT COALESCE(SUM(c.importe_vigente),0) FROM public.venta_cuotas c
    WHERE c.organization_id=p_organization_id AND c.venta_id=p_venta_id
      AND c.cronograma_id=v_new_id) IS DISTINCT FROM v_after
    OR NOT EXISTS(SELECT 1 FROM private.financial_2c_audit_sale(
         p_organization_id,p_venta_id) a WHERE a.apta_para_motor
         AND a.saldo_calculado=v_after AND a.revision=v_account.revision+1) THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Reverso y cronograma v2 no conciliaron';
 END IF;
 DELETE FROM private.financial_2c2_write_intents
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id
   AND tx_id=pg_catalog.pg_current_xact_id();
 v_result:=jsonb_build_object(
  'success',true,'idempotent',false,'venta_id',p_venta_id,
  'request_id',p_request_id,'original_event_id',v_origin.id,
  'reversal_event_id',v_event,'payment_id',v_payment.id,
  'bank_reversal_ref',p_bank_reversal_ref,
  'schedule_version',2,'schedule_id',v_new_id,
  'previous_schedule_id',v_old.id,'amount',v_payment.monto,
  'balance',v_after,'revision',v_account.revision+1
 );
 UPDATE public.venta_operaciones_financieras SET
  resultado='aplicado',resultado_payload=v_result,
  actualizado_at=v_now
 WHERE id=v_op_id AND organization_id=p_organization_id
   AND venta_id=p_venta_id;
 IF private.financial_2dc_supported_v2_schedule(p_organization_id,p_venta_id,v_new_id)
   IS NOT TRUE THEN
  RAISE EXCEPTION USING ERRCODE='23514',MESSAGE='Origen del nuevo cronograma no certificado';
 END IF;
 RETURN v_result;
END;
$body$;
REVOKE ALL ON FUNCTION private.financial_2dc_reverse_initial_transfer(uuid,bigint,uuid,uuid,timestamptz,text)
 FROM PUBLIC,anon,authenticated,service_role;


-- Extend existing collectors ONLY for provenance-certified v2 from 2D-C.
CREATE OR REPLACE FUNCTION private.financial_2c4_allocate_cash_receipt()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
 v_schedule public.venta_cronogramas%ROWTYPE;
 v_account public.venta_cuentas_financieras%ROWTYPE;
 v_intent private.financial_2c2_write_intents%ROWTYPE;
 v_count integer;
 v_bad_count integer;
 v_min_number integer;
 v_max_number integer;
 v_due numeric;
 v_applied numeric;
 v_remaining numeric;
 v_room numeric;
 v_piece numeric;
 v_total_assigned numeric := 0;
 v_previous numeric;
 v_quota record;
BEGIN
 IF NEW.tipo<>'cobro' THEN
   RETURN NEW;
 END IF;

 -- Una venta sin historial de cuotas NO recibe vencimientos ficticios.
 SELECT cr.* INTO v_schedule
 FROM public.venta_cronogramas cr
 WHERE cr.organization_id=NEW.organization_id
   AND cr.venta_id=NEW.venta_id
   AND cr.estado='vigente'
 FOR UPDATE;
 IF NOT FOUND THEN
   IF EXISTS (
     SELECT 1 FROM public.venta_cronogramas cr
     WHERE cr.organization_id=NEW.organization_id
       AND cr.venta_id=NEW.venta_id
   ) THEN
     RAISE EXCEPTION USING ERRCODE='23514',
       MESSAGE='Hay cronogramas anteriores pero ninguno vigente';
   END IF;
   RETURN NEW;
 END IF;

 -- La versión 2 requiere reasignaciones históricas explícitas no incluidas
 -- aún en 2C4: no recontar movimientos de versiones sustituidas.
 IF v_schedule.version<>1 AND NOT private.financial_2dc_supported_v2_schedule(NEW.organization_id,NEW.venta_id,v_schedule.id) THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cronograma versionado requiere transferencia de asignaciones';
 END IF;

 -- Un cobro con cuotas solo puede proceder de uno de los dos escritores
 -- internos, ya que ellos crean esta intención privada antes del evento.
 SELECT i.* INTO v_intent
 FROM private.financial_2c2_write_intents i
 WHERE i.organization_id=NEW.organization_id
   AND i.venta_id=NEW.venta_id
   AND i.tx_id=pg_catalog.pg_current_xact_id()
   AND i.operation_id=NEW.operacion_id
   AND i.pago_id IS NULL
   AND i.etapa='insert_payment';
 IF NOT FOUND OR v_intent.monto IS DISTINCT FROM NEW.delta_cobros
    OR NEW.delta_exigible<>0 OR NEW.pago_id IS NULL
    OR NEW.delta_cobros<=0 OR NEW.delta_cobros<>round(NEW.delta_cobros,2) THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Evento de cuota sin intención de cobro válida';
 END IF;

 SELECT cf.* INTO v_account
 FROM public.venta_cuentas_financieras cf
 WHERE cf.organization_id=NEW.organization_id
   AND cf.venta_id=NEW.venta_id
 FOR UPDATE;
 IF NOT FOUND OR v_account.moneda<>'PEN'
   OR v_account.estado_conciliacion<>'conciliada'
   OR NEW.delta_cobros>v_account.saldo_pendiente THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cuenta financiera no elegible para asignar cobro a cuotas';
 END IF;

 -- Suma de obligaciones pendientes = saldo canónico previo al cobro.
 -- Solo se admiten movimientos positivos de cobro hasta disponer de
 -- reversos y NC (fase posterior).
 SELECT COUNT(*),MIN(c.numero),MAX(c.numero),
        COALESCE(SUM(c.importe_vigente),0),
        COUNT(*) FILTER (
          WHERE c.es_legado OR c.vencimiento IS NULL
             OR c.importe_vigente<0
             OR c.importe_vigente<>round(c.importe_vigente,2)
        )
 INTO v_count,v_min_number,v_max_number,v_due,v_bad_count
 FROM public.venta_cuotas c
 WHERE c.organization_id=NEW.organization_id
   AND c.venta_id=NEW.venta_id
   AND c.cronograma_id=v_schedule.id;

 IF v_count=0 OR v_min_number<>1 OR v_max_number<>v_count
   OR v_bad_count>0 THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cronograma incompleto, legado o importes inválidos';
 END IF;

 SELECT COALESCE(SUM(m.importe_asignado),0) INTO v_applied
 FROM public.venta_cuota_movimientos m
 JOIN public.venta_cuotas c
   ON c.organization_id=m.organization_id
   AND c.venta_id=m.venta_id AND c.id=m.cuota_id
 WHERE c.organization_id=NEW.organization_id
   AND c.venta_id=NEW.venta_id AND c.cronograma_id=v_schedule.id;

 IF v_applied<0 OR v_applied<>round(v_applied,2)
    OR v_due-v_applied IS DISTINCT FROM v_account.saldo_pendiente THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Saldo de cuotas no coincide con deuda canónica anterior al cobro';
 END IF;

 v_remaining:=NEW.delta_cobros;
 FOR v_quota IN
  SELECT c.id,c.numero,c.vencimiento,c.importe_vigente,
         COALESCE((
           SELECT SUM(m.importe_asignado)
           FROM public.venta_cuota_movimientos m
           WHERE m.organization_id=c.organization_id
             AND m.venta_id=c.venta_id AND m.cuota_id=c.id
         ),0) as asignado
  FROM public.venta_cuotas c
  WHERE c.organization_id=NEW.organization_id
    AND c.venta_id=NEW.venta_id AND c.cronograma_id=v_schedule.id
  ORDER BY c.vencimiento,c.numero
 LOOP
   IF v_remaining=0 THEN EXIT; END IF;
   v_room:=v_quota.importe_vigente-v_quota.asignado;
   IF v_room<0 OR v_room<>round(v_room,2) THEN
     RAISE EXCEPTION USING ERRCODE='23514',
       MESSAGE='Cuota excede su obligación vigente';
   END IF;
   v_piece:=LEAST(v_remaining,v_room);
   IF v_piece>0 THEN
     INSERT INTO public.venta_cuota_movimientos(
       organization_id,venta_id,cuota_id,evento_id,tipo,importe_asignado
     ) VALUES(
       NEW.organization_id,NEW.venta_id,v_quota.id,NEW.id,'cobro',v_piece
     );
     v_remaining:=v_remaining-v_piece;
     v_total_assigned:=v_total_assigned+v_piece;
   END IF;
 END LOOP;

 IF v_remaining<>0 OR v_total_assigned<>NEW.delta_cobros THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Asignación incompleta de cobro, rollback de transacción';
 END IF;
 RETURN NEW;
END;
$function$
;
CREATE OR REPLACE FUNCTION private.financial_2c5a_reverse_transfer_payment(p_organization_id uuid, p_venta_id bigint, p_request_id uuid, p_original_event_id uuid, p_efectivo_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
 SET "TimeZone" TO 'UTC'
AS $function$
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
 IF FOUND AND v_schedule.version<>1 AND NOT private.financial_2dc_supported_v2_schedule(p_organization_id,p_venta_id,v_schedule.id) THEN
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
$function$;
