BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(16);

SELECT has_table('public', 'branches', 'branches existe');

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid='public.branches'::regclass
      AND attname='organization_id' AND NOT attisdropped AND attnotnull
  ),
  'branches.organization_id es NOT NULL'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.branches'::regclass
      AND conname='branches_organization_id_fkey'
      AND confrelid='public.organizations'::regclass
  ),
  'branches pertenece a organizations'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.branches'::regclass
      AND conname='branches_organization_id_id_key'
      AND contype='u'
  ),
  'branches expone clave compuesta tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public' AND tablename='branches'
      AND indexname='branches_organization_code_key'
      AND indexdef ILIKE '%UNIQUE%'
      AND indexdef ILIKE '%organization_id%'
      AND indexdef ILIKE '%code%'
  ),
  'código de sucursal es único por organización'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public' AND tablename='branches'
      AND indexname='branches_one_main_per_organization_key'
      AND indexdef ILIKE '%UNIQUE%'
      AND indexdef ILIKE '%WHERE is_main%'
  ),
  'como máximo una sucursal principal por organización'
);

SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid='public.branches'::regclass),
  'branches tiene RLS habilitado'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='branches'
      AND policyname='branches_tenant_select'
      AND cmd='SELECT'
      AND lower(qual) LIKE '%private.row_belongs_to_current_organization(organization_id)%'
  ),
  'SELECT de branches está aislado por tenant'
);

SELECT ok(
  has_table_privilege('authenticated', 'public.branches', 'SELECT'),
  'authenticated puede leer branches vía RLS'
);

SELECT ok(
  NOT has_table_privilege('authenticated', 'public.branches', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'public.branches', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'public.branches', 'DELETE'),
  'authenticated no tiene escritura directa sobre branches'
);

SELECT has_function(
  'public', 'create_branch_v1', ARRAY['text','text','text'],
  'create_branch_v1 existe'
);

SELECT has_function(
  'public', 'update_branch_v1', ARRAY['uuid','text','text','text'],
  'update_branch_v1 existe'
);

SELECT has_function(
  'public', 'set_main_branch_v1', ARRAY['uuid'],
  'set_main_branch_v1 existe'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.create_branch_v1(text,text,text)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.update_branch_v1(uuid,text,text,text)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.set_main_branch_v1(uuid)', 'EXECUTE'),
  'authenticated sólo muta sucursales mediante RPC allowlisted'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.organizations'::regclass
      AND tgname='trg_organization_create_main_branch'
      AND NOT tgisinternal
  ),
  'nuevas organizaciones crean sucursal principal automáticamente'
);

SELECT ok(
  NOT EXISTS (
    SELECT organization_id
    FROM public.branches
    WHERE is_main
    GROUP BY organization_id
    HAVING count(*) > 1
  ),
  'no existen dos sucursales principales en la misma organización'
);

SELECT * FROM finish();
ROLLBACK;
