BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(22);

SELECT ok(to_regclass('public.observability_events') IS NOT NULL,
  'observability_events existe');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_class
  WHERE oid='public.observability_events'::regclass AND relrowsecurity
), 'observability_events tiene RLS habilitado');
SELECT ok(NOT has_table_privilege('authenticated','public.observability_events','SELECT'),
  'authenticated no puede leer ledger crudo');
SELECT ok(NOT has_table_privilege('authenticated','public.observability_events','INSERT'),
  'authenticated no puede insertar ledger crudo');
SELECT ok(NOT has_table_privilege('authenticated','public.observability_events','UPDATE'),
  'authenticated no puede modificar ledger crudo');
SELECT ok(NOT has_table_privilege('authenticated','public.observability_events','DELETE'),
  'authenticated no puede borrar ledger crudo');
SELECT ok(NOT EXISTS(
  SELECT 1
  FROM pg_attribute
  WHERE attrelid='public.observability_events'::regclass
    AND NOT attisdropped
    AND lower(attname) = ANY(ARRAY[
      'body','payload','metadata','message','error_message','email','document',
      'document_number','token','authorization','cookie','secret','name'
    ])
), 'ledger no tiene columnas libres o de PII/secreto');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_indexes
  WHERE schemaname='public' AND tablename='observability_events'
    AND indexname='observability_events_org_time_idx'
), 'índice tenant/tiempo existe');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_indexes
  WHERE schemaname='public' AND tablename='observability_events'
    AND indexname='observability_events_trace_time_idx'
), 'índice trace/tiempo existe');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_indexes
  WHERE schemaname='public' AND tablename='observability_events'
    AND indexname='observability_events_job_time_idx'
), 'índice job/tiempo existe');

SELECT ok(to_regprocedure(
  'public.record_observability_event_v1(uuid,uuid,text,text,text,text,integer,integer,text,uuid)'
) IS NOT NULL, 'writer observability v1 existe');
SELECT ok(has_function_privilege(
  'service_role',
  'public.record_observability_event_v1(uuid,uuid,text,text,text,text,integer,integer,text,uuid)',
  'EXECUTE'
), 'service_role puede ejecutar writer');
SELECT ok(NOT has_function_privilege(
  'authenticated',
  'public.record_observability_event_v1(uuid,uuid,text,text,text,text,integer,integer,text,uuid)',
  'EXECUTE'
), 'authenticated no puede ejecutar writer');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_proc p
  WHERE p.oid='public.record_observability_event_v1(uuid,uuid,text,text,text,text,integer,integer,text,uuid)'::regprocedure
    AND p.prosecdef
), 'writer usa SECURITY DEFINER y autorización por EXECUTE, no current_user interno');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_proc p
  WHERE p.oid='public.record_observability_event_v1(uuid,uuid,text,text,text,text,integer,integer,text,uuid)'::regprocedure
    AND lower(pg_get_function_arguments(p.oid)) NOT SIMILAR TO '%(body|payload|metadata|message|email|document|token|secret)%'
), 'firma writer no acepta payload, PII ni secretos');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_proc p
  WHERE p.oid='public.record_observability_event_v1(uuid,uuid,text,text,text,text,integer,integer,text,uuid)'::regprocedure
    AND lower(pg_get_functiondef(p.oid)) LIKE '%invalid sanitized observability event%'
    AND lower(pg_get_functiondef(p.oid)) LIKE '%error_code%'
), 'writer valida allowlist técnica antes de persistir');

SELECT ok(to_regprocedure('public.get_observability_metrics_v1(integer)') IS NOT NULL,
  'RPC de métricas observability existe');
SELECT ok(has_function_privilege(
  'authenticated','public.get_observability_metrics_v1(integer)','EXECUTE'
), 'authenticated puede invocar métricas vía RPC');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_proc p
  WHERE p.oid='public.get_observability_metrics_v1(integer)'::regprocedure
    AND lower(pg_get_functiondef(p.oid)) LIKE '%tenant.admin%'
    AND lower(pg_get_functiondef(p.oid)) LIKE '%organization_id=v_org%'
), 'métricas exigen tenant.admin y filtran por tenant');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_proc p
  WHERE p.oid='public.get_observability_metrics_v1(integer)'::regprocedure
    AND lower(pg_get_functiondef(p.oid)) LIKE '%percentile_cont(0.50)%'
    AND lower(pg_get_functiondef(p.oid)) LIKE '%percentile_cont(0.95)%'
    AND lower(pg_get_functiondef(p.oid)) LIKE '%percentile_cont(0.99)%'
), 'métricas calculan p50/p95/p99');

SELECT ok(to_regprocedure('public.list_recent_observability_errors_v1(integer)') IS NOT NULL,
  'RPC de errores observability existe');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_proc p
  WHERE p.oid='public.list_recent_observability_errors_v1(integer)'::regprocedure
    AND has_function_privilege('authenticated',p.oid,'EXECUTE')
    AND lower(pg_get_functiondef(p.oid)) LIKE '%tenant.admin%'
    AND lower(pg_get_functiondef(p.oid)) LIKE '%e.organization_id=v_org%'
    AND lower(pg_get_function_result(p.oid)) NOT SIMILAR TO '%(body|payload|metadata|message|email|document|token|secret)%'
), 'errores recientes son tenant-admin y sólo exponen campos sanitizados');

SELECT * FROM finish();
ROLLBACK;
