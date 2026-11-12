-- 2D-I1 (staged, NOT ACTIVATED): read-only atomic selected-membership primitive.
-- The original private.current_organization_id/current_base_role remain unchanged.
-- Never accept the request organization/role without an active DB membership and
-- an active employee in that very same organization. No user_metadata trust.
CREATE OR REPLACE FUNCTION private.resolve_selected_membership_v1()
RETURNS TABLE(organization_id uuid,base_role text,employee_id bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $function$
DECLARE
  v_actor uuid:=auth.uid();
  v_header_raw text:=current_setting('request.headers',true);
  v_headers jsonb:='{}'::jsonb;
  v_target_text text;
  v_target uuid;
  v_count bigint;
BEGIN
  IF v_actor IS NULL THEN
    RETURN;
  END IF;

  IF v_header_raw IS NOT NULL AND btrim(v_header_raw)<>'' THEN
    BEGIN
      v_headers:=v_header_raw::jsonb;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION USING ERRCODE='42501',
        MESSAGE='Invalid organization selector headers';
    END;
  END IF;
  IF jsonb_typeof(v_headers) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION USING ERRCODE='42501',
      MESSAGE='Invalid organization selector headers';
  END IF;

  IF v_headers ? 'x-stomni-organization-id' THEN
    v_target_text:=btrim(coalesce(v_headers->>'x-stomni-organization-id',''));
    IF v_target_text='' THEN
      RAISE EXCEPTION USING ERRCODE='42501',
        MESSAGE='Invalid organization selector';
    END IF;
    BEGIN
      v_target:=v_target_text::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION USING ERRCODE='42501',
        MESSAGE='Invalid organization selector';
    END;
  END IF;

  SELECT count(*) INTO v_count
  FROM public.app_users au
  JOIN public.organizations o ON o.id=au.organization_id
  WHERE au.user_id=v_actor AND au.status='active'
    AND o.status='active'
    AND (v_target IS NULL OR au.organization_id=v_target)
    AND EXISTS (
      SELECT 1 FROM public.empleados e
      WHERE e.organization_id=au.organization_id
        AND (e.app_user_id=v_actor OR e.auth_id=v_actor)
        AND e.employment_status='active' AND e.activo IS TRUE
    );
  -- Without a selector, multiple memberships must NEVER be chosen
  -- arbitrarily. With a selector, only the selected membership may match.
  IF v_count<>1 THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT au.organization_id,au.base_role,
    (SELECT e.id FROM public.empleados e
     WHERE e.organization_id=au.organization_id
       AND (e.app_user_id=v_actor OR e.auth_id=v_actor)
       AND e.employment_status='active' AND e.activo IS TRUE
     ORDER BY CASE WHEN e.app_user_id=v_actor THEN 0 ELSE 1 END,e.id
     LIMIT 1)::bigint AS employee_id
  FROM public.app_users au
  JOIN public.organizations o ON o.id=au.organization_id
  WHERE au.user_id=v_actor AND au.status='active'
    AND o.status='active'
    AND (v_target IS NULL OR au.organization_id=v_target)
    AND EXISTS (
      SELECT 1 FROM public.empleados e
      WHERE e.organization_id=au.organization_id
        AND (e.app_user_id=v_actor OR e.auth_id=v_actor)
        AND e.employment_status='active' AND e.activo IS TRUE
    );
END;
$function$;
-- Internal resolver: callable only by trusted SECURITY DEFINER internals.
-- public RPCs/current identity helpers are NOT rewired by this migration.
REVOKE ALL ON FUNCTION private.resolve_selected_membership_v1()
  FROM PUBLIC,anon,authenticated;
