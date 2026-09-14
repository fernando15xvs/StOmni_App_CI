begin;

create extension if not exists pgtap with schema extensions;

select plan(14);

select has_function(
  'public',
  'eliminar_pago_gasto_v1',
  array['bigint', 'bigint'],
  'existe RPC atomica para eliminar pago de gasto'
);

select has_function(
  'public',
  'eliminar_gasto_v1',
  array['bigint'],
  'existe RPC atomica para eliminar gasto completo'
);

select function_returns(
  'public',
  'eliminar_pago_gasto_v1',
  array['bigint', 'bigint'],
  'jsonb',
  'eliminar_pago_gasto_v1 retorna jsonb'
);

select function_returns(
  'public',
  'eliminar_gasto_v1',
  array['bigint'],
  'jsonb',
  'eliminar_gasto_v1 retorna jsonb'
);

select ok(
  (select p.prosecdef
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public'
     and p.proname='eliminar_pago_gasto_v1'
     and pg_get_function_identity_arguments(p.oid)='p_pago_id bigint, p_gasto_id bigint'),
  'eliminar_pago_gasto_v1 es SECURITY DEFINER'
);

select ok(
  (select p.prosecdef
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public'
     and p.proname='eliminar_gasto_v1'
     and pg_get_function_identity_arguments(p.oid)='p_gasto_id bigint'),
  'eliminar_gasto_v1 es SECURITY DEFINER'
);

select is(
  (select array_to_string(p.proconfig, ',')
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public'
     and p.proname='eliminar_pago_gasto_v1'
     and pg_get_function_identity_arguments(p.oid)='p_pago_id bigint, p_gasto_id bigint'),
  'search_path=""',
  'eliminar_pago_gasto_v1 fija search_path vacío y seguro'
);

select is(
  (select array_to_string(p.proconfig, ',')
   from pg_proc p
   join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public'
     and p.proname='eliminar_gasto_v1'
     and pg_get_function_identity_arguments(p.oid)='p_gasto_id bigint'),
  'search_path=""',
  'eliminar_gasto_v1 fija search_path vacío y seguro'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.eliminar_pago_gasto_v1(bigint,bigint)',
    'EXECUTE'
  ),
  'authenticated puede ejecutar eliminar_pago_gasto_v1'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.eliminar_pago_gasto_v1(bigint,bigint)',
    'EXECUTE'
  ),
  'anon no puede ejecutar eliminar_pago_gasto_v1'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.eliminar_gasto_v1(bigint)',
    'EXECUTE'
  ),
  'authenticated puede ejecutar eliminar_gasto_v1'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.eliminar_gasto_v1(bigint)',
    'EXECUTE'
  ),
  'anon no puede ejecutar eliminar_gasto_v1'
);

select is(
  (select rc.delete_rule
   from information_schema.referential_constraints rc
   join information_schema.table_constraints tc
     on tc.constraint_name=rc.constraint_name
    and tc.constraint_schema=rc.constraint_schema
   join information_schema.key_column_usage kcu
     on kcu.constraint_name=tc.constraint_name
    and kcu.constraint_schema=tc.constraint_schema
   where tc.constraint_schema='public'
     and tc.table_name='pagos_gasto'
     and kcu.column_name='gasto_id'
   limit 1),
  'CASCADE',
  'pagos_gasto se elimina en cascada al borrar gasto'
);

select ok(
  position('private.has_permission(''tenant.write'')' in lower(pg_get_functiondef(
    'public.eliminar_gasto_v1(bigint)'::regprocedure
  ))) > 0
  and position('private.assert_expense_in_current_organization' in lower(pg_get_functiondef(
    'public.eliminar_gasto_v1(bigint)'::regprocedure
  ))) > 0
  and position('private.has_permission(''tenant.write'')' in lower(pg_get_functiondef(
    'public.eliminar_pago_gasto_v1(bigint,bigint)'::regprocedure
  ))) > 0
  and position('private.assert_expense_payment_in_current_organization' in lower(pg_get_functiondef(
    'public.eliminar_pago_gasto_v1(bigint,bigint)'::regprocedure
  ))) > 0,
  'ambas RPC exigen permiso y validan ownership del tenant'
);

select * from finish();
rollback;
