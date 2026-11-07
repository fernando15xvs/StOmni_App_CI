-- 2D-H: close the membership-only path into privileged tenant data readers.
-- Keep private.current_organization_id() available for bootstrap/account-state
-- discovery, but require active employment at every privileged require_* boundary.
-- This prevents terminated employees with lingering app_users memberships from
-- accessing cash, subscriptions and other SECURITY DEFINER RPCs.
CREATE OR REPLACE FUNCTION private.require_current_organization_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SET search_path TO ''
AS $function$
DECLARE
  v_organization_id uuid := private.current_organization_id();
BEGIN
  IF v_organization_id IS NULL
     OR private.has_permission('tenant.read') IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Active organization membership and employment required';
  END IF;

  RETURN v_organization_id;
END;
$function$;
