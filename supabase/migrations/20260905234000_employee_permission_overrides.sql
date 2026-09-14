BEGIN;

CREATE TABLE public.employee_permission_overrides (
  employee_id bigint NOT NULL REFERENCES public.empleados(id) ON DELETE CASCADE,
  permission_code text NOT NULL,
  allowed boolean NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid NULL,
  PRIMARY KEY (employee_id, permission_code),
  CONSTRAINT employee_permission_code_known CHECK (
    permission_code = ANY (ARRAY[
      'products.create',
      'products.update',
      'products.change_price',
      'inventory.receive',
      'inventory.adjust',
      'sales.create',
      'sales.discount',
      'reports.view_profit',
      'business.configure'
    ]::text[])
  )
);

ALTER TABLE public.employee_permission_overrides ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.employee_permission_overrides FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.employee_permission_overrides TO authenticated;

CREATE OR REPLACE FUNCTION public._app_role_base_permissions(p_role text)
RETURNS text[]
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $function$
  SELECT CASE lower(trim(coalesce(p_role, '')))
    WHEN 'admin' THEN ARRAY[
      'products.create',
      'products.update',
      'products.change_price',
      'inventory.receive',
      'inventory.adjust',
      'sales.create',
      'sales.discount',
      'reports.view_profit',
      'business.configure'
    ]::text[]
    WHEN 'administrador' THEN ARRAY[
      'products.create',
      'products.update',
      'products.change_price',
      'inventory.receive',
      'inventory.adjust',
      'sales.create',
      'sales.discount',
      'reports.view_profit',
      'business.configure'
    ]::text[]
    WHEN 'operador' THEN ARRAY[
      'inventory.receive',
      'sales.create',
      'sales.discount'
    ]::text[]
    ELSE ARRAY[]::text[]
  END;
$function$;

