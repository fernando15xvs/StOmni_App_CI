-- Fase 2.1 SaaS: helpers canonicos de autorizacion multi-tenant.
-- La lectura privilegiada de membership vive fuera del schema public expuesto.
BEGIN;

CREATE SCHEMA IF NOT EXISTS private;

REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA private TO authenticated;

-- Evita que futuras funciones creadas por el mismo owner nazcan ejecutables por PUBLIC.
ALTER DEFAULT PRIVILEGES IN SCHEMA private
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE OR REPLACE FUNCTION private.current_organization_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT au.organization_id
  FROM public.app_users AS au
  JOIN public.organizations AS o
    ON o.id = au.organization_id
  WHERE au.user_id = (SELECT auth.uid())
    AND au.status = 'active'
    AND o.status = 'active'
$$;

COMMENT ON FUNCTION private.current_organization_id() IS
  'Tenant efectivo del usuario autenticado. Devuelve NULL si no hay membership activa o la organizacion no esta activa.';

CREATE OR REPLACE FUNCTION private.is_active_user()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT (SELECT private.current_organization_id()) IS NOT NULL
$$;

COMMENT ON FUNCTION private.is_active_user() IS
  'True solo cuando auth.uid() tiene app_user activo dentro de una organizacion activa.';

CREATE OR REPLACE FUNCTION private.current_base_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT au.base_role
  FROM public.app_users AS au
  JOIN public.organizations AS o
    ON o.id = au.organization_id
  WHERE au.user_id = (SELECT auth.uid())
    AND au.status = 'active'
    AND o.status = 'active'
$$;

COMMENT ON FUNCTION private.current_base_role() IS
  'Rol base V1 del usuario autenticado dentro de su tenant activo.';

CREATE OR REPLACE FUNCTION private.has_permission(p_permission text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT CASE lower(btrim(p_permission))
    WHEN 'tenant.read' THEN (SELECT private.current_base_role()) IN ('admin', 'operador')
    WHEN 'tenant.write' THEN (SELECT private.current_base_role()) IN ('admin', 'operador')
    WHEN 'tenant.admin' THEN (SELECT private.current_base_role()) = 'admin'
    ELSE false
  END
$$;

COMMENT ON FUNCTION private.has_permission(text) IS
  'Contrato transitorio de permisos V1. Fase 4.5 podra cambiar la implementacion sin cambiar los call-sites de RLS/RPC.';

CREATE OR REPLACE FUNCTION private.row_belongs_to_current_organization(
  p_organization_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT p_organization_id IS NOT NULL
     AND p_organization_id = (SELECT private.current_organization_id())
$$;

COMMENT ON FUNCTION private.row_belongs_to_current_organization(uuid) IS
  'True solo si el organization_id de una fila pertenece al tenant efectivo autenticado.';

CREATE OR REPLACE FUNCTION private.require_current_organization_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.current_organization_id();
BEGIN
  IF v_organization_id IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Active organization membership required';
  END IF;

  RETURN v_organization_id;
END;
$$;

COMMENT ON FUNCTION private.require_current_organization_id() IS
  'RPC helper: devuelve el tenant efectivo o aborta si el usuario no tiene acceso empresarial activo.';

REVOKE ALL ON FUNCTION private.current_organization_id()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.is_active_user()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.current_base_role()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.has_permission(text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.row_belongs_to_current_organization(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.require_current_organization_id()
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION private.current_organization_id() TO authenticated;
GRANT EXECUTE ON FUNCTION private.is_active_user() TO authenticated;
GRANT EXECUTE ON FUNCTION private.current_base_role() TO authenticated;
GRANT EXECUTE ON FUNCTION private.has_permission(text) TO authenticated;
GRANT EXECUTE ON FUNCTION private.row_belongs_to_current_organization(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION private.require_current_organization_id() TO authenticated;

COMMIT;
