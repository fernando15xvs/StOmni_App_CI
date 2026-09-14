-- Puente temporal de autorización durante el rollout de Bloque 3.
-- app_users + organizations son la autoridad; empleados sólo conserva overrides legacy.
BEGIN;

CREATE OR REPLACE FUNCTION public.app_empleado_activo()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.is_active_user()
$$;

CREATE OR REPLACE FUNCTION public.app_es_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT private.current_base_role() = 'admin'
$$;

CREATE OR REPLACE FUNCTION public.get_my_tenant_context_v1()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'organization_id', private.require_current_organization_id(),
    'base_role', private.current_base_role()
  )
$$;

CREATE OR REPLACE FUNCTION public.app_tiene_permiso(p_permission_code text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := private.current_organization_id();
  v_role text := private.current_base_role();
  v_permission_code text := NULLIF(btrim(p_permission_code), '');
  v_employee_id bigint;
  v_base text[];
  v_override boolean;
BEGIN
  IF v_user_id IS NULL
     OR v_organization_id IS NULL
     OR v_role IS NULL
     OR v_permission_code IS NULL THEN
    RETURN false;
  END IF;

  v_base := public._app_role_base_permissions(v_role);
  IF NOT (v_permission_code = ANY(COALESCE(v_base, ARRAY[]::text[]))) THEN
    RETURN false;
  END IF;

  -- El rol base canónico vive en app_users. Admin conserva los permisos base
  -- incluso si todavía existe un override histórico incoherente en empleados.
  IF v_role = 'admin' THEN
    RETURN true;
  END IF;

  -- Para operadores se conserva temporalmente el override de la ficha laboral,
  -- pero sólo cuando la ficha pertenece al mismo tenant y a la misma identidad.
  SELECT e.id
  INTO v_employee_id
  FROM public.empleados AS e
  WHERE e.organization_id = v_organization_id
    AND COALESCE(e.app_user_id, e.auth_id) = v_user_id
    AND COALESCE(e.activo, false) = true
  LIMIT 1;

  IF v_employee_id IS NULL THEN
    RETURN true;
  END IF;

  SELECT o.allowed
  INTO v_override
  FROM public.employee_permission_overrides AS o
  WHERE o.employee_id = v_employee_id
    AND o.permission_code = v_permission_code;

  RETURN COALESCE(v_override, true);
END;
$$;

CREATE OR REPLACE FUNCTION public.get_my_effective_permissions_v1()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_organization_id uuid := private.current_organization_id();
  v_role text := private.current_base_role();
  v_employee_id bigint;
  v_base text[];
  v_effective text[];
BEGIN
  IF v_user_id IS NULL OR v_organization_id IS NULL OR v_role IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Active application membership required';
  END IF;

  v_base := public._app_role_base_permissions(v_role);

  SELECT e.id
  INTO v_employee_id
  FROM public.empleados AS e
  WHERE e.organization_id = v_organization_id
    AND COALESCE(e.app_user_id, e.auth_id) = v_user_id
    AND COALESCE(e.activo, false) = true
  LIMIT 1;

  IF v_role = 'admin' OR v_employee_id IS NULL THEN
    v_effective := v_base;
  ELSE
    SELECT COALESCE(array_agg(code ORDER BY code), ARRAY[]::text[])
    INTO v_effective
    FROM unnest(COALESCE(v_base, ARRAY[]::text[])) AS code
    WHERE COALESCE((
      SELECT o.allowed
      FROM public.employee_permission_overrides AS o
      WHERE o.employee_id = v_employee_id
        AND o.permission_code = code
    ), true);
  END IF;

  RETURN jsonb_build_object(
    'supported', true,
    'organization_id', v_organization_id,
    'employee_id', v_employee_id,
    'role', v_role,
    'permissions', to_jsonb(COALESCE(v_effective, ARRAY[]::text[]))
  );
END;
$$;

REVOKE ALL ON FUNCTION public.app_empleado_activo()
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.app_es_admin()
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_my_tenant_context_v1()
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.app_tiene_permiso(text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_my_effective_permissions_v1()
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.app_empleado_activo() TO authenticated;
GRANT EXECUTE ON FUNCTION public.app_es_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_tenant_context_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.app_tiene_permiso(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_effective_permissions_v1() TO authenticated;

COMMENT ON FUNCTION public.app_empleado_activo() IS
  'Compatibilidad SaaS: membership activa se resuelve desde app_users/organizations, no desde empleados.auth_id.';
COMMENT ON FUNCTION public.app_es_admin() IS
  'Compatibilidad SaaS: admin se resuelve desde app_users.base_role.';
COMMENT ON FUNCTION public.get_my_tenant_context_v1() IS
  'Devuelve únicamente el organization_id y rol base de la membership autenticada activa. No concede autoridad por recibir el UUID.';
COMMENT ON FUNCTION public.app_tiene_permiso(text) IS
  'Compatibilidad temporal: rol base desde app_users; override laboral sólo dentro del mismo tenant. F4.5 reemplazará la implementación.';
COMMENT ON FUNCTION public.get_my_effective_permissions_v1() IS
  'Permisos efectivos SaaS: app_users es autoridad; employee_id es opcional y sólo aporta overrides laborales del mismo tenant.';

COMMIT;
