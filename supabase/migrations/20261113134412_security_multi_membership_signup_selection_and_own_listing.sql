-- 2D-I2: prepare multi-org account state without enabling multiple memberships.
-- Only list memberships with a matching active organization and employee.
CREATE OR REPLACE FUNCTION public.list_my_organization_memberships_v1()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE v_actor uuid:=auth.uid(); v_result jsonb;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Authentication required';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'organization_id',o.id,'display_name',o.display_name,'base_role',au.base_role)
    ORDER BY lower(o.display_name),o.id),'[]'::jsonb)
  INTO v_result
  FROM public.app_users au
  JOIN public.organizations o ON o.id=au.organization_id
  WHERE au.user_id=v_actor AND au.status='active' AND o.status='active'
    AND EXISTS(
      SELECT 1 FROM public.empleados e
      WHERE e.organization_id=au.organization_id
        AND (e.app_user_id=v_actor OR e.auth_id=v_actor)
        AND e.activo IS TRUE AND e.employment_status='active'
    );
  RETURN v_result;
END;
$fn$;
REVOKE ALL ON FUNCTION public.list_my_organization_memberships_v1() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.list_my_organization_memberships_v1() TO authenticated;

-- Explicit unauthorized selection never reveals a foreign tenant's metadata.
-- Multiple valid memberships without selection must fail closed.
CREATE OR REPLACE FUNCTION public.get_organization_signup_state_v1()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $fn$
DECLARE
 v_user uuid:=auth.uid();
 v_org uuid;
 v_has_memberships boolean;
 v_has_legacy_identity boolean;
 v_headers jsonb;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='28000',MESSAGE='Authentication required';
  END IF;
  SELECT s.organization_id INTO v_org
  FROM private.resolve_selected_membership_v1() AS s;
  IF v_org IS NOT NULL THEN
    RETURN (
      SELECT jsonb_build_object(
        'state','attached','eligible',false,
        'organization_id',au.organization_id,
        'organization_status',o.status,
        'membership_status',au.status,
        'display_name',o.display_name
      )
      FROM public.app_users au
      JOIN public.organizations o ON o.id=au.organization_id
      WHERE au.user_id=v_user AND au.organization_id=v_org
        AND au.status='active' AND o.status='active'
    );
  END IF;
  SELECT EXISTS(SELECT 1 FROM public.app_users au WHERE au.user_id=v_user)
    INTO v_has_memberships;
  IF v_has_memberships THEN
    v_headers:=coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb;
    IF NOT (v_headers ? 'x-stomni-organization-id')
      AND jsonb_array_length(public.list_my_organization_memberships_v1())>1
    THEN
      RETURN jsonb_build_object('state','selection_required','eligible',false,'organization_id',NULL);
    END IF;
    RETURN jsonb_build_object('state','access_revoked','eligible',false,'organization_id',NULL);
  END IF;
  SELECT EXISTS(
    SELECT 1 FROM public.empleados e
    WHERE e.auth_id=v_user OR e.app_user_id=v_user
  ) INTO v_has_legacy_identity;
  IF v_has_legacy_identity THEN
    RETURN jsonb_build_object('state','legacy_identity_requires_migration','eligible',false,'organization_id',NULL);
  END IF;
  RETURN jsonb_build_object('state','eligible','eligible',true,'organization_id',NULL);
END;
$fn$;
REVOKE ALL ON FUNCTION public.get_organization_signup_state_v1() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_organization_signup_state_v1() TO authenticated;
