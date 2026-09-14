-- Fase 4.3 SaaS (parte 3): reabrir deuda/gastos cash sobre sesiones tenant-aware.
BEGIN;

-- La PK histórica global impedía reutilizar el mismo request UUID en dos tenants.
-- Las FKs tenant-aware creadas en fases anteriores dependen del UNIQUE temporal
-- (organization_id, request_id). Se desmontan explícitamente antes de promover
-- ese par a la PK definitiva y se recrean contra la nueva PK sin cambiar su
-- semántica ON DELETE RESTRICT. No usar CASCADE: queremos conservar el contrato
-- referencial de pagos_venta y pagos_gasto de forma deliberada.
ALTER TABLE public.pagos_venta
  DROP CONSTRAINT IF EXISTS pagos_venta_request_id_fkey;

ALTER TABLE public.pagos_gasto
  DROP CONSTRAINT IF EXISTS pagos_gasto_request_id_fkey;

ALTER TABLE public.pagos_deuda_requests
  DROP CONSTRAINT IF EXISTS pagos_deuda_requests_pkey,
  DROP CONSTRAINT IF EXISTS pagos_deuda_requests_organization_request_key;

ALTER TABLE public.pagos_deuda_requests
  ADD CONSTRAINT pagos_deuda_requests_pkey
    PRIMARY KEY (organization_id, request_id);

ALTER TABLE public.pagos_venta
  ADD CONSTRAINT pagos_venta_request_id_fkey
    FOREIGN KEY (organization_id, request_id)
    REFERENCES public.pagos_deuda_requests(organization_id, request_id)
    ON DELETE RESTRICT;

ALTER TABLE public.pagos_gasto
  ADD CONSTRAINT pagos_gasto_request_id_fkey
    FOREIGN KEY (organization_id, request_id)
    REFERENCES public.pagos_deuda_requests(organization_id, request_id)
    ON DELETE RESTRICT;

-- -----------------------------------------------------------------------------
-- Helpers privados de Caja. Toda operación cash usa la sesión ABIERTA del usuario
-- autenticado dentro del tenant actual; nunca "la última caja abierta" global.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.require_open_cash_session_id()
RETURNS uuid
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_session_id uuid;
  v_count integer;
BEGIN
  SELECT count(*)::integer
  INTO v_count
  FROM public.sesiones_caja AS s
  WHERE s.organization_id=v_org
    AND s.usuario_id=auth.uid()
    AND s.estado='ABIERTA';

  IF v_count=0 THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Open cash session required for current user';
  END IF;
  IF v_count>1 THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Multiple open cash sessions require explicit register selection';
  END IF;

  SELECT s.id
  INTO v_session_id
  FROM public.sesiones_caja AS s
  WHERE s.organization_id=v_org
    AND s.usuario_id=auth.uid()
    AND s.estado='ABIERTA'
  FOR UPDATE;

  RETURN v_session_id;
END;
$$;

CREATE OR REPLACE FUNCTION private.cash_session_available_balance(p_session_id uuid)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_opening numeric;
  v_income numeric := 0;
  v_expense numeric := 0;
BEGIN
  SELECT s.monto_apertura
  INTO v_opening
  FROM public.sesiones_caja AS s
  WHERE s.organization_id=v_org
    AND s.id=p_session_id
    AND s.usuario_id=auth.uid()
    AND s.estado='ABIERTA';

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Open cash session not available in current organization';
  END IF;

  SELECT COALESCE(sum(p.monto),0)
  INTO v_income
  FROM public.pagos_venta AS p
  WHERE p.organization_id=v_org
    AND p.cash_session_id=p_session_id;

  SELECT COALESCE(sum(p.monto),0)
  INTO v_expense
  FROM public.pagos_gasto AS p
  WHERE p.organization_id=v_org
    AND p.cash_session_id=p_session_id
    AND COALESCE(p.afecta_caja_chica,false);

  -- pagos_empleados se incorpora aquí en F4.4 cuando tenga ownership tenant/cash.
  RETURN COALESCE(v_opening,0)+v_income-v_expense;
END;
$$;

