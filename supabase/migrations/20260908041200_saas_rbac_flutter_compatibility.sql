-- Fase 4.5: compatibilidad del RBAC configurable con el contrato Flutter actual.
BEGIN;

CREATE OR REPLACE FUNCTION public.get_employee_permission_settings_v1(p_employee_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_permissions jsonb;
  v_roles jsonb;
  v_primary_role text;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant admin required';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.empleados e WHERE e.organization_id=v_org AND e.id=p_employee_id) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Employee not available in current organization';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('id',r.id,'code',r.code,'name',r.name) ORDER BY CASE WHEN r.code='admin' THEN 0 WHEN r.code='operator' THEN 1 ELSE 2 END,r.name),'[]'::jsonb)
  INTO v_roles
  FROM public.employee_roles er
  JOIN public.roles r ON r.organization_id=er.organization_id AND r.id=er.role_id
  WHERE er.organization_id=v_org AND er.employee_id=p_employee_id AND r.status='active';

  SELECT r.code
  INTO v_primary_role
  FROM public.employee_roles er
  JOIN public.roles r ON r.organization_id=er.organization_id AND r.id=er.role_id
  WHERE er.organization_id=v_org AND er.employee_id=p_employee_id AND r.status='active'
  ORDER BY CASE WHEN r.code='admin' THEN 0 WHEN r.code='operator' THEN 1 ELSE 2 END,r.name,r.id
  LIMIT 1;
  v_primary_role:=COALESCE(v_primary_role,'operator');

  SELECT COALESCE(jsonb_object_agg(p.code,jsonb_build_object(
    'base_allowed',EXISTS(
      SELECT 1 FROM public.employee_roles er
      JOIN public.roles r ON r.organization_id=er.organization_id AND r.id=er.role_id AND r.status='active'
      JOIN public.role_permissions rp ON rp.organization_id=r.organization_id AND rp.role_id=r.id
      WHERE er.organization_id=v_org AND er.employee_id=p_employee_id AND rp.permission_code=p.code
    ),
    'allowed',CASE
      WHEN EXISTS(
        SELECT 1 FROM public.employee_roles er
        JOIN public.roles r ON r.organization_id=er.organization_id AND r.id=er.role_id
        WHERE er.organization_id=v_org AND er.employee_id=p_employee_id AND r.code='admin' AND r.status='active'
      ) THEN true
      WHEN EXISTS(
        SELECT 1 FROM public.employee_permission_overrides o
        WHERE o.organization_id=v_org AND o.employee_id=p_employee_id AND o.permission_code=p.code
      ) THEN (
        SELECT o.allowed FROM public.employee_permission_overrides o
        WHERE o.organization_id=v_org AND o.employee_id=p_employee_id AND o.permission_code=p.code
      )
      ELSE EXISTS(
        SELECT 1 FROM public.employee_roles er
        JOIN public.roles r ON r.organization_id=er.organization_id AND r.id=er.role_id AND r.status='active'
        JOIN public.role_permissions rp ON rp.organization_id=r.organization_id AND rp.role_id=r.id
        WHERE er.organization_id=v_org AND er.employee_id=p_employee_id AND rp.permission_code=p.code
      )
    END,
    'override',(SELECT o.allowed FROM public.employee_permission_overrides o WHERE o.organization_id=v_org AND o.employee_id=p_employee_id AND o.permission_code=p.code)
  )),'{}'::jsonb)
  INTO v_permissions
  FROM public.permissions p
  WHERE p.is_active;

  RETURN jsonb_build_object(
    'employee_id',p_employee_id,
    'role',v_primary_role,
    'roles',v_roles,
    'permissions',v_permissions
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_effective_permissions_v1()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_employee_id bigint;
  v_primary_role text;
  v_permissions jsonb;
BEGIN
  SELECT e.id INTO v_employee_id
  FROM public.empleados e
  WHERE e.organization_id=v_org AND e.employment_status='active'
    AND (e.app_user_id=auth.uid() OR e.auth_id=auth.uid())
  ORDER BY CASE WHEN e.app_user_id=auth.uid() THEN 0 ELSE 1 END,e.id
  LIMIT 1;
  IF v_employee_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Employee identity required';
  END IF;

  SELECT r.code INTO v_primary_role
  FROM public.employee_roles er
  JOIN public.roles r ON r.organization_id=er.organization_id AND r.id=er.role_id
  WHERE er.organization_id=v_org AND er.employee_id=v_employee_id AND r.status='active'
  ORDER BY CASE WHEN r.code='admin' THEN 0 WHEN r.code='operator' THEN 1 ELSE 2 END,r.name,r.id
  LIMIT 1;

  SELECT COALESCE(jsonb_agg(p.code ORDER BY p.code),'[]'::jsonb)
  INTO v_permissions
  FROM public.permissions p
  WHERE p.is_active AND public.app_tiene_permiso(p.code);

  RETURN jsonb_build_object(
    'supported',true,
    'employee_id',v_employee_id,
    'role',COALESCE(v_primary_role,'operator'),
    'permissions',v_permissions
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_employee_permission_settings_v1(bigint) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.get_my_effective_permissions_v1() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_employee_permission_settings_v1(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_effective_permissions_v1() TO authenticated;

COMMIT;
