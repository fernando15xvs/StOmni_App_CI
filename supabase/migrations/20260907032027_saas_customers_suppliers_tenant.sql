-- Fase 3.2 SaaS: clientes y proveedores por organización.
-- Las filas legacy sólo se backfillean cuando existe un único tenant empresarial inequívoco.
BEGIN;

ALTER TABLE public.clientes
  ADD COLUMN organization_id uuid;

ALTER TABLE public.proveedores
  ADD COLUMN organization_id uuid;

ALTER TABLE public.clientes
  ADD CONSTRAINT clientes_organization_id_fkey
    FOREIGN KEY (organization_id)
    REFERENCES public.organizations(id)
    ON DELETE RESTRICT,
  ADD CONSTRAINT clientes_organization_id_id_key
    UNIQUE (organization_id, id);

ALTER TABLE public.proveedores
  ADD CONSTRAINT proveedores_organization_id_fkey
    FOREIGN KEY (organization_id)
    REFERENCES public.organizations(id)
    ON DELETE RESTRICT,
  ADD CONSTRAINT proveedores_organization_id_id_key
    UNIQUE (organization_id, id);

COMMENT ON COLUMN public.clientes.organization_id IS
  'Tenant propietario del cliente. Se asigna server-side para usuarios autenticados.';
COMMENT ON COLUMN public.proveedores.organization_id IS
  'Tenant propietario del proveedor. Se asigna server-side para usuarios autenticados.';

DO $backfill$
DECLARE
  v_needs_backfill boolean;
  v_organization_count integer;
  v_organization_id uuid;
BEGIN
  SELECT
    EXISTS (SELECT 1 FROM public.clientes WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.proveedores WHERE organization_id IS NULL)
  INTO v_needs_backfill;

  IF v_needs_backfill THEN
    SELECT count(DISTINCT organization_id)::integer
    INTO v_organization_count
    FROM public.configuracion_negocio;

    IF v_organization_count <> 1 THEN
      RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = 'Ambiguous legacy state: unscoped customers/suppliers require exactly one business organization';
    END IF;

    SELECT organization_id
    INTO v_organization_id
    FROM public.configuracion_negocio
    LIMIT 1;

    UPDATE public.clientes
    SET organization_id = v_organization_id
    WHERE organization_id IS NULL;

    UPDATE public.proveedores
    SET organization_id = v_organization_id
    WHERE organization_id IS NULL;
  END IF;

  IF EXISTS (SELECT 1 FROM public.clientes WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.proveedores WHERE organization_id IS NULL) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Unscoped customers or suppliers remain after tenant backfill';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.clientes
    WHERE NULLIF(btrim(dni_ruc), '') IS NOT NULL
    GROUP BY organization_id, btrim(dni_ruc)
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23505',
      MESSAGE = 'Duplicate customer document exists inside one organization';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.proveedores
    WHERE NULLIF(btrim(ruc), '') IS NOT NULL
    GROUP BY organization_id, btrim(ruc)
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23505',
      MESSAGE = 'Duplicate supplier RUC exists inside one organization';
  END IF;
END;
$backfill$;

ALTER TABLE public.clientes
  ALTER COLUMN organization_id SET NOT NULL;

ALTER TABLE public.proveedores
  ALTER COLUMN organization_id SET NOT NULL;

CREATE INDEX clientes_organization_id_idx
  ON public.clientes (organization_id);

CREATE INDEX proveedores_organization_id_idx
  ON public.proveedores (organization_id);

CREATE UNIQUE INDEX clientes_organization_document_key
  ON public.clientes (organization_id, btrim(dni_ruc))
  WHERE NULLIF(btrim(dni_ruc), '') IS NOT NULL;

CREATE UNIQUE INDEX proveedores_organization_ruc_key
  ON public.proveedores (organization_id, btrim(ruc))
  WHERE NULLIF(btrim(ruc), '') IS NOT NULL;

