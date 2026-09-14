begin;

create extension if not exists pgtap with schema extensions;

-- Huella del dump public de produccion obtenido con:
-- supabase db dump --linked --schema public
-- SHA-256 observado el 2026-08-21:
-- A274BEE6A36515C529C379A908A620FFF3728326E7815272D385DBEED1CE3275
--
-- Este contrato NO valida auth/storage administrados por Supabase. Su objetivo
-- es comprobar que el laboratorio local recibio el esquema public exacto antes
-- de aplicar las migraciones nuevas de Fase 5.

select plan(16);

select is(
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'),
  44::bigint,
  'snapshot public contiene 44 tablas'
);

select is(
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('v', 'm')),
  2::bigint,
  'snapshot public contiene 2 vistas'
);

select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'),
  74::bigint,
  'snapshot public contiene 74 funciones'
);

select is(
  (select count(*) from pg_trigger t
   join pg_class c on c.oid = t.tgrelid
   join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and not t.tgisinternal),
  16::bigint,
  'snapshot public contiene 16 triggers de usuario'
);

select is(
  (select count(*) from pg_policies where schemaname = 'public'),
  58::bigint,
  'snapshot public contiene 58 policies'
);

select is(
  (select count(*) from pg_indexes where schemaname = 'public'),
  145::bigint,
  'snapshot public contiene 145 indices'
);

select is(
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity),
  44::bigint,
  'RLS esta habilitado en las 44 tablas public'
);

select ok(
  to_regprocedure('public.process_sale_v3(uuid,bigint,numeric,timestamp with time zone,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)') is not null,
  'process_sale_v3 existe en el snapshot'
);

select ok(
  to_regprocedure('public.guardar_guia_remision_v4(uuid,uuid,boolean,text,text,bigint,bigint,uuid,text,text,text,text,text,timestamp with time zone,timestamp with time zone,jsonb,jsonb,jsonb,jsonb,bigint,bigint,bigint,numeric,integer,boolean,text,jsonb,boolean,bigint,bigint,bigint,text)') is not null,
  'guardar_guia_remision_v4 existe en el snapshot'
);

select ok(
  to_regprocedure('public.app_empleado_activo()') is not null,
  'helper app_empleado_activo existe'
);

select ok(
  exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'inventario_almacen'
      and t.tgname = 'trigger_stock_alert_acumular_tx'
      and not t.tgisinternal
  ),
  'snapshot incluye acumulador transaccional de alertas de stock'
);

select ok(
  exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'inventario_almacen'
      and t.tgname = 'trigger_stock_alert_evaluar_tx'
      and t.tgdeferrable
      and t.tginitdeferred
      and not t.tgisinternal
  ),
  'snapshot incluye evaluador de stock diferido hasta commit'
);

select ok(
  exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'clientes'
      and policyname = 'Permitir todo en clientes'
      and coalesce(qual, '') = 'true'
      and coalesce(with_check, '') = 'true'
  ),
  'snapshot conserva policy permisiva de clientes que Fase 5 debe cerrar'
);

select ok(
  exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'transferencias_stock'
      and policyname = 'Permitir todo en transferencias_stock'
      and coalesce(qual, '') = 'true'
      and coalesce(with_check, '') = 'true'
  ),
  'snapshot conserva policy permisiva de transferencias que Fase 5 debe cerrar'
);

select ok(
  (select reloptions @> array['security_invoker=true']
   from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'movimientos'),
  'vista movimientos usa security_invoker'
);

select ok(
  (select reloptions @> array['security_invoker=true']
   from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'reportes_movimientos_financieros'),
  'vista reportes_movimientos_financieros usa security_invoker'
);

select * from finish();
rollback;
