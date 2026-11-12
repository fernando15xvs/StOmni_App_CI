-- 2D-I1: bind operational tenant and role to one validated selected membership.
-- Bootstrap-only compatibility: before the first employee exists, a single
-- active membership WITHOUT an explicit selector may provide an organization
-- to the onboarding writers. It never grants a base role.
-- Any former employee, including revoked employees, fails this fallback.
CREATE OR REPLACE FUNCTION private.current_organization_id()
RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
  v_actor uuid := auth.uid();
  v_org uuid;
  v_fallback uuid;
BEGIN
  SELECT s.organization_id INTO v_org
  FROM private.resolve_selected_membership_v1() AS s;
  IF v_org IS NOT NULL THEN
    RETURN v_org;
  END IF;

  -- Explicit selections must pass the atomic membership/employee resolver.
  -- Do not interpret headers as permission grants.
  IF v_actor IS NULL OR
    coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb
      ? 'x-stomni-organization-id'
  THEN
    RETURN NULL;
  END IF;

  -- The organization bootstrap inserts app_users before the owner employee.
  -- Compatibility is allowed only if the actor has never had an employee;
  -- never choose an arbitrary row once multiple memberships exist.
  SELECT CASE WHEN count(*) = 1
              THEN min(au.organization_id::text)::uuid
              ELSE NULL END
  INTO v_fallback
  FROM public.app_users au
  JOIN public.organizations o ON o.id=au.organization_id
  WHERE au.user_id=v_actor
    AND au.status='active'
    AND o.status='active'
    AND NOT EXISTS (
      SELECT 1 FROM public.empleados e
      WHERE e.app_user_id=v_actor OR e.auth_id=v_actor
    );

  RETURN v_fallback;
END;
$fn$;

CREATE OR REPLACE FUNCTION private.current_base_role()
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
  SELECT s.base_role
  FROM private.resolve_selected_membership_v1() AS s
$fn$;
