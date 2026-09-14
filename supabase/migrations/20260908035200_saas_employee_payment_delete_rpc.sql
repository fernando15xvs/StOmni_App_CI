-- Fase 4.4: eliminación de pago de personal únicamente por RPC tenant-aware.
BEGIN;

CREATE OR REPLACE FUNCTION public.eliminar_pago_empleado_v1(p_pago_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_payment public.pagos_empleados%ROWTYPE;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant admin required for employee payment deletion';
  END IF;

  SELECT * INTO v_payment
  FROM public.pagos_empleados
  WHERE organization_id=v_org AND id=p_pago_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Employee payment not available in current organization';
  END IF;

  -- Una sesión cerrada es evidencia contable: su movimiento no se reescribe.
  IF v_payment.cash_session_id IS NOT NULL AND EXISTS(
    SELECT 1 FROM public.sesiones_caja s
    WHERE s.organization_id=v_org AND s.id=v_payment.cash_session_id AND s.estado='CERRADA'
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Employee payment belongs to a closed cash session';
  END IF;

  DELETE FROM public.pagos_empleados
  WHERE organization_id=v_org AND id=p_pago_id;

  RETURN jsonb_build_object('success',true,'pago_id',p_pago_id,'empleado_id',v_payment.empleado_id);
END;
$$;

REVOKE ALL ON FUNCTION public.eliminar_pago_empleado_v1(bigint) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.eliminar_pago_empleado_v1(bigint) TO authenticated;

COMMIT;
