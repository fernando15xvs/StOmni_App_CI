-- 2D-H DEV: prevent loss of closed cash session payment evidence in
-- legacy sales with no venta_cuentas_financieras row. The canonical financial
-- ledger guard already blocks such deletion; this fills the legacy gap.
-- Preserve tenant-scope, sales.create, electronic document and ledger guards.
CREATE OR REPLACE FUNCTION public.eliminar_pago_venta_v1(p_pago_id bigint, p_venta_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_total numeric;
  v_total_pagado numeric;
  v_saldo numeric;
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Sales permission required';
  END IF;
  PERFORM private.assert_sale_in_current_organization(p_venta_id);
  IF NOT EXISTS (SELECT 1 FROM public.pagos_venta WHERE organization_id=v_org AND id=p_pago_id) THEN
    RETURN jsonb_build_object('success',true,'idempotent',true);
  END IF;
  PERFORM private.assert_sale_payment_in_current_organization(p_pago_id,p_venta_id);

  -- Closed cash sessions are immutable accounting evidence: even legacy
  -- (non-canonical ledger) sales cannot delete the associated payment.
  IF EXISTS (
    SELECT 1 FROM public.pagos_venta pv
    JOIN public.sesiones_caja s ON s.organization_id=pv.organization_id AND s.id=pv.cash_session_id
    WHERE pv.organization_id=v_org AND pv.venta_id=p_venta_id AND pv.id=p_pago_id AND s.estado='CERRADA'
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Sale payment belongs to a closed cash session';
  END IF;

  -- Mientras F3.7 no tenantifique comprobantes, una venta con documento reservado
  -- se considera inmutable desde este RPC.
  IF EXISTS (SELECT 1 FROM public.comprobantes_electronicos WHERE venta_id=p_venta_id) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Payments of a sale with electronic document cannot be modified';
  END IF;

  SELECT total INTO v_total FROM public.ventas
  WHERE organization_id=v_org AND id=p_venta_id FOR UPDATE;

  DELETE FROM public.pagos_venta
  WHERE organization_id=v_org AND id=p_pago_id AND venta_id=p_venta_id;

  SELECT coalesce(sum(monto),0) INTO v_total_pagado
  FROM public.pagos_venta WHERE organization_id=v_org AND venta_id=p_venta_id;
  v_saldo:=greatest(round(coalesce(v_total,0)-v_total_pagado,2),0);

  UPDATE public.ventas
  SET saldo=v_saldo, estado=CASE WHEN v_saldo<=0.01 THEN 'pagado' ELSE 'pendiente' END
  WHERE organization_id=v_org AND id=p_venta_id;

  RETURN jsonb_build_object('success',true,'venta_id',p_venta_id,'pago_id',p_pago_id,'saldo',v_saldo);
END;
$function$;
