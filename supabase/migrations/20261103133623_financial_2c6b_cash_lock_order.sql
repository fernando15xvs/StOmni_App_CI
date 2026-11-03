-- 2C3B-2: escritor interno, efectivo en PEN con contexto JWT de empleado
-- y sesion bloqueada. No exponer a anon/authenticated/service_role ni UI.
CREATE OR REPLACE FUNCTION private.financial_2c3b_record_cash_payment(
 p_organization_id uuid,
 p_venta_id bigint,
 p_request_id uuid,
 p_cash_session_id uuid,
 p_monto numeric,
 p_fecha timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path=''
SET "TimeZone"='UTC'
AS $writer$
DECLARE
 v_actor uuid := auth.uid();
 v_account public.venta_cuentas_financieras%ROWTYPE;
 v_sale public.ventas%ROWTYPE;
 v_session public.sesiones_caja%ROWTYPE;
 v_register public.cash_registers%ROWTYPE;
 v_existing public.venta_operaciones_financieras%ROWTYPE;
 v_check record;
 v_op_id uuid;
 v_payment record;
 v_secuencia bigint;
 v_balance numeric(14,2);
 v_now timestamptz := clock_timestamp();
 v_payload text;
 v_hash text;
 v_result jsonb;
BEGIN
 IF p_organization_id IS NULL OR p_venta_id IS NULL
    OR p_request_id IS NULL OR p_cash_session_id IS NULL OR
    p_monto IS NULL OR p_fecha IS NULL OR v_actor IS NULL THEN
   RAISE EXCEPTION USING ERRCODE='22023',
     MESSAGE='Actor JWT y campos obligatorios requeridos para cobro en efectivo';
 END IF;
 IF p_monto<=0 OR p_monto<>round(p_monto,2) OR
    p_monto>999999999999.99 THEN
   RAISE EXCEPTION USING ERRCODE='22023',
     MESSAGE='Monto en efectivo debe ser positivo con centavos exactos';
 END IF;
 IF p_fecha>v_now THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Fecha de cobro futura';
 END IF;

 -- Un usuario sin membresia activa no puede cobrar ni mediante el rol admin.
 IF private.current_organization_id() IS DISTINCT FROM p_organization_id THEN
   RAISE EXCEPTION USING ERRCODE='42501',
     MESSAGE='Actor no pertenece a organizacion activa';
 END IF;

 -- La huella incorpora usuario, sesion y medio: nunca puede cambiar la caja
 -- de una solicitud repetida y la zona UTC evita falsos cambios por timezone.
 v_payload:=pg_catalog.jsonb_build_object(
   'organization_id',p_organization_id,'venta_id',p_venta_id,
   'request_id',p_request_id,'actor_id',v_actor,
   'cash_session_id',p_cash_session_id,'moneda','PEN',
   'metodo','efectivo','monto',p_monto::numeric(14,2),'fecha',p_fecha
 )::text;
 v_hash:=pg_catalog.encode(extensions.digest(v_payload,'sha256'),'hex');

 -- Serializa por organizacion+request con la MISMA clave que 2C2, de modo
 -- que una solicitud no pueda resultar cobrada como efectivo y transferencia.
 PERFORM pg_catalog.pg_advisory_xact_lock(
   pg_catalog.hashtextextended(
     p_organization_id::text||':financial-2c2:'||p_request_id::text,0
   )
 );

 SELECT op.* INTO v_existing
 FROM public.venta_operaciones_financieras op
 WHERE op.organization_id=p_organization_id
   AND op.tipo='cobro' AND op.request_id=p_request_id;

 IF FOUND THEN
   IF v_existing.venta_id IS DISTINCT FROM p_venta_id
      OR v_existing.actor_id IS DISTINCT FROM v_actor
      OR v_existing.payload_hash IS DISTINCT FROM v_hash
      OR v_existing.resultado<>'aplicado'
      OR v_existing.resultado_payload IS NULL THEN
     RAISE EXCEPTION USING ERRCODE='23505',
       MESSAGE='Solicitud ya usada con distinto cobro, actor o sesion';
   END IF;
   RETURN v_existing.resultado_payload || '{"idempotent":true}'::jsonb;
 END IF;

 -- 2C6B1: take the cash session before account/sale row locks.
 SELECT s.* INTO v_session
 FROM public.sesiones_caja s
 WHERE s.organization_id=p_organization_id
   AND s.id=p_cash_session_id
 FOR UPDATE;
 IF NOT FOUND OR v_session.estado<>'ABIERTA'
   OR v_session.fecha_cierre IS NOT NULL
   OR v_session.usuario_id IS DISTINCT FROM v_actor
   OR p_fecha<v_session.fecha_apertura THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Sesion de caja cerrada, ajena o fuera de fechas';
 END IF;

 SELECT cf.* INTO v_account
 FROM public.venta_cuentas_financieras cf
 WHERE cf.organization_id=p_organization_id AND cf.venta_id=p_venta_id
 FOR UPDATE;
 IF NOT FOUND THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cuenta financiera inexistente';
 END IF;

 SELECT v.* INTO v_sale
 FROM public.ventas v
 WHERE v.organization_id=p_organization_id AND v.id=p_venta_id
 FOR UPDATE;
 IF NOT FOUND OR v_sale.fecha IS NULL OR p_fecha<v_sale.fecha THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Venta inexistente o pago anterior a la venta';
 END IF;

 SELECT r.* INTO v_register
 FROM public.cash_registers r
 WHERE r.organization_id=p_organization_id
   AND r.id=v_session.cash_register_id
   AND r.branch_id=v_session.branch_id
 FOR SHARE;
 IF NOT FOUND OR v_register.status<>'active' THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Caja inactiva o no perteneciente a la sucursal';
 END IF;

 SELECT * INTO v_check
 FROM private.financial_2c3_cash_preflight(
   p_organization_id,p_venta_id,p_request_id,v_actor,
   p_cash_session_id,p_monto,p_fecha
 );
 IF NOT COALESCE(v_check.permitido,false)
    OR v_check.cash_register_id IS DISTINCT FROM v_session.cash_register_id THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Preflight de caja rechazado: '||COALESCE(v_check.codigo,'sin_resultado');
 END IF;
 v_balance:=v_check.saldo_despues::numeric(14,2);

 SELECT COALESCE(MAX(ev.secuencia),0)+1 INTO v_secuencia
 FROM public.venta_eventos_financieros ev
 WHERE ev.organization_id=p_organization_id AND ev.venta_id=p_venta_id;

 INSERT INTO public.venta_operaciones_financieras(
  organization_id,venta_id,tipo,request_id,actor_id,payload_hash,
  resultado,creado_at,actualizado_at
 ) VALUES (
  p_organization_id,p_venta_id,'cobro',p_request_id,v_actor,v_hash,
  'pendiente',v_now,v_now
 ) RETURNING id INTO v_op_id;

 INSERT INTO private.financial_2c2_write_intents(
  organization_id,venta_id,tx_id,operation_id,request_id,monto,
  metodo,fecha,saldo_despues,etapa,
  actor_id,cash_session_id,cash_register_id
 ) VALUES (
  p_organization_id,p_venta_id,pg_catalog.pg_current_xact_id(),
  v_op_id,p_request_id,p_monto,'efectivo',p_fecha,v_balance,
  'insert_payment',v_actor,v_session.id,v_session.cash_register_id
 );

 INSERT INTO public.pagos_venta(
  organization_id,venta_id,metodo,monto,fecha,request_id,
  cash_session_id,cash_register_id
 ) VALUES (
  p_organization_id,p_venta_id,'efectivo',p_monto,p_fecha,NULL,
  v_session.id,v_session.cash_register_id
 ) RETURNING id,monto,metodo,fecha,cash_session_id,cash_register_id INTO v_payment;

 IF v_payment.cash_session_id IS DISTINCT FROM v_session.id
    OR v_payment.cash_register_id IS DISTINCT FROM v_session.cash_register_id
    OR v_payment.monto IS DISTINCT FROM p_monto
    OR lower(btrim(v_payment.metodo))<>'efectivo'
    OR v_payment.fecha IS DISTINCT FROM p_fecha THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Trigger de caja altero origen esperado; rollback';
 END IF;

 INSERT INTO public.venta_eventos_financieros(
  organization_id,venta_id,operacion_id,secuencia,tipo,delta_exigible,
  delta_cobros,efectivo_at,registrado_at,pago_id
 ) VALUES (
  p_organization_id,p_venta_id,v_op_id,v_secuencia,'cobro',0,p_monto,
  p_fecha,v_now,v_payment.id
 );

 UPDATE public.venta_cuentas_financieras
 SET cobros_netos=cobros_netos+p_monto,saldo_pendiente=v_balance,
     excedente=0,revision=revision+1,actualizado_at=v_now
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id;

 UPDATE private.financial_2c2_write_intents
 SET etapa='update_sale',pago_id=v_payment.id
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id
   AND tx_id=pg_catalog.pg_current_xact_id();

 UPDATE public.ventas
 SET saldo=v_balance,
     estado=CASE WHEN v_balance=0 THEN 'pagado' ELSE 'pendiente' END
 WHERE organization_id=p_organization_id AND id=p_venta_id;

 IF NOT EXISTS (
  SELECT 1
  FROM private.financial_2c_audit_sale(p_organization_id,p_venta_id) a
  WHERE a.apta_para_motor AND a.saldo_calculado=v_balance
    AND a.revision=v_account.revision+1
 ) THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Cobro en efectivo no concilia al final: rollback';
 END IF;

 DELETE FROM private.financial_2c2_write_intents
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id
   AND tx_id=pg_catalog.pg_current_xact_id();

 v_result:=pg_catalog.jsonb_build_object(
   'success',true,'idempotent',false,'request_id',p_request_id,
   'venta_id',p_venta_id,'operacion_id',v_op_id,
   'pago_id',v_payment.id,'actor_id',v_actor,
   'cash_session_id',v_session.id,
   'cash_register_id',v_session.cash_register_id,
   'moneda','PEN','metodo','efectivo',
   'monto',p_monto::numeric(14,2),'fecha',p_fecha,
   'saldo',v_balance,'revision',v_account.revision+1
 );
 UPDATE public.venta_operaciones_financieras
 SET resultado='aplicado',resultado_payload=v_result,actualizado_at=clock_timestamp()
 WHERE organization_id=p_organization_id AND venta_id=p_venta_id
   AND id=v_op_id;
 RETURN v_result;
END;
$writer$;

REVOKE ALL ON FUNCTION private.financial_2c3b_record_cash_payment(
 uuid,bigint,uuid,uuid,numeric,timestamptz
) FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON FUNCTION private.financial_2c3b_record_cash_payment(
 uuid,bigint,uuid,uuid,numeric,timestamptz
) IS '2C3B: escritor interno de efectivo con identidad derivada de JWT y sesion bloqueada. No exponer antes de UI, cuotas y reversos.';
