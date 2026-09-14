-- F2.3 hardening transversal: los overrides de permisos pertenecen a una
-- organización y las RPC de sesión usan app_users como autoridad canónica.
-- F4.5 podrá reemplazar este modelo por roles configurables sin dejar una fuga
-- cross-tenant durante la transición.
BEGIN;

ALTER TABLE public.employee_permission_overrides
  ADD COLUMN organization_id uuid;

UPDATE public.employee_permission_overrides o
SET organization_id = e.organization_id
FROM public.empleados e
WHERE e.id = o.employee_id
  AND o.organization_id IS NULL;

DO $validate$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.employee_permission_overrides
    WHERE organization_id IS NULL
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Unscoped employee permission overrides remain';
  END IF;
END;
$validate$;

ALTER TABLE public.employee_permission_overrides
  ALTER COLUMN organization_id SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS saas_empleados_organization_id_id_uidx
  ON public.empleados(organization_id, id);

ALTER TABLE public.employee_permission_overrides
  DROP CONSTRAINT employee_permission_overrides_employee_id_fkey,
  DROP CONSTRAINT employee_permission_overrides_pkey;

ALTER TABLE public.employee_permission_overrides
  ADD CONSTRAINT employee_permission_overrides_organization_id_fkey
    FOREIGN KEY (organization_id)
    REFERENCES public.organizations(id)
    ON DELETE RESTRICT,
  ADD CONSTRAINT employee_permission_overrides_employee_fkey
    FOREIGN KEY (organization_id, employee_id)
    REFERENCES public.empleados(organization_id, id)
    ON DELETE CASCADE,
  ADD CONSTRAINT employee_permission_overrides_pkey
    PRIMARY KEY (organization_id, employee_id, permission_code);

CREATE INDEX employee_permission_overrides_employee_idx
  ON public.employee_permission_overrides(organization_id, employee_id);

DROP POLICY IF EXISTS employee_permission_read
  ON public.employee_permission_overrides;
ALTER TABLE public.employee_permission_overrides ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.employee_permission_overrides
  FROM PUBLIC, anon, authenticated;

CREATE POLICY employee_permission_overrides_tenant_select
ON public.employee_permission_overrides
FOR SELECT
TO authenticated
USING (
  organization_id = private.current_organization_id()
  AND (
    private.has_permission('tenant.admin')
    OR employee_id = (
      SELECT e.id
      FROM public.empleados e
      WHERE e.organization_id = private.current_organization_id()
        AND (e.app_user_id = auth.uid() OR e.auth_id = auth.uid())
        AND COALESCE(e.activo, false) = true
      LIMIT 1
    )
  )
);

-- No GRANT SELECT: el cliente consume exclusivamente las RPC allowlisted.