REVOKE ALL ON FUNCTION private.require_open_cash_session_id() FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION private.cash_session_available_balance(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.require_open_cash_session_id() TO authenticated;
GRANT EXECUTE ON FUNCTION private.cash_session_available_balance(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- registrar_gasto_mixto: reabre afecta_caja_chica de forma transaccional.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_gasto_mixto(
  p_proveedor_id bigint,p_categoria text,p_monto_total numeric,p_descripcion text,
  p_fecha timestamptz,p_pagos_json jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_saldo_restante numeric;
  v_estado text;
  v_gasto_id bigint;
  v_total_pagado numeric := 0;
  v_total_cash numeric := 0;
  v_pago jsonb;
  v_monto numeric;
  v_metodo text;
  v_afecta_caja boolean;
  v_fecha timestamptz := COALESCE(p_fecha,now());
  v_session_id uuid;
  v_cash_available numeric;
BEGIN
  IF NOT private.has_permission('tenant.write') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant write permission required';
  END IF;
  IF p_proveedor_id IS NOT NULL THEN
    PERFORM private.assert_supplier_in_current_organization(p_proveedor_id,true);
  END IF;
  IF p_monto_total IS NULL OR p_monto_total<=0 THEN
    RAISE EXCEPTION 'El monto total del gasto debe ser mayor a cero.' USING ERRCODE='22023';
  END IF;
  IF p_pagos_json IS NOT NULL AND jsonb_typeof(p_pagos_json)<>'array' THEN
    RAISE EXCEPTION 'Los pagos deben enviarse como un arreglo JSON.' USING ERRCODE='22023';
  END IF;

  IF p_pagos_json IS NOT NULL THEN
    FOR v_pago IN SELECT value FROM jsonb_array_elements(p_pagos_json)
    LOOP
      IF jsonb_typeof(v_pago)<>'object' THEN
        RAISE EXCEPTION 'Cada pago debe ser un objeto JSON.' USING ERRCODE='22023';
      END IF;
      v_monto:=COALESCE(NULLIF(v_pago->>'monto','')::numeric,0);
      v_metodo:=btrim(COALESCE(v_pago->>'metodo',''));
      v_afecta_caja:=COALESCE((v_pago->>'afecta_caja_chica')::boolean,false)
        AND upper(v_metodo) LIKE '%EFECTIVO%';
      IF v_monto<=0 OR v_metodo='' THEN
        RAISE EXCEPTION 'Todos los pagos deben indicar método y monto positivo.' USING ERRCODE='22023';
      END IF;
      v_total_pagado:=v_total_pagado+v_monto;
      IF v_afecta_caja THEN v_total_cash:=v_total_cash+v_monto; END IF;
    END LOOP;
  END IF;

  IF v_total_pagado>p_monto_total+0.02 THEN
    RAISE EXCEPTION 'Los pagos superan el monto total del gasto.' USING ERRCODE='23514';
  END IF;

  IF v_total_cash>0 THEN
    v_session_id:=private.require_open_cash_session_id();
    v_cash_available:=private.cash_session_available_balance(v_session_id);
    IF v_total_cash>v_cash_available+0.000001 THEN
      RAISE EXCEPTION 'Saldo insuficiente en Caja. Disponible: S/ %, solicitado: S/ %.',
        round(v_cash_available,2),round(v_total_cash,2) USING ERRCODE='23514';
    END IF;
  END IF;

  v_saldo_restante:=GREATEST(p_monto_total-v_total_pagado,0);
  v_estado:=CASE WHEN v_saldo_restante<=0.02 THEN 'pagado' ELSE 'pendiente' END;

  INSERT INTO public.gastos(
    organization_id,fecha,proveedor_id,categoria,monto,descripcion,estado,saldo
  ) VALUES (
    v_org,v_fecha,p_proveedor_id,p_categoria,p_monto_total,p_descripcion,v_estado,v_saldo_restante
  ) RETURNING id INTO v_gasto_id;

  IF p_pagos_json IS NOT NULL THEN
    FOR v_pago IN SELECT value FROM jsonb_array_elements(p_pagos_json)
    LOOP
      v_monto:=COALESCE(NULLIF(v_pago->>'monto','')::numeric,0);
      v_metodo:=btrim(COALESCE(v_pago->>'metodo',''));
      v_afecta_caja:=COALESCE((v_pago->>'afecta_caja_chica')::boolean,false)
        AND upper(v_metodo) LIKE '%EFECTIVO%';
      INSERT INTO public.pagos_gasto(
        organization_id,gasto_id,metodo,monto,fecha,afecta_caja_chica,cash_session_id
      ) VALUES (
        v_org,v_gasto_id,v_metodo,v_monto,v_fecha,v_afecta_caja,
        CASE WHEN v_afecta_caja THEN v_session_id ELSE NULL END
      );
    END LOOP;
  END IF;

  RETURN v_gasto_id;
END;
$$;

-- -----------------------------------------------------------------------------
-- procesar_pago_deuda_v2: implementación autoritativa tenant/session-aware.
-- No delega al motor histórico que resolvía Caja global por fecha.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.procesar_pago_deuda_v2(
  p_request_id uuid,p_es_cliente boolean,p_deuda_id bigint,p_monto numeric,
  p_metodo text,p_fecha timestamptz,p_descontar_de_caja boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
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
$$;

REVOKE ALL ON FUNCTION public.registrar_gasto_mixto(bigint,text,numeric,text,timestamptz,jsonb)
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._legacy_procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)
  FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_gasto_mixto(bigint,text,numeric,text,timestamptz,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean) TO authenticated;

COMMIT;