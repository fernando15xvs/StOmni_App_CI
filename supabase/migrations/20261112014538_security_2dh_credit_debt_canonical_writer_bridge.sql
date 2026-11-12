-- 2D-H DEV: bridge debt-payment RPC to the audited financial 2C writers.
-- Canonical sales must not use legacy pagos_venta INSERT (55000).
-- For reconciled sales, preserve transaction-scoped request identity and
-- delegate bank transfer to private.financial_2c2_record_transfer_payment
-- or authenticated active cash session to private.financial_2c3b_record_cash_payment.
-- Reject other canonical methods explicitly; keep legacy sales and expense
-- paths unchanged, including tenant authorization and idempotent requests.
-- No extra EXECUTE grants: the helpers remain internal and RLS intact.
CREATE OR REPLACE FUNCTION public.procesar_pago_deuda_v2(p_request_id uuid, p_es_cliente boolean, p_deuda_id bigint, p_monto numeric, p_metodo text, p_fecha timestamp with time zone, p_descontar_de_caja boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_auth uuid := auth.uid();
  v_employee_id bigint;
  v_amount numeric(14,2):=round(COALESCE(p_monto,0),2);
  v_method text:=btrim(COALESCE(p_metodo,''));
  v_method_norm text:=lower(btrim(COALESCE(p_metodo,'')));
  v_date timestamptz:=COALESCE(p_fecha,now());
  v_is_cash boolean;
  v_affects_cash boolean;
  v_request public.pagos_deuda_requests%ROWTYPE;
  v_sale public.ventas%ROWTYPE;
  v_expense public.gastos%ROWTYPE;
  v_payment_id bigint;
  v_balance numeric(14,2);
  v_session_id uuid;
  v_cash_available numeric;
  v_result jsonb;
  v_account public.venta_cuentas_financieras%ROWTYPE;
  v_canonical jsonb;
BEGIN
  IF p_request_id IS NULL OR p_es_cliente IS NULL OR p_deuda_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='request_id, debt type and debt id are required';
  END IF;
  IF v_amount<=0 OR v_method='' THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Positive amount and payment method are required';
  END IF;

  IF p_es_cliente THEN
    IF NOT public.app_tiene_permiso('sales.create') THEN
      RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Sales permission required';
    END IF;
    PERFORM private.assert_sale_in_current_organization(p_deuda_id);
  ELSE
    IF NOT public.app_tiene_permiso('purchases.manage') THEN
      RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Purchases permission required';
    END IF;
    PERFORM private.assert_expense_in_current_organization(p_deuda_id);
  END IF;

  SELECT e.id
  INTO v_employee_id
  FROM public.empleados AS e
  WHERE e.organization_id=v_org
    AND COALESCE(e.activo,false)
    AND (e.app_user_id=v_auth OR e.auth_id=v_auth)
  ORDER BY CASE WHEN e.app_user_id=v_auth THEN 0 ELSE 1 END,e.id
  LIMIT 1;
  IF v_employee_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Active employee identity required to register debt payment';
  END IF;

  v_is_cash:=upper(v_method) LIKE '%EFECTIVO%';
  v_affects_cash:=v_is_cash AND (p_es_cliente OR COALESCE(p_descontar_de_caja,false));

  PERFORM pg_advisory_xact_lock(hashtextextended(v_org::text || ':' || p_request_id::text,0));

  SELECT * INTO v_request
  FROM public.pagos_deuda_requests
  WHERE organization_id=v_org AND request_id=p_request_id;
  IF FOUND THEN
    IF v_request.auth_user_id IS DISTINCT FROM v_auth
       OR v_request.empleado_id IS DISTINCT FROM v_employee_id
       OR v_request.es_cliente IS DISTINCT FROM p_es_cliente
       OR v_request.deuda_id IS DISTINCT FROM p_deuda_id
       OR v_request.monto IS DISTINCT FROM v_amount
       OR v_request.metodo IS DISTINCT FROM v_method_norm
       OR v_request.descontar_de_caja IS DISTINCT FROM (NOT p_es_cliente AND v_affects_cash) THEN
      RAISE EXCEPTION USING ERRCODE='23505', MESSAGE='request_id reused with different payment payload';
    END IF;
    IF v_request.resultado IS NULL THEN
      RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='Debt payment request has no confirmed result';
    END IF;
    RETURN v_request.resultado || jsonb_build_object('idempotent',true);
  END IF;

  INSERT INTO public.pagos_deuda_requests(
    organization_id,request_id,auth_user_id,empleado_id,es_cliente,deuda_id,
    monto,metodo,descontar_de_caja
  ) VALUES (
    v_org,p_request_id,v_auth,v_employee_id,p_es_cliente,p_deuda_id,
    v_amount,v_method_norm,(NOT p_es_cliente AND v_affects_cash)
  );

  IF v_affects_cash THEN
    v_session_id:=private.require_open_cash_session_id();
    IF v_date < (SELECT s.fecha_apertura FROM public.sesiones_caja s WHERE s.organization_id=v_org AND s.id=v_session_id) THEN
      RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Cash payment date cannot be before cash session opening';
    END IF;
    IF NOT p_es_cliente THEN
      v_cash_available:=private.cash_session_available_balance(v_session_id);
      IF v_amount>v_cash_available+0.000001 THEN
        RAISE EXCEPTION 'Saldo insuficiente en Caja. Disponible: S/ %, solicitado: S/ %.',
          round(v_cash_available,2),round(v_amount,2) USING ERRCODE='23514';
      END IF;
    END IF;
  END IF;

  IF p_es_cliente THEN
    -- When an audited canonical account exists, use the only writers allowed
    -- by financial_2b_guard_legacy_financial_write. Never insert a legacy
    -- pagos_venta row against an open canonical ledger.
    SELECT cf.* INTO v_account
    FROM public.venta_cuentas_financieras cf
    WHERE cf.organization_id=v_org AND cf.venta_id=p_deuda_id;
    IF FOUND THEN
      IF v_method_norm='transferencia' THEN
        v_canonical:=private.financial_2c2_record_transfer_payment(
          v_org,p_deuda_id,p_request_id,v_account.moneda,v_amount,v_date
        );
      ELSIF v_is_cash THEN
        v_canonical:=private.financial_2c3b_record_cash_payment(
          v_org,p_deuda_id,p_request_id,v_session_id,v_amount,v_date
        );
      ELSE
        RAISE EXCEPTION USING ERRCODE='23514',
          MESSAGE='Canonical sale accepts only audited bank transfer or cash receipt';
      END IF;
      v_result:=v_canonical || jsonb_build_object(
        'tipo','cobro_cliente','deuda_id',p_deuda_id
      );
    ELSE
    SELECT * INTO v_sale
    FROM public.ventas
    WHERE organization_id=v_org AND id=p_deuda_id
    FOR UPDATE;
    IF NOT FOUND OR lower(COALESCE(v_sale.estado,''))<>'pendiente' THEN
      RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Sale does not allow debt payment';
    END IF;
    v_balance:=round(COALESCE(v_sale.saldo,0),2);
    IF v_amount>v_balance+0.01 THEN
      RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Payment exceeds pending sale balance';
    END IF;

    INSERT INTO public.pagos_venta(
      organization_id,venta_id,metodo,monto,fecha,request_id,cash_session_id
    ) VALUES (
      v_org,p_deuda_id,v_method,v_amount,v_date,p_request_id,
      CASE WHEN v_affects_cash THEN v_session_id ELSE NULL END
    ) RETURNING id INTO v_payment_id;

    SELECT GREATEST(round(COALESCE(v_sale.total,0)-COALESCE(sum(p.monto),0),2),0)
    INTO v_balance
    FROM public.pagos_venta p
    WHERE p.organization_id=v_org AND p.venta_id=p_deuda_id;

    UPDATE public.ventas
    SET saldo=v_balance,estado=CASE WHEN v_balance<=0.01 THEN 'pagado' ELSE 'pendiente' END
    WHERE organization_id=v_org AND id=p_deuda_id;

    v_result:=jsonb_build_object(
      'success',true,'idempotent',false,'request_id',p_request_id,
      'tipo','cobro_cliente','deuda_id',p_deuda_id,'pago_id',v_payment_id,
      'monto',v_amount,'saldo',v_balance,'cash_session_id',v_session_id
    );
    END IF;
  ELSE
    SELECT * INTO v_expense
    FROM public.gastos
    WHERE organization_id=v_org AND id=p_deuda_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Expense not available in current organization';
    END IF;
    v_balance:=round(COALESCE(v_expense.saldo,0),2);
    IF v_amount>v_balance+0.01 THEN
      RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Payment exceeds pending expense balance';
    END IF;

    INSERT INTO public.pagos_gasto(
      organization_id,gasto_id,metodo,monto,fecha,afecta_caja_chica,request_id,cash_session_id
    ) VALUES (
      v_org,p_deuda_id,v_method,v_amount,v_date,v_affects_cash,p_request_id,
      CASE WHEN v_affects_cash THEN v_session_id ELSE NULL END
    ) RETURNING id INTO v_payment_id;

    v_balance:=GREATEST(round(v_balance-v_amount,2),0);
    UPDATE public.gastos
    SET saldo=v_balance,estado=CASE WHEN v_balance<=0.01 THEN 'pagado' ELSE 'pendiente' END
    WHERE organization_id=v_org AND id=p_deuda_id;

    v_result:=jsonb_build_object(
      'success',true,'idempotent',false,'request_id',p_request_id,
      'tipo','pago_proveedor','deuda_id',p_deuda_id,'pago_id',v_payment_id,
      'monto',v_amount,'saldo',v_balance,'cash_session_id',v_session_id
    );
  END IF;

  UPDATE public.pagos_deuda_requests
  SET resultado=v_result,completed_at=now()
  WHERE organization_id=v_org AND request_id=p_request_id;

  RETURN v_result;
END;
$function$;
