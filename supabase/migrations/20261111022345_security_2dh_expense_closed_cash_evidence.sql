-- 2D-H DEV: preserve accounting evidence when deleting expenses/payments.
-- Original expense-deletion RPCs skipped the closed-session immutability
-- check already applied to employee payments. Parent deletion cascades to
-- pagos_gasto, so both direct payment deletion and expense deletion must
-- reject payments with cash_session_id pointing to a CERRADA session.
-- SQLSTATE 23514; no additional EXECUTE privileges or changes to tenant guards.
CREATE OR REPLACE FUNCTION public.eliminar_gasto_v1(p_gasto_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_org uuid := private.require_current_organization_id();
BEGIN
  IF NOT private.has_permission('tenant.write') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant write permission required';
  END IF;
  PERFORM private.assert_expense_in_current_organization(p_gasto_id);
  -- Deleting the parent would CASCADE DELETE its cash payments; preserve
  -- all records belonging to a closed session just like employee payments.
  IF EXISTS (
    SELECT 1 FROM public.pagos_gasto pg
    JOIN public.sesiones_caja s ON s.organization_id=pg.organization_id AND s.id=pg.cash_session_id
    WHERE pg.organization_id=v_org AND pg.gasto_id=p_gasto_id AND s.estado='CERRADA'
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Expense contains payment in a closed cash session';
  END IF;

  DELETE FROM public.gastos WHERE organization_id=v_org AND id=p_gasto_id;
  RETURN jsonb_build_object('success',true,'gasto_id',p_gasto_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.eliminar_pago_gasto_v1(p_pago_id bigint, p_gasto_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_gasto public.gastos%ROWTYPE;
  v_total_pagado numeric := 0;
  v_nuevo_saldo numeric := 0;
  v_estado text;
BEGIN
  IF NOT private.has_permission('tenant.write') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant write permission required';
  END IF;
  PERFORM private.assert_expense_payment_in_current_organization(p_pago_id,p_gasto_id);

  -- Cash payments in a closed session are immutable accounting evidence.
  IF EXISTS (
    SELECT 1 FROM public.pagos_gasto pg
    JOIN public.sesiones_caja s ON s.organization_id=pg.organization_id AND s.id=pg.cash_session_id
    WHERE pg.organization_id=v_org AND pg.gasto_id=p_gasto_id AND pg.id=p_pago_id AND s.estado='CERRADA'
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Expense payment belongs to a closed cash session';
  END IF;

  SELECT * INTO v_gasto
  FROM public.gastos
  WHERE organization_id=v_org AND id=p_gasto_id
  FOR UPDATE;

  DELETE FROM public.pagos_gasto
  WHERE organization_id=v_org AND id=p_pago_id AND gasto_id=p_gasto_id;

  SELECT COALESCE(SUM(monto),0) INTO v_total_pagado
  FROM public.pagos_gasto
  WHERE organization_id=v_org AND gasto_id=p_gasto_id;

  v_nuevo_saldo:=GREATEST(v_gasto.monto-v_total_pagado,0);
  v_estado:=CASE WHEN v_nuevo_saldo<=0.02 THEN 'pagado' ELSE 'pendiente' END;

  UPDATE public.gastos
  SET saldo=v_nuevo_saldo,estado=v_estado
  WHERE organization_id=v_org AND id=p_gasto_id;

  RETURN jsonb_build_object(
    'success',true,'gasto_id',p_gasto_id,'pago_id',p_pago_id,
    'saldo',v_nuevo_saldo,'estado',v_estado
  );
END;
$function$;
