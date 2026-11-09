-- 2D-H: prevent orphan active app_users rows from revealing tenant metadata.
-- A genuine sign-up is atomic: owner app_users + employee are committed together.
-- No change to the existing return type, grants or stable SECURITY DEFINER ABI.
CREATE OR REPLACE FUNCTION public.get_organization_signup_state_v1()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_user uuid:=auth.uid();
  v_membership public.app_users;
  v_org public.organizations;
  v_has_legacy_identity boolean:=false;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Authentication required';
  END IF;

  SELECT * INTO v_membership
  FROM public.app_users au
  WHERE au.user_id=v_user;

  IF FOUND THEN
    -- Revoked employees must not obtain tenant identifiers or names from
    -- this account-state endpoint. Temporary pre-employee bootstrap remains
    -- attached until the owner employment row is provisioned.
    -- A surviving app_users membership without an active employee is not
    -- an authorized tenant identity. Signup bootstrap creates the owner
    -- employee in the SAME transaction, so this is safe for real onboarding.
    IF v_membership.status <> 'active'
      OR NOT EXISTS (
        SELECT 1 FROM public.empleados e
        WHERE e.organization_id=v_membership.organization_id
          AND (e.app_user_id=v_user OR e.auth_id=v_user)
          AND e.activo IS TRUE
          AND e.employment_status='active'
      )
    THEN
      RETURN jsonb_build_object('state','access_revoked',
                                'eligible',false,'organization_id',NULL);
    END IF;
    SELECT * INTO v_org FROM public.organizations o WHERE o.id=v_membership.organization_id;
    RETURN jsonb_build_object(
      'state','attached',
      'eligible',false,
      'organization_id',v_membership.organization_id,
      'organization_status',v_org.status,
      'membership_status',v_membership.status,
      'display_name',v_org.display_name
    );
  END IF;

  SELECT EXISTS(
    SELECT 1 FROM public.empleados e
    WHERE e.auth_id=v_user OR e.app_user_id=v_user
  ) INTO v_has_legacy_identity;

  IF v_has_legacy_identity THEN
    RETURN jsonb_build_object(
      'state','legacy_identity_requires_migration',
      'eligible',false,
      'organization_id',NULL
    );
  END IF;

  RETURN jsonb_build_object(
    'state','eligible',
    'eligible',true,
    'organization_id',NULL
  );
END;
$function$;
