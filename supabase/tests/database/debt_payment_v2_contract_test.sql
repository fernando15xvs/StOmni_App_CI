begin;

create extension if not exists pgtap with schema extensions;

-- Contrato final SaaS/F4.3 para pagos de deuda tenant/session-aware.
select plan(17);

select ok(
  to_regprocedure(
    'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'
  ) is not null
  and to_regprocedure(
    'public._legacy_procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'
  ) is null,
  'procesar_pago_deuda_v2 tenant-aware existe y la implementacion legacy fue retirada'
);

select ok(
  coalesce((
    select p.prosecdef
    from pg_proc p
    where p.oid = to_regprocedure(
      'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'
    )
  ), false),
  'procesar_pago_deuda_v2 es SECURITY DEFINER'
);

select ok(
  exists(
    select 1
    from pg_proc p
    where p.oid = to_regprocedure(
      'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'
    )
      and array_to_string(coalesce(p.proconfig, array[]::text[]), ',') = 'search_path=""'
  ),
  'procesar_pago_deuda_v2 fija search_path vacío y seguro'
);

select ok(
  position('sales.create' in lower(pg_get_functiondef(
    'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'::regprocedure
  ))) > 0
  and position('purchases.manage' in lower(pg_get_functiondef(
    'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'::regprocedure
  ))) > 0,
  'procesar_pago_deuda_v2 autoriza por permisos SaaS según tipo de deuda'
);

select ok(
  position('vendedor' in lower(pg_get_functiondef(
    'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'::regprocedure
  ))) = 0
  and position('almacenero' in lower(pg_get_functiondef(
    'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'::regprocedure
  ))) = 0
  and position('administrador' in lower(pg_get_functiondef(
    'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'::regprocedure
  ))) = 0,
  'procesar_pago_deuda_v2 no conserva roles tecnicos legacy'
);

select ok(
  has_function_privilege(
    'authenticated',
    to_regprocedure(
      'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'
    ),
    'EXECUTE'
  ),
  'authenticated puede ejecutar procesar_pago_deuda_v2'
);

select ok(
  not has_function_privilege(
    'anon',
    to_regprocedure(
      'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'
    ),
    'EXECUTE'
  ),
  'anon no puede ejecutar procesar_pago_deuda_v2'
);

select ok(to_regclass('public.pagos_deuda_requests') is not null,'pagos_deuda_requests existe');
select ok(coalesce((select c.relrowsecurity from pg_class c where c.oid=to_regclass('public.pagos_deuda_requests')),false),'pagos_deuda_requests tiene RLS habilitado');
select ok(not has_table_privilege('authenticated','public.pagos_deuda_requests','SELECT'),'authenticated no puede leer directamente pagos_deuda_requests');
select ok(not has_table_privilege('authenticated','public.pagos_deuda_requests','INSERT'),'authenticated no puede insertar directamente pagos_deuda_requests');

select ok(
  exists(
    select 1 from pg_indexes
    where schemaname='public' and tablename='pagos_venta'
      and indexname='pagos_venta_organization_request_uidx'
      and indexdef ilike '%organization_id%request_id%'
  ),
  'pagos_venta protege request_id dentro del tenant'
);

select ok(
  exists(
    select 1 from pg_indexes
    where schemaname='public' and tablename='pagos_gasto'
      and indexname='pagos_gasto_organization_request_uidx'
      and indexdef ilike '%organization_id%request_id%'
  ),
  'pagos_gasto protege request_id dentro del tenant'
);

select ok(
  position('for update' in lower(pg_get_functiondef(
    'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'::regprocedure
  ))) > 0,
  'pagos serializan la deuda/sesión con FOR UPDATE'
);

select ok(
  position('saldo insuficiente en caja' in lower(pg_get_functiondef(
    'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'::regprocedure
  ))) > 0,
  'procesar_pago_deuda_v2 valida saldo suficiente de caja'
);

select ok(
  position('cash payment date cannot be before cash session opening' in lower(pg_get_functiondef(
    'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'::regprocedure
  ))) > 0,
  'procesar_pago_deuda_v2 no permite movimientos anteriores a la apertura'
);

select ok(
  position('p_descontar_de_caja' in lower(pg_get_functiondef(
    'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'::regprocedure
  ))) > 0
  and position('v_affects_cash' in lower(pg_get_functiondef(
    'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'::regprocedure
  ))) > 0
  and position('v_is_cash' in lower(pg_get_functiondef(
    'public.procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)'::regprocedure
  ))) > 0,
  'afectación de caja se decide server-side por efectivo y tipo de deuda'
);

select * from finish();
rollback;