CREATE OR REPLACE FUNCTION public.app_tiene_permiso(p_permission_code text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_employee_id bigint;
  v_role text;
  v_base text[];
  v_override boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN false;
  END IF;

  SELECT e.id, e.rol
  INTO v_employee_id, v_role
  FROM public.empleados e
  WHERE e.auth_id = auth.uid()
    AND e.activo = true
  LIMIT 1;

  IF v_employee_id IS NULL THEN
    RETURN false;
  END IF;

  v_base := public._app_role_base_permissions(v_role);
  IF NOT (p_permission_code = ANY(v_base)) THEN
    RETURN false;
  END IF;

  -- Admin no puede quedar accidentalmente bloqueado por un override antiguo.
  IF lower(trim(coalesce(v_role, ''))) IN ('admin', 'administrador') THEN
    RETURN true;
  END IF;

  SELECT o.allowed
  INTO v_override
  FROM public.employee_permission_overrides o
  WHERE o.employee_id = v_employee_id
    AND o.permission_code = p_permission_code;

  RETURN coalesce(v_override, true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_my_effective_permissions_v1()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_employee_id bigint;
  v_role text;
  v_base text[];
  v_effective text[];
BEGIN
  SELECT e.id, e.rol
  INTO v_employee_id, v_role
  FROM public.empleados e
  WHERE e.auth_id = auth.uid()
    AND e.activo = true
  LIMIT 1;

  IF v_employee_id IS NULL THEN
    RAISE EXCEPTION 'Empleado no autorizado' USING ERRCODE = '42501';
  END IF;

  v_base := public._app_role_base_permissions(v_role);

  IF lower(trim(coalesce(v_role, ''))) IN ('admin', 'administrador') THEN
    v_effective := v_base;
  ELSE
    SELECT coalesce(array_agg(code ORDER BY code), ARRAY[]::text[])
    INTO v_effective
    FROM unnest(v_base) AS code
    WHERE coalesce((
      SELECT o.allowed
      FROM public.employee_permission_overrides o
      WHERE o.employee_id = v_employee_id
        AND o.permission_code = code
    ), true);
  END IF;

  RETURN jsonb_build_object(
    'supported', true,
    'employee_id', v_employee_id,
    'role', lower(trim(v_role)),
    'permissions', to_jsonb(v_effective)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_employee_permission_settings_v1(p_employee_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_role text;
  v_base text[];
  v_permissions jsonb;
BEGIN
  IF NOT public.app_es_admin() THEN
    RAISE EXCEPTION 'Solo el administrador puede consultar permisos de empleados'
      USING ERRCODE = '42501';
  END IF;

  SELECT e.rol INTO v_role
  FROM public.empleados e
  WHERE e.id = p_employee_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Empleado no encontrado' USING ERRCODE = 'P0002';
  END IF;

  v_base := public._app_role_base_permissions(v_role);

  SELECT coalesce(
    jsonb_object_agg(code, jsonb_build_object(
      'base_allowed', code = ANY(v_base),
      'allowed', CASE
        WHEN lower(trim(coalesce(v_role, ''))) IN ('admin', 'administrador') THEN true
        WHEN code = ANY(v_base) THEN coalesce((
          SELECT o.allowed
          FROM public.employee_permission_overrides o
          WHERE o.employee_id = p_employee_id
            AND o.permission_code = code
        ), true)
        ELSE false
      END
    )),
    '{}'::jsonb
  )
  INTO v_permissions
  FROM unnest(ARRAY[
    'products.create',
    'products.update',
    'products.change_price',
    'inventory.receive',
    'inventory.adjust',
    'sales.create',
    'sales.discount',
    'reports.view_profit',
    'business.configure'
  ]::text[]) AS code;

  RETURN jsonb_build_object(
    'employee_id', p_employee_id,
    'role', lower(trim(v_role)),
    'permissions', v_permissions
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_employee_permission_overrides_v1(
  p_employee_id bigint,
  p_overrides jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_role text;
  v_base text[];
  v_key text;
  v_value jsonb;
BEGIN
  IF NOT public.app_es_admin() THEN
    RAISE EXCEPTION 'Solo el administrador puede modificar permisos de empleados'
      USING ERRCODE = '42501';
  END IF;
  IF p_overrides IS NULL OR jsonb_typeof(p_overrides) <> 'object' THEN
    RAISE EXCEPTION 'Los permisos deben enviarse como objeto' USING ERRCODE = '22023';
  END IF;

  SELECT e.rol INTO v_role
  FROM public.empleados e
  WHERE e.id = p_employee_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Empleado no encontrado' USING ERRCODE = 'P0002';
  END IF;

  IF lower(trim(coalesce(v_role, ''))) IN ('admin', 'administrador') THEN
    DELETE FROM public.employee_permission_overrides
    WHERE employee_id = p_employee_id;
    RETURN public.get_employee_permission_settings_v1(p_employee_id);
  END IF;

  v_base := public._app_role_base_permissions(v_role);

  FOR v_key, v_value IN SELECT key, value FROM jsonb_each(p_overrides) LOOP
    IF NOT (v_key = ANY(ARRAY[
      'products.create',
      'products.update',
      'products.change_price',
      'inventory.receive',
      'inventory.adjust',
      'sales.create',
      'sales.discount',
      'reports.view_profit',
      'business.configure'
    ]::text[])) THEN
      RAISE EXCEPTION 'Permiso desconocido: %', v_key USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_value) <> 'boolean' THEN
      RAISE EXCEPTION 'El permiso % debe ser booleano', v_key USING ERRCODE = '22023';
    END IF;
    IF (v_value #>> '{}')::boolean AND NOT (v_key = ANY(v_base)) THEN
      RAISE EXCEPTION 'El rol no puede recibir el permiso %', v_key USING ERRCODE = '42501';
    END IF;

    IF NOT (v_key = ANY(v_base)) OR (v_value #>> '{}')::boolean THEN
      DELETE FROM public.employee_permission_overrides
      WHERE employee_id = p_employee_id
        AND permission_code = v_key;
    ELSE
      INSERT INTO public.employee_permission_overrides(
        employee_id, permission_code, allowed, updated_at, updated_by
      ) VALUES (
        p_employee_id, v_key, false, now(), auth.uid()
      )
      ON CONFLICT (employee_id, permission_code) DO UPDATE SET
        allowed = excluded.allowed,
        updated_at = excluded.updated_at,
        updated_by = excluded.updated_by;
    END IF;
  END LOOP;

  RETURN public.get_employee_permission_settings_v1(p_employee_id);
END;
$function$;

CREATE POLICY employee_permission_read ON public.employee_permission_overrides
FOR SELECT TO authenticated
USING (
  public.app_es_admin()
  OR employee_id = (
    SELECT e.id FROM public.empleados e
    WHERE e.auth_id = auth.uid() AND e.activo = true
    LIMIT 1
  )
);

REVOKE ALL ON FUNCTION public._app_role_base_permissions(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.app_tiene_permiso(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_my_effective_permissions_v1() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_employee_permission_settings_v1(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_employee_permission_overrides_v1(bigint,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.app_tiene_permiso(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_effective_permissions_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_employee_permission_settings_v1(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_employee_permission_overrides_v1(bigint,jsonb) TO authenticated;

COMMIT;