CREATE OR REPLACE FUNCTION public.app_tiene_permiso(p_permission_code text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.current_organization_id();
  v_employee_id bigint;
  v_role text;
  v_base text[];
  v_override boolean;
BEGIN
  IF v_org IS NULL OR auth.uid() IS NULL THEN
    RETURN false;
  END IF;

  SELECT e.id, au.base_role
  INTO v_employee_id, v_role
  FROM public.app_users au
  JOIN public.empleados e
    ON e.organization_id = au.organization_id
   AND (e.app_user_id = au.user_id OR e.auth_id = au.user_id)
  WHERE au.user_id = auth.uid()
    AND au.organization_id = v_org
    AND au.status = 'active'
    AND COALESCE(e.activo, false) = true
  LIMIT 1;

  IF v_employee_id IS NULL THEN
    RETURN false;
  END IF;

  v_base := public._app_role_base_permissions(v_role);
  IF NOT (p_permission_code = ANY(v_base)) THEN
    RETURN false;
  END IF;

  IF v_role = 'admin' THEN
    RETURN true;
  END IF;

  SELECT o.allowed
  INTO v_override
  FROM public.employee_permission_overrides o
  WHERE o.organization_id = v_org
    AND o.employee_id = v_employee_id
    AND o.permission_code = p_permission_code;

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
  v_org uuid := private.require_current_organization_id();
  v_employee_id bigint;
  v_role text;
  v_base text[];
  v_effective text[];
BEGIN
  SELECT e.id, au.base_role
  INTO v_employee_id, v_role
  FROM public.app_users au
  JOIN public.empleados e
    ON e.organization_id = au.organization_id
   AND (e.app_user_id = au.user_id OR e.auth_id = au.user_id)
  WHERE au.user_id = auth.uid()
    AND au.organization_id = v_org
    AND au.status = 'active'
    AND COALESCE(e.activo, false) = true
  LIMIT 1;

  IF v_employee_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Empleado no autorizado';
  END IF;

  v_base := public._app_role_base_permissions(v_role);

  IF v_role = 'admin' THEN
    v_effective := v_base;
  ELSE
    SELECT COALESCE(array_agg(code ORDER BY code), ARRAY[]::text[])
    INTO v_effective
    FROM unnest(v_base) AS code
    WHERE COALESCE((
      SELECT o.allowed
      FROM public.employee_permission_overrides o
      WHERE o.organization_id = v_org
        AND o.employee_id = v_employee_id
        AND o.permission_code = code
    ), true);
  END IF;

  RETURN jsonb_build_object(
    'supported', true,
    'employee_id', v_employee_id,
    'role', v_role,
    'permissions', to_jsonb(v_effective)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.get_employee_permission_settings_v1(
  p_employee_id bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_role text;
  v_base text[];
  v_permissions jsonb;
  v_codes constant text[] := ARRAY[
    'products.create',
    'products.update',
    'products.change_price',
    'inventory.receive',
    'inventory.adjust',
    'sales.create',
    'sales.discount',
    'purchases.manage',
    'reports.view_profit',
    'business.configure'
  ];
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING
      ERRCODE='42501',
      MESSAGE='Tenant administrator permission required';
  END IF;

  SELECT COALESCE(au.base_role, e.rol)
  INTO v_role
  FROM public.empleados e
  LEFT JOIN public.app_users au
    ON au.organization_id = e.organization_id
   AND au.user_id = e.app_user_id
  WHERE e.organization_id = v_org
    AND e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Empleado no encontrado';
  END IF;

  v_base := public._app_role_base_permissions(v_role);

  SELECT COALESCE(
    jsonb_object_agg(code, jsonb_build_object(
      'base_allowed', code = ANY(v_base),
      'allowed', CASE
        WHEN v_role = 'admin' THEN true
        WHEN code = ANY(v_base) THEN COALESCE((
          SELECT o.allowed
          FROM public.employee_permission_overrides o
          WHERE o.organization_id = v_org
            AND o.employee_id = p_employee_id
            AND o.permission_code = code
        ), true)
        ELSE false
      END
    )),
    '{}'::jsonb
  )
  INTO v_permissions
  FROM unnest(v_codes) AS code;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'role', lower(btrim(COALESCE(v_role, ''))),
    'permissions', v_permissions
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.update_employee_permission_overrides_v1(
  p_employee_id bigint,
  p_overrides jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_role text;
  v_base text[];
  v_key text;
  v_value jsonb;
  v_codes constant text[] := ARRAY[
    'products.create',
    'products.update',
    'products.change_price',
    'inventory.receive',
    'inventory.adjust',
    'sales.create',
    'sales.discount',
    'purchases.manage',
    'reports.view_profit',
    'business.configure'
  ];
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING
      ERRCODE='42501',
      MESSAGE='Tenant administrator permission required';
  END IF;
  IF p_overrides IS NULL OR jsonb_typeof(p_overrides) <> 'object' THEN
    RAISE EXCEPTION USING
      ERRCODE='22023',
      MESSAGE='Los permisos deben enviarse como objeto';
  END IF;

  SELECT COALESCE(au.base_role, e.rol)
  INTO v_role
  FROM public.empleados e
  LEFT JOIN public.app_users au
    ON au.organization_id = e.organization_id
   AND au.user_id = e.app_user_id
  WHERE e.organization_id = v_org
    AND e.id = p_employee_id
  FOR UPDATE OF e;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Empleado no encontrado';
  END IF;

  IF v_role = 'admin' THEN
    DELETE FROM public.employee_permission_overrides
    WHERE organization_id = v_org
      AND employee_id = p_employee_id;
    RETURN public.get_employee_permission_settings_v1(p_employee_id);
  END IF;

  v_base := public._app_role_base_permissions(v_role);

  FOR v_key, v_value IN
    SELECT key, value FROM jsonb_each(p_overrides)
  LOOP
    IF NOT (v_key = ANY(v_codes)) THEN
      RAISE EXCEPTION 'Permiso desconocido: %', v_key USING ERRCODE='22023';
    END IF;
    IF jsonb_typeof(v_value) <> 'boolean' THEN
      RAISE EXCEPTION 'El permiso % debe ser booleano', v_key USING ERRCODE='22023';
    END IF;
    IF (v_value #>> '{}')::boolean AND NOT (v_key = ANY(v_base)) THEN
      RAISE EXCEPTION 'El rol no puede recibir el permiso %', v_key USING ERRCODE='42501';
    END IF;

    IF NOT (v_key = ANY(v_base)) OR (v_value #>> '{}')::boolean THEN
      DELETE FROM public.employee_permission_overrides
      WHERE organization_id = v_org
        AND employee_id = p_employee_id
        AND permission_code = v_key;
    ELSE
      INSERT INTO public.employee_permission_overrides(
        organization_id,
        employee_id,
        permission_code,
        allowed,
        updated_at,
        updated_by
      ) VALUES (
        v_org,
        p_employee_id,
        v_key,
        false,
        now(),
        auth.uid()
      )
      ON CONFLICT (organization_id, employee_id, permission_code)
      DO UPDATE SET
        allowed = excluded.allowed,
        updated_at = excluded.updated_at,
        updated_by = excluded.updated_by;
    END IF;
  END LOOP;

  RETURN public.get_employee_permission_settings_v1(p_employee_id);
END;
$$;

REVOKE ALL ON FUNCTION public.app_tiene_permiso(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_my_effective_permissions_v1() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_employee_permission_settings_v1(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_employee_permission_overrides_v1(bigint,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.app_tiene_permiso(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_effective_permissions_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_employee_permission_settings_v1(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_employee_permission_overrides_v1(bigint,jsonb) TO authenticated;

COMMENT ON TABLE public.employee_permission_overrides IS
  'Overrides legacy tenant-owned. Se mantiene seguro hasta su reemplazo por roles/permissions configurables en F4.5.';

COMMIT;
