-- Fase 2.2 SaaS: RLS multi-tenant para la fundacion ya tenant-aware.
-- Las tablas operativas restantes adoptaran el mismo patron al recibir organization_id en Bloque 3.
BEGIN;

-- organizations: el cliente solo puede leer su propia organizacion activa.
ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS organizations_select_current ON public.organizations;
REVOKE ALL ON TABLE public.organizations FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.organizations TO authenticated;
CREATE POLICY organizations_select_current
ON public.organizations
FOR SELECT
TO authenticated
USING (
  id = (SELECT private.current_organization_id())
);

-- app_users: un usuario normal ve su membership; admin puede listar memberships del tenant.
ALTER TABLE public.app_users ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS app_users_select_current_tenant ON public.app_users;
REVOKE ALL ON TABLE public.app_users FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.app_users TO authenticated;
CREATE POLICY app_users_select_current_tenant
ON public.app_users
FOR SELECT
TO authenticated
USING (
  organization_id = (SELECT private.current_organization_id())
  AND (
    user_id = (SELECT auth.uid())
    OR (SELECT private.has_permission('tenant.admin'))
  )
);

-- empleados: sustituye autorizacion legacy basada en auth_id/rol.
ALTER TABLE public.empleados ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS empleados_admin_delete ON public.empleados;
DROP POLICY IF EXISTS empleados_admin_insert ON public.empleados;
DROP POLICY IF EXISTS empleados_admin_update ON public.empleados;
DROP POLICY IF EXISTS empleados_select_activos ON public.empleados;
DROP POLICY IF EXISTS empleados_tenant_select ON public.empleados;
DROP POLICY IF EXISTS empleados_tenant_insert ON public.empleados;
DROP POLICY IF EXISTS empleados_tenant_update ON public.empleados;
DROP POLICY IF EXISTS empleados_tenant_delete ON public.empleados;
REVOKE ALL ON TABLE public.empleados FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.empleados TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.empleados_id_seq TO authenticated;

CREATE POLICY empleados_tenant_select
ON public.empleados
FOR SELECT
TO authenticated
USING (
  organization_id = (SELECT private.current_organization_id())
  AND (SELECT private.has_permission('tenant.read'))
);

CREATE POLICY empleados_tenant_insert
ON public.empleados
FOR INSERT
TO authenticated
WITH CHECK (
  organization_id = (SELECT private.current_organization_id())
  AND (SELECT private.has_permission('tenant.admin'))
);

CREATE POLICY empleados_tenant_update
ON public.empleados
FOR UPDATE
TO authenticated
USING (
  organization_id = (SELECT private.current_organization_id())
  AND (SELECT private.has_permission('tenant.admin'))
)
WITH CHECK (
  organization_id = (SELECT private.current_organization_id())
  AND (SELECT private.has_permission('tenant.admin'))
);

CREATE POLICY empleados_tenant_delete
ON public.empleados
FOR DELETE
TO authenticated
USING (
  organization_id = (SELECT private.current_organization_id())
  AND (SELECT private.has_permission('tenant.admin'))
);

-- Configuracion: lectura tenant para usuarios activos; escritura directa solo admin.
ALTER TABLE public.configuracion_negocio ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS configuracion_select ON public.configuracion_negocio;
DROP POLICY IF EXISTS configuracion_tenant_select ON public.configuracion_negocio;
DROP POLICY IF EXISTS configuracion_tenant_update ON public.configuracion_negocio;
REVOKE ALL ON TABLE public.configuracion_negocio FROM PUBLIC, anon, authenticated;
GRANT SELECT, UPDATE ON TABLE public.configuracion_negocio TO authenticated;

CREATE POLICY configuracion_tenant_select
ON public.configuracion_negocio
FOR SELECT
TO authenticated
USING (
  organization_id = (SELECT private.current_organization_id())
  AND (SELECT private.has_permission('tenant.read'))
);

CREATE POLICY configuracion_tenant_update
ON public.configuracion_negocio
FOR UPDATE
TO authenticated
USING (
  organization_id = (SELECT private.current_organization_id())
  AND (SELECT private.has_permission('tenant.admin'))
)
WITH CHECK (
  organization_id = (SELECT private.current_organization_id())
  AND (SELECT private.has_permission('tenant.admin'))
);

-- Capabilities: mismo aislamiento que configuracion; bootstrap conserva INSERT privilegiado server-side.
ALTER TABLE public.business_capabilities ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS business_capabilities_read ON public.business_capabilities;
DROP POLICY IF EXISTS business_capabilities_tenant_select ON public.business_capabilities;
DROP POLICY IF EXISTS business_capabilities_tenant_update ON public.business_capabilities;
REVOKE ALL ON TABLE public.business_capabilities FROM PUBLIC, anon, authenticated;
GRANT SELECT, UPDATE ON TABLE public.business_capabilities TO authenticated;

CREATE POLICY business_capabilities_tenant_select
ON public.business_capabilities
FOR SELECT
TO authenticated
USING (
  organization_id = (SELECT private.current_organization_id())
  AND (SELECT private.has_permission('tenant.read'))
);

CREATE POLICY business_capabilities_tenant_update
ON public.business_capabilities
FOR UPDATE
TO authenticated
USING (
  organization_id = (SELECT private.current_organization_id())
  AND (SELECT private.has_permission('tenant.admin'))
)
WITH CHECK (
  organization_id = (SELECT private.current_organization_id())
  AND (SELECT private.has_permission('tenant.admin'))
);

COMMIT;
