begin;

create extension if not exists pgtap with schema extensions;

-- Ejecutar este test sobre el estado reconstruido hasta 20260821191000:
--   supabase db reset --local --no-seed --version 20260821191000
--   supabase test db supabase/tests/database/fase5_production_fingerprint_test.sql
--
-- Ese corte incluye el fix de alertas de stock que ya esta activo en produccion
-- aunque su version no figure en el historial remoto.

select plan(21);

select is(
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'),
  44::bigint,
  'public reconstruye 44 tablas'
);

select is(
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('v', 'm')),
  2::bigint,
  'public reconstruye 2 vistas/materialized views'
);

select is(
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'),
  74::bigint,
  'public reconstruye 74 funciones'
);

select is(
  (select count(*) from pg_trigger t
   join pg_class c on c.oid = t.tgrelid
   join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and not t.tgisinternal),
  16::bigint,
  'public reconstruye 16 triggers de usuario'
);

select is(
  (select count(*) from pg_policies where schemaname = 'public'),
  58::bigint,
  'public reconstruye 58 policies'
);

select is(
  (select count(*) from pg_indexes where schemaname = 'public'),
  145::bigint,
  'public reconstruye 145 indices'
);

select is(
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity),
  44::bigint,
  'RLS queda habilitado en las 44 tablas public'
);

select ok(exists(select 1 from pg_extension where extname = 'pg_cron'), 'pg_cron disponible');
select ok(exists(select 1 from pg_extension where extname = 'pg_net'), 'pg_net disponible');
select ok(exists(select 1 from pg_extension where extname = 'pg_stat_statements'), 'pg_stat_statements disponible');
select ok(exists(select 1 from pg_extension where extname = 'pgcrypto'), 'pgcrypto disponible');
select ok(exists(select 1 from pg_extension where extname = 'supabase_vault'), 'supabase_vault disponible');
select ok(exists(select 1 from pg_extension where extname = 'uuid-ossp'), 'uuid-ossp disponible');

select ok(
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='logos_admin_delete'),
  'Storage conserva logos_admin_delete'
);
select ok(
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='logos_admin_insert'),
  'Storage conserva logos_admin_insert'
);
select ok(
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='logos_admin_update'),
  'Storage conserva logos_admin_update'
);
select ok(
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='logos_public_select'),
  'Storage conserva logos_public_select'
);
select ok(
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='productos_imagenes_admin_delete'),
  'Storage conserva productos_imagenes_admin_delete'
);
select ok(
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='productos_imagenes_admin_insert'),
  'Storage conserva productos_imagenes_admin_insert'
);
select ok(
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='productos_imagenes_admin_update'),
  'Storage conserva productos_imagenes_admin_update'
);
select ok(
  exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='productos_imagenes_public_select'),
  'Storage conserva productos_imagenes_public_select'
);

select * from finish();
rollback;
