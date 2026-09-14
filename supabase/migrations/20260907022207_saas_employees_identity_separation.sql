-- Fase 1.3 SaaS: separar la ficha de empleado de la identidad de acceso.
-- Expand/contract: se conserva empleados.auth_id temporalmente para compatibilidad legacy.
BEGIN;

ALTER TABLE public.empleados
  ADD COLUMN organization_id uuid,
  ADD COLUMN app_user_id uuid;

COMMENT ON COLUMN public.empleados.organization_id IS
  'Tenant propietario del empleado. Se volvera NOT NULL despues del backfill controlado.';
COMMENT ON COLUMN public.empleados.app_user_id IS
  'Acceso StOmni opcional del empleado. NULL significa empleado sin cuenta de acceso.';
COMMENT ON COLUMN public.empleados.auth_id IS
  'LEGACY transitorio. No es la fuente canonica de autorizacion multi-tenant.';

ALTER TABLE public.empleados
  ADD CONSTRAINT empleados_organization_id_fkey
    FOREIGN KEY (organization_id)
    REFERENCES public.organizations(id)
    ON DELETE RESTRICT,
  ADD CONSTRAINT empleados_app_user_id_key
    UNIQUE (app_user_id),
  ADD CONSTRAINT empleados_organization_app_user_fkey
    FOREIGN KEY (organization_id, app_user_id)
    REFERENCES public.app_users(organization_id, user_id)
    ON DELETE RESTRICT,
  ADD CONSTRAINT empleados_organization_required
    CHECK (organization_id IS NOT NULL) NOT VALID,
  ADD CONSTRAINT empleados_auth_app_user_consistent
    CHECK (
      auth_id IS NULL
      OR app_user_id IS NULL
      OR auth_id = app_user_id
    ) NOT VALID;

-- La unicidad del correo deja de ser global: una misma direccion de contacto
-- puede existir en empresas distintas. NULLS NOT DISTINCT conserva la proteccion
-- entre filas legacy aun no backfilleadas (organization_id NULL).
ALTER TABLE public.empleados
  DROP CONSTRAINT IF EXISTS empleados_email_key;

CREATE UNIQUE INDEX empleados_organization_email_key
  ON public.empleados (organization_id, email) NULLS NOT DISTINCT
  WHERE email IS NOT NULL;

CREATE INDEX empleados_organization_id_idx
  ON public.empleados (organization_id);

-- Las funciones legacy enlazaban Auth -> empleado buscando solamente el email.
-- En multi-tenant ese criterio es ambiguo y puede vincular la empresa equivocada.
-- Se conservan como no-op durante expand/contract para no romper posibles triggers
-- históricos; el enlace nuevo debe hacerse explícitamente mediante app_user_id.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.vincular_usuario_empleado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.vincular_usuario_empleado() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.handle_new_user() IS
  'LEGACY no-op: el email ya no vincula automaticamente Auth con empleados.';
COMMENT ON FUNCTION public.vincular_usuario_empleado() IS
  'LEGACY no-op: el enlace de acceso debe ser tenant-aware mediante app_users/app_user_id.';

COMMIT;
