begin;

create extension if not exists pgtap with schema extensions;

select plan(7);

select ok(
  to_regprocedure('public.tributario_finalizar_proceso(bigint)') is null,
  'overload legacy bigint fue eliminado'
);

select ok(
  to_regprocedure('public.tributario_finalizar_proceso(uuid,uuid,text,jsonb)') is not null,
  'overload canonico UUID de cuatro parametros permanece'
);

select is(
  (
    select count(*)
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'tributario_finalizar_proceso'
  ),
  1::bigint,
  'queda una sola firma tributario_finalizar_proceso'
);

select is(
  (
    select pg_get_function_result(
      'public.tributario_finalizar_proceso(uuid,uuid,text,jsonb)'::regprocedure
    )
  ),
  'jsonb'::text,
  'firma canonica devuelve jsonb'
);

select ok(
  (
    select p.prosecdef
    from pg_proc p
    where p.oid = 'public.tributario_finalizar_proceso(uuid,uuid,text,jsonb)'::regprocedure
  ),
  'firma canonica conserva SECURITY DEFINER'
);

select ok(
  has_function_privilege(
    'service_role',
    'public.tributario_finalizar_proceso(uuid,uuid,text,jsonb)',
    'EXECUTE'
  ),
  'service_role conserva EXECUTE sobre la firma canonica'
);

select ok(
  not has_function_privilege(
    'anon',
    'public.tributario_finalizar_proceso(uuid,uuid,text,jsonb)',
    'EXECUTE'
  )
  and not has_function_privilege(
    'authenticated',
    'public.tributario_finalizar_proceso(uuid,uuid,text,jsonb)',
    'EXECUTE'
  ),
  'anon y authenticated no pueden finalizar procesos tributarios directamente'
);

select * from finish();
rollback;
