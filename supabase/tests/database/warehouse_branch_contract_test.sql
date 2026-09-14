BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(10);

SELECT ok(EXISTS(
  SELECT 1 FROM pg_attribute
  WHERE attrelid='public.almacenes'::regclass
    AND attname='branch_id' AND attnotnull AND NOT attisdropped
), 'almacenes.branch_id existe y es NOT NULL');

SELECT ok(EXISTS(
  SELECT 1 FROM pg_constraint
  WHERE conrelid='public.almacenes'::regclass
    AND conname='almacenes_organization_branch_fkey'
    AND confrelid='public.branches'::regclass
), 'almacenes usa FK tenant-qualified a branches');

SELECT ok(EXISTS(
  SELECT 1 FROM pg_indexes
  WHERE schemaname='public' AND tablename='almacenes'
    AND indexname='almacenes_organization_branch_active_idx'
    AND indexdef ILIKE '%organization_id%branch_id%activo%'
), 'índice tenant/branch/activo existe');

SELECT ok(EXISTS(
  SELECT 1 FROM pg_trigger
  WHERE tgrelid='public.almacenes'::regclass
    AND tgname='zz_almacenes_enforce_branch'
    AND NOT tgisinternal
), 'trigger de branch en almacenes existe');

SELECT ok(
  position('private.current_organization_id()' in pg_get_functiondef('private.enforce_warehouse_branch()'::regprocedure)) > 0,
  'trigger deriva tenant desde sesión'
);

SELECT ok(
  position('b.organization_id=v_org' in replace(pg_get_functiondef('private.enforce_warehouse_branch()'::regprocedure),' ','')) > 0,
  'trigger valida branch dentro de organization'
);

SELECT ok(NOT EXISTS(
  SELECT 1 FROM public.almacenes a
  JOIN public.branches b ON b.id=a.branch_id
  WHERE a.organization_id IS DISTINCT FROM b.organization_id
), 'no hay almacenes asociados a branch de otro tenant');

SELECT ok(NOT EXISTS(
  SELECT 1 FROM public.almacenes WHERE branch_id IS NULL
), 'no quedan almacenes sin sucursal');

SELECT ok(
  position('Branch has active warehouses' in pg_get_functiondef('public.update_branch_v1(uuid,text,text,text)'::regprocedure)) > 0,
  'no se desactiva una sucursal con almacenes activos'
);

SELECT ok(
  has_function_privilege('authenticated','public.update_branch_v1(uuid,text,text,text)','EXECUTE'),
  'authenticated actualiza branch sólo mediante RPC'
);

SELECT * FROM finish();
ROLLBACK;
