BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(18);

SELECT ok(to_regnamespace('private') IS NOT NULL,
  'schema private existe');
SELECT ok(NOT has_schema_privilege('anon','private','USAGE'),
  'anon no tiene USAGE sobre schema private');
SELECT ok(
  has_schema_privilege('authenticated','private','USAGE')
  AND NOT has_schema_privilege('authenticated','private','CREATE'),
  'authenticated usa helpers RLS privados pero no puede crear objetos en private');

SELECT ok(to_regclass('public.organizations') IS NOT NULL,
  'organizations existe');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_class
  WHERE oid='public.organizations'::regclass AND relrowsecurity
), 'organizations mantiene RLS');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_class
  WHERE oid='public.app_users'::regclass AND relrowsecurity
), 'app_users mantiene RLS');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_class
  WHERE oid='public.observability_events'::regclass AND relrowsecurity
), 'observability_events mantiene RLS');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_class
  WHERE oid='public.audit_logs'::regclass AND relrowsecurity
), 'audit_logs mantiene RLS');

SELECT ok(NOT has_table_privilege(
  'authenticated','public.observability_events','SELECT'
), 'authenticated no lee observability ledger crudo');
SELECT ok(NOT has_table_privilege(
  'authenticated','public.audit_logs','INSERT'
), 'authenticated no inserta audit ledger directamente');

SELECT ok(NOT has_function_privilege(
  'anon',
  'public.record_observability_event_v1(uuid,uuid,text,text,text,text,integer,integer,text,uuid)',
  'EXECUTE'
), 'anon no ejecuta writer observability');
SELECT ok(NOT has_function_privilege(
  'authenticated',
  'public.record_observability_event_v1(uuid,uuid,text,text,text,text,integer,integer,text,uuid)',
  'EXECUTE'
), 'authenticated no ejecuta writer observability');
SELECT ok(has_function_privilege(
  'service_role',
  'public.record_observability_event_v1(uuid,uuid,text,text,text,text,integer,integer,text,uuid)',
  'EXECUTE'
), 'service_role sí ejecuta writer observability');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_proc
  WHERE oid='public.record_observability_event_v1(uuid,uuid,text,text,text,text,integer,integer,text,uuid)'::regprocedure
    AND prosecdef
), 'writer observability conserva SECURITY DEFINER');

SELECT ok(NOT has_function_privilege(
  'anon','public.get_observability_metrics_v1(integer)','EXECUTE'
), 'anon no ejecuta métricas tenant-admin');
SELECT ok(has_function_privilege(
  'authenticated','public.get_observability_metrics_v1(integer)','EXECUTE'
), 'authenticated sólo accede a métricas por RPC con autorización interna');
SELECT ok(NOT has_function_privilege(
  'anon','public.list_recent_observability_errors_v1(integer)','EXECUTE'
), 'anon no ejecuta listado de errores tenant-admin');
SELECT ok(has_function_privilege(
  'authenticated','public.list_recent_observability_errors_v1(integer)','EXECUTE'
), 'authenticated sólo accede a errores por RPC con autorización interna');

SELECT * FROM finish();
ROLLBACK;