-- Helper reutilizable para tablas tenant-owned con INSERT directo desde Data API.
-- Usuarios normales nunca eligen el tenant: se deriva de auth.uid().
-- service_role/postgres deben suministrar organization_id explícito y no pueden
-- cambiarlo en UPDATE; esto prepara procesos backend sin abrir un bypass cliente.
CREATE OR REPLACE FUNCTION private.enforce_row_organization_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.current_organization_id();
BEGIN
  IF v_organization_id IS NULL THEN
    IF current_user IN ('service_role', 'postgres') THEN
      IF NEW.organization_id IS NULL THEN
        RAISE EXCEPTION USING
          ERRCODE = '23502',
          MESSAGE = 'Privileged tenant write requires explicit organization_id';
      END IF;

      IF TG_OP = 'UPDATE'
         AND NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
        RAISE EXCEPTION USING
          ERRCODE = '23514',
          MESSAGE = 'organization_id is immutable';
      END IF;

      RETURN NEW;
    END IF;

    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Active organization membership required';
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.organization_id IS NOT NULL
       AND NEW.organization_id IS DISTINCT FROM v_organization_id THEN
      RAISE EXCEPTION USING
        ERRCODE = '42501',
        MESSAGE = 'Cross-tenant organization_id is not allowed';
    END IF;

    NEW.organization_id := v_organization_id;
    RETURN NEW;
  END IF;

  IF NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'organization_id is immutable';
  END IF;

  IF OLD.organization_id IS DISTINCT FROM v_organization_id THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Cross-tenant update is not allowed';
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.enforce_row_organization_id()
  FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS clientes_enforce_organization_id ON public.clientes;
CREATE TRIGGER clientes_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.clientes
FOR EACH ROW
EXECUTE FUNCTION private.enforce_row_organization_id();

DROP TRIGGER IF EXISTS proveedores_enforce_organization_id ON public.proveedores;
CREATE TRIGGER proveedores_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.proveedores
FOR EACH ROW
EXECUTE FUNCTION private.enforce_row_organization_id();

ALTER TABLE public.clientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.proveedores ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS clientes_empleado_delete ON public.clientes;
DROP POLICY IF EXISTS clientes_empleado_insert ON public.clientes;
DROP POLICY IF EXISTS clientes_empleado_select ON public.clientes;
DROP POLICY IF EXISTS clientes_empleado_update ON public.clientes;

CREATE POLICY clientes_tenant_select
ON public.clientes
FOR SELECT
TO authenticated
USING (
  private.has_permission('tenant.read')
  AND private.row_belongs_to_current_organization(organization_id)
);

CREATE POLICY clientes_tenant_insert
ON public.clientes
FOR INSERT
TO authenticated
WITH CHECK (
  private.has_permission('tenant.write')
  AND private.row_belongs_to_current_organization(organization_id)
);

CREATE POLICY clientes_tenant_update
ON public.clientes
FOR UPDATE
TO authenticated
USING (
  private.has_permission('tenant.write')
  AND private.row_belongs_to_current_organization(organization_id)
)
WITH CHECK (
  private.has_permission('tenant.write')
  AND private.row_belongs_to_current_organization(organization_id)
);

CREATE POLICY clientes_tenant_delete
ON public.clientes
FOR DELETE
TO authenticated
USING (
  private.has_permission('tenant.write')
  AND private.row_belongs_to_current_organization(organization_id)
);

DROP POLICY IF EXISTS proveedores_admin_delete ON public.proveedores;
DROP POLICY IF EXISTS proveedores_admin_insert ON public.proveedores;
DROP POLICY IF EXISTS proveedores_admin_update ON public.proveedores;
DROP POLICY IF EXISTS proveedores_select ON public.proveedores;

CREATE POLICY proveedores_tenant_select
ON public.proveedores
FOR SELECT
TO authenticated
USING (
  private.has_permission('tenant.read')
  AND private.row_belongs_to_current_organization(organization_id)
);

CREATE POLICY proveedores_tenant_insert
ON public.proveedores
FOR INSERT
TO authenticated
WITH CHECK (
  private.has_permission('tenant.admin')
  AND private.row_belongs_to_current_organization(organization_id)
);

CREATE POLICY proveedores_tenant_update
ON public.proveedores
FOR UPDATE
TO authenticated
USING (
  private.has_permission('tenant.admin')
  AND private.row_belongs_to_current_organization(organization_id)
)
WITH CHECK (
  private.has_permission('tenant.admin')
  AND private.row_belongs_to_current_organization(organization_id)
);

CREATE POLICY proveedores_tenant_delete
ON public.proveedores
FOR DELETE
TO authenticated
USING (
  private.has_permission('tenant.admin')
  AND private.row_belongs_to_current_organization(organization_id)
);

REVOKE ALL ON TABLE public.clientes FROM PUBLIC, anon;
REVOKE ALL ON TABLE public.proveedores FROM PUBLIC, anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.clientes TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.proveedores TO authenticated;

COMMIT;
