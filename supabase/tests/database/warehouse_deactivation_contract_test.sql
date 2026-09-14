begin;

create extension if not exists pgtap with schema extensions;

select plan(12);

select ok(
  to_regprocedure('public.desactivar_almacen_seguro_v1(bigint)') is not null,
  'desactivar_almacen_seguro_v1 existe'
);

select ok(
  to_regprocedure('public.reactivar_almacen_seguro_v1(bigint)') is not null,
  'reactivar_almacen_seguro_v1 existe'
);

select ok(
  has_function_privilege(
    'authenticated',
    to_regprocedure('public.desactivar_almacen_seguro_v1(bigint)'),
    'EXECUTE'
  ),
  'authenticated puede invocar desactivar_almacen_seguro_v1'
);

select ok(
  not has_function_privilege(
    'anon',
    to_regprocedure('public.desactivar_almacen_seguro_v1(bigint)'),
    'EXECUTE'
  ),
  'anon no puede invocar desactivar_almacen_seguro_v1'
);

select ok(
  has_function_privilege(
    'authenticated',
    to_regprocedure('public.reactivar_almacen_seguro_v1(bigint)'),
    'EXECUTE'
  ),
  'authenticated puede invocar reactivar_almacen_seguro_v1'
);

select ok(
  not has_function_privilege(
    'anon',
    to_regprocedure('public.reactivar_almacen_seguro_v1(bigint)'),
    'EXECUTE'
  ),
  'anon no puede invocar reactivar_almacen_seguro_v1'
);

select ok(
  exists(
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'almacenes'
      and t.tgname = 'trg_validar_desactivacion_almacen_v1'
      and not t.tgisinternal
  ),
  'almacenes conserva trigger que bloquea desactivacion con stock'
);

select ok(
  exists(
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'inventario_almacen'
      and t.tgname = 'trg_validar_stock_en_almacen_activo_v1'
      and not t.tgisinternal
  ),
  'inventario_almacen bloquea stock distinto de cero en almacen inactivo'
);

select ok(
  not has_function_privilege(
    'authenticated',
    to_regprocedure('public._validar_desactivacion_almacen_v1()'),
    'EXECUTE'
  ),
  'authenticated no puede invocar directamente helper de desactivacion'
);

select ok(
  not has_function_privilege(
    'authenticated',
    to_regprocedure('public._validar_stock_en_almacen_activo_v1()'),
    'EXECUTE'
  ),
  'authenticated no puede invocar directamente helper de stock'
);

select ok(
  not has_table_privilege('authenticated', 'public.almacenes', 'DELETE'),
  'authenticated no puede borrar fisicamente almacenes'
);

select ok(
  not exists(
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'almacenes'
      and policyname = 'almacenes_admin_delete'
  ),
  'no existe policy de DELETE fisico para almacenes'
);

select * from finish();
rollback;
