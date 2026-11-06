-- 2D-H: authorize the tenant-owned register before inspecting open sessions.
CREATE OR REPLACE FUNCTION public.update_cash_register_v1(p_cash_register_id uuid, p_name text, p_status text DEFAULT 'active'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_status text:=lower(btrim(p_status));
  v_row public.cash_registers;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION 'Only tenant admin can update cash registers' USING ERRCODE='42501';
  END IF;
  IF v_status NOT IN ('active','inactive') THEN
    RAISE EXCEPTION 'Invalid cash register status' USING ERRCODE='22023';
  END IF;
  SELECT * INTO v_row FROM public.cash_registers
  WHERE organization_id=v_org AND id=p_cash_register_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cash register not available in current organization' USING ERRCODE='P0002';
  END IF;
  IF v_status='inactive' AND EXISTS(
    SELECT 1 FROM public.sesiones_caja s
    WHERE s.organization_id=v_org
      AND s.cash_register_id=p_cash_register_id AND s.estado='ABIERTA'
  ) THEN
    RAISE EXCEPTION 'Cash register has an open session' USING ERRCODE='23514';
  END IF;
  UPDATE public.cash_registers
  SET name=btrim(p_name),status=v_status
  WHERE organization_id=v_org AND id=p_cash_register_id
  RETURNING * INTO v_row;
  IF NOT FOUND THEN RAISE EXCEPTION 'Cash register not available in current organization' USING ERRCODE='P0002'; END IF;
  RETURN to_jsonb(v_row);
END;
$function$;
