-- 2C2B: primer escritor canonico, restringido a transferencia bancaria.
-- SECURITY INVOKER, sin EXECUTE de clientes ni service_role. El flujo publico
-- de deudas y efectivo permanece intacto. No habilita NC, cuotas ni reversos.
CREATE FUNCTION private.financial_2c2_record_transfer_payment(
 p_organization_id uuid,
 p_venta_id bigint,
 p_request_id uuid,
 p_moneda text,
 p_monto numeric,
 p_fecha timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path=''
AS $writer$
DECLARE
  v_account public.venta_cuentas_financieras%ROWTYPE;
  v_sale public.ventas%ROWTYPE;
  v_existing public.venta_operaciones_financieras%ROWTYPE;
  v_check record;
  v_op_id uuid;
  v_payment_id bigint;
  v_secuencia bigint;
  v_balance numeric(14,2);
  v_now timestamptz:=clock_timestamp();
  v_payload text;
  v_hash text;
  v_result jsonb;
BEGIN
  IF p_organization_id IS NULL OR p_venta_id IS NULL
     OR p_request_id IS NULL OR p_moneda IS NULL OR p_fecha IS NULL
     OR p_monto IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023',
      MESSAGE='Datos obligatorios de cobro canonico incompletos';
  END IF;
  IF p_moneda !~ '^[A-Z]{3}$' OR p_monto<=0
     OR p_monto<>round(p_monto,2) OR p_monto>999999999999.99 THEN
    RAISE EXCEPTION USING ERRCODE='22023',
      MESSAGE='Moneda o monto fuera del contrato exacto en centavos';
  END IF;
  IF p_fecha>v_now THEN
    RAISE EXCEPTION USING ERRCODE='23514',
      MESSAGE='La fecha real de cobro no puede ser futura';
  END IF;

  v_payload:=pg_catalog.jsonb_build_object(
    'organization_id',p_organization_id,
    'venta_id',p_venta_id,
    'moneda',p_moneda,
    'monto',p_monto::numeric(14,2),
    'metodo','transferencia',
    'fecha',p_fecha
  )::text;
  v_hash:=pg_catalog.encode(extensions.digest(v_payload,'sha256'),'hex');

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      p_organization_id::text||':financial-2c2:'||p_request_id::text,0)
  );

  SELECT op.* INTO v_existing FROM public.venta_operaciones_financieras op
  WHERE op.organization_id=p_organization_id
    AND op.tipo='cobro' AND op.request_id=p_request_id;

  IF FOUND THEN
    IF v_existing.venta_id IS DISTINCT FROM p_venta_id
       OR v_existing.payload_hash IS DISTINCT FROM v_hash
       OR v_existing.resultado<>'aplicado'
       OR v_existing.resultado_payload IS NULL THEN
      RAISE EXCEPTION USING ERRCODE='23505',
        MESSAGE='request_id de cobro reutilizado o sin resultado confirmado';
    END IF;
    RETURN v_existing.resultado_payload||'{"idempotent":true}'::jsonb;
  END IF;

  SELECT cf.* INTO v_account
    FROM public.venta_cuentas_financieras cf
   WHERE cf.organization_id=p_organization_id AND cf.venta_id=p_venta_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='23514',
      MESSAGE='Venta sin cuenta financiera canonica';
  END IF;

  SELECT v.* INTO v_sale FROM public.ventas v
   WHERE v.organization_id=p_organization_id AND v.id=p_venta_id
   FOR UPDATE;
  IF NOT FOUND OR v_sale.fecha IS NULL OR p_fecha<v_sale.fecha THEN
    RAISE EXCEPTION USING ERRCODE='23514',
      MESSAGE='Cobro anterior a la venta o venta sin fecha verificable';
  END IF;

  SELECT * INTO v_check FROM private.financial_2c_preflight_payment(
    p_organization_id,p_venta_id,p_request_id,p_moneda,p_monto,
    'transferencia',p_fecha
  );
  IF NOT COALESCE(v_check.permitido,false) THEN
    RAISE EXCEPTION USING ERRCODE='23514',
      MESSAGE='Preflight no autorizado: '||COALESCE(v_check.codigo,'sin_resultado');
  END IF;

  v_balance:=v_check.saldo_despues::numeric(14,2);
  SELECT COALESCE(MAX(ev.secuencia),0)+1 INTO v_secuencia
    FROM public.venta_eventos_financieros ev
   WHERE ev.organization_id=p_organization_id AND ev.venta_id=p_venta_id;

  INSERT INTO public.venta_operaciones_financieras(
    organization_id,venta_id,tipo,request_id,payload_hash,
    resultado,creado_at,actualizado_at
  ) VALUES (
    p_organization_id,p_venta_id,'cobro',p_request_id,v_hash,
    'pendiente',v_now,v_now
  ) RETURNING id INTO v_op_id;

  INSERT INTO private.financial_2c2_write_intents(
    organization_id,venta_id,tx_id,operation_id,request_id,
    monto,metodo,fecha,saldo_despues,etapa
  ) VALUES (
    p_organization_id,p_venta_id,pg_catalog.pg_current_xact_id(),
    v_op_id,p_request_id,p_monto,'transferencia',p_fecha,
    v_balance,'insert_payment'
  );

  -- pagos_venta.request_id pertenece al circuito legacy de
  -- pagos_deuda_requests. La identidad canonica se mantiene en
  -- venta_operaciones_financieras -> venta_eventos_financieros -> pago_id.
  INSERT INTO public.pagos_venta(
    organization_id,venta_id,metodo,monto,fecha,request_id,
    cash_session_id,cash_register_id
  ) VALUES (
    p_organization_id,p_venta_id,'transferencia',p_monto,p_fecha,
    NULL,NULL,NULL
  ) RETURNING id INTO v_payment_id;

  INSERT INTO public.venta_eventos_financieros(
    organization_id,venta_id,operacion_id,secuencia,tipo,
    delta_exigible,delta_cobros,efectivo_at,registrado_at,pago_id
  ) VALUES (
    p_organization_id,p_venta_id,v_op_id,v_secuencia,'cobro',
    0,p_monto,p_fecha,v_now,v_payment_id
  );

  UPDATE public.venta_cuentas_financieras
     SET cobros_netos=cobros_netos+p_monto,
         saldo_pendiente=v_balance,
         excedente=0,revision=revision+1,actualizado_at=v_now
   WHERE organization_id=p_organization_id AND venta_id=p_venta_id;

  UPDATE private.financial_2c2_write_intents
     SET etapa='update_sale',pago_id=v_payment_id
   WHERE organization_id=p_organization_id AND venta_id=p_venta_id
     AND tx_id=pg_catalog.pg_current_xact_id();

  UPDATE public.ventas
     SET saldo=v_balance,
         estado=CASE WHEN v_balance=0 THEN 'pagado' ELSE 'pendiente' END
   WHERE organization_id=p_organization_id AND id=p_venta_id;

  IF NOT EXISTS (
    SELECT 1 FROM private.financial_2c_audit_sale(p_organization_id,p_venta_id) a
    WHERE a.apta_para_motor AND a.saldo_calculado=v_balance
      AND a.revision=v_account.revision+1
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23514',
      MESSAGE='Cobro canonico no concilia tras escritura; transaccion revertida';
  END IF;

  DELETE FROM private.financial_2c2_write_intents
   WHERE organization_id=p_organization_id AND venta_id=p_venta_id
     AND tx_id=pg_catalog.pg_current_xact_id();

  v_result:=pg_catalog.jsonb_build_object(
    'success',true,'idempotent',false,
    'request_id',p_request_id,'venta_id',p_venta_id,
    'operacion_id',v_op_id,'pago_id',v_payment_id,
    'moneda',p_moneda,'monto',p_monto::numeric(14,2),
    'metodo','transferencia','fecha',p_fecha,
    'saldo',v_balance,'revision',v_account.revision+1,
    'cash_session_id',NULL
  );
  UPDATE public.venta_operaciones_financieras
     SET resultado='aplicado',resultado_payload=v_result,
         actualizado_at=clock_timestamp()
   WHERE organization_id=p_organization_id AND venta_id=p_venta_id
     AND id=v_op_id;
  RETURN v_result;
END;
$writer$;

REVOKE ALL ON FUNCTION private.financial_2c2_record_transfer_payment(
 uuid,bigint,uuid,text,numeric,timestamptz
) FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON FUNCTION private.financial_2c2_record_transfer_payment(
 uuid,bigint,uuid,text,numeric,timestamptz
) IS '2C2 admin-only: cobro por transferencia atomico e idempotente. No se habilita cliente, caja, cuotas ni notas de credito.';
