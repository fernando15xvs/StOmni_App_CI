BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(19);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid='public.clientes'::regclass
      AND attname='organization_id' AND NOT attisdropped AND attnotnull
  ),
  'clientes.organization_id existe y es NOT NULL'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid='public.clientes'::regclass
      AND attname='telefono' AND NOT attisdropped
  ),
  'clientes.telefono coincide con el contrato del gateway compartido'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid='public.proveedores'::regclass
      AND attname='organization_id' AND NOT attisdropped AND attnotnull
  ),
  'proveedores.organization_id existe y es NOT NULL'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.clientes'::regclass
      AND conname='clientes_organization_id_fkey'
      AND confrelid='public.organizations'::regclass
  ),
  'clientes pertenece a organizations'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.proveedores'::regclass
      AND conname='proveedores_organization_id_fkey'
      AND confrelid='public.organizations'::regclass
  ),
  'proveedores pertenece a organizations'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.clientes'::regclass
      AND conname='clientes_organization_id_id_key'
      AND contype='u'
  ),
  'clientes expone clave compuesta tenant para futuras FK'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.proveedores'::regclass
      AND conname='proveedores_organization_id_id_key'
      AND contype='u'
  ),
  'proveedores expone clave compuesta tenant para futuras FK'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public' AND tablename='clientes'
      AND indexname='clientes_organization_document_key'
      AND indexdef ILIKE '%UNIQUE%'
      AND indexdef ILIKE '%organization_id%'
      AND indexdef ILIKE '%btrim(dni_ruc)%'
  ),
  'documento de cliente es único dentro de la organización'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public' AND tablename='proveedores'
      AND indexname='proveedores_organization_ruc_key'
      AND indexdef ILIKE '%UNIQUE%'
      AND indexdef ILIKE '%organization_id%'
      AND indexdef ILIKE '%btrim(ruc)%'
  ),
  'RUC de proveedor es único dentro de la organización'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.clientes'::regclass
      AND tgname='clientes_enforce_organization_id'
      AND NOT tgisinternal
  ),
  'clientes asigna/verifica tenant mediante trigger'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.proveedores'::regclass
      AND tgname='proveedores_enforce_organization_id'
      AND NOT tgisinternal
  ),
  'proveedores asigna/verifica tenant mediante trigger'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='clientes'
      AND policyname='clientes_tenant_select'
      AND cmd='SELECT'
      AND lower(coalesce(qual,'')) LIKE '%row_belongs_to_current_organization%'
      AND lower(coalesce(qual,'')) LIKE '%organization_id%'
      AND lower(coalesce(qual,'')) LIKE '%tenant.read%'
  ),
  'clientes SELECT está aislado por tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='clientes'
      AND policyname='clientes_tenant_update'
      AND cmd='UPDATE'
      AND lower(qual) LIKE '%tenant.write%'
      AND lower(with_check) LIKE '%tenant.write%'
      AND lower(qual) LIKE '%row_belongs_to_current_organization%'
      AND lower(with_check) LIKE '%row_belongs_to_current_organization%'
  ),
  'clientes UPDATE tiene USING y WITH CHECK tenant-aware'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='proveedores'
      AND policyname='proveedores_tenant_select'
      AND cmd='SELECT'
      AND lower(coalesce(qual,'')) LIKE '%row_belongs_to_current_organization%'
      AND lower(coalesce(qual,'')) LIKE '%organization_id%'
      AND lower(coalesce(qual,'')) LIKE '%tenant.read%'
  ),
  'proveedores SELECT está aislado por tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='proveedores'
      AND policyname='proveedores_tenant_update'
      AND cmd='UPDATE'
      AND lower(qual) LIKE '%tenant.admin%'
      AND lower(with_check) LIKE '%tenant.admin%'
      AND lower(qual) LIKE '%row_belongs_to_current_organization%'
      AND lower(with_check) LIKE '%row_belongs_to_current_organization%'
  ),
  'proveedores UPDATE conserva escritura admin y tenant-aware'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='clientes'
      AND policyname IN (
        'clientes_empleado_delete','clientes_empleado_insert',
        'clientes_empleado_select','clientes_empleado_update'
      )
  ),
  'policies legacy de clientes fueron retiradas'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='proveedores'
      AND policyname IN (
        'proveedores_admin_delete','proveedores_admin_insert',
        'proveedores_admin_update','proveedores_select'
      )
  ),
  'policies legacy de proveedores fueron retiradas'
);

SELECT ok(
  NOT has_table_privilege('anon', 'public.clientes', 'SELECT')
  AND NOT has_table_privilege('anon', 'public.proveedores', 'SELECT'),
  'anon no accede a clientes/proveedores'
);

SELECT ok(
  has_table_privilege('authenticated', 'public.clientes', 'SELECT')
  AND has_table_privilege('authenticated', 'public.proveedores', 'SELECT'),
  'authenticated tiene grants explícitos y queda limitado por RLS'
);

SELECT * FROM finish();
ROLLBACK;
