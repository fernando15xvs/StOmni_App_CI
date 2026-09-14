BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(30);

SELECT ok(to_regclass('public.business_metric_definitions') IS NOT NULL,'business_metric_definitions existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.business_metric_definitions'::regclass AND attname='organization_id' AND attnotnull AND NOT attisdropped),'organization_id NOT NULL');
SELECT ok(NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.business_metric_definitions'::regclass AND attname='business_id' AND NOT attisdropped),'business_id retirado');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.business_metric_definitions'::regclass AND contype='p' AND pg_get_constraintdef(oid) ILIKE '%organization_id%source_key%'),'PK tenant+source');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.business_metric_definitions'::regclass AND contype='u' AND pg_get_constraintdef(oid) ILIKE '%organization_id%position%'),'posición única por tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.business_metric_definitions'::regclass AND contype='f' AND pg_get_constraintdef(oid) ILIKE '%organizations(id)%'),'FK organization');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.business_metric_definitions'::regclass AND pg_get_constraintdef(oid) ILIKE '%sales_revenue%gross_margin%inventory_turnover%dead_inventory_items%accounts_receivable%cash_performance_percent%'),'catálogo KPI extendido');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.organizations'::regclass AND tgname='organizations_create_default_business_metrics' AND NOT tgisinternal),'nuevos tenants reciben métricas');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.business_metric_definitions'::regclass AND tgname='business_metric_definitions_audit_change' AND NOT tgisinternal),'cambios de métricas auditados');
SELECT ok(NOT has_table_privilege('authenticated','public.business_metric_definitions','INSERT'),'authenticated sin INSERT directo');
SELECT ok(NOT has_table_privilege('authenticated','public.business_metric_definitions','UPDATE'),'authenticated sin UPDATE directo');
SELECT ok(NOT has_table_privilege('authenticated','public.business_metric_definitions','DELETE'),'authenticated sin DELETE directo');

SELECT ok(to_regprocedure('public.list_business_metrics_v1()') IS NOT NULL,'list_business_metrics_v1 existe');
SELECT ok(to_regprocedure('public.save_business_metrics_v1(jsonb)') IS NOT NULL,'save_business_metrics_v1 existe');
SELECT ok(to_regprocedure('public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)') IS NOT NULL,'get_configurable_dashboard_v1 existe');
SELECT ok(to_regprocedure('private.sale_belongs_unambiguously_to_branch(uuid,bigint,uuid)') IS NOT NULL,'helper branch venta existe');
SELECT ok(has_function_privilege('authenticated','public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)','EXECUTE'),'authenticated puede ejecutar dashboard');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.list_business_metrics_v1()'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%organization_id=v_org%'),'list filtra tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.save_business_metrics_v1(jsonb)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%delete from public.business_metric_definitions where organization_id=v_org%'),'save borra sólo tenant actual');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.save_business_metrics_v1(jsonb)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%v_org,trim(v_row->>''source'')%'),'save inserta tenant server-side');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%p_end-p_start>interval ''366 days''%'),'dashboard limita periodo');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%b.organization_id=v_org and b.id=p_branch_id%'),'branch validada por tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%sale_belongs_unambiguously_to_branch%'),'ventas usan atribución branch inequívoca');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%cr.branch_id=p_branch_id%'),'finanzas branch-aware por caja');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%a.branch_id=p_branch_id%'),'inventario branch-aware');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%when ''gross_margin'' then%' AND lower(pg_get_functiondef(p.oid)) LIKE '%v_available:=false%'),'margen fail-closed');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_proc p
  WHERE p.oid='public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure
    AND position('v_available:=false' IN translate(
      split_part(
        split_part(lower(pg_get_functiondef(p.oid)), 'when ''inventory_turnover'' then', 2),
        'else', 1
      ), E' \n\r\t', ''
    )) > 0
    AND position('v_note:=' IN translate(
      split_part(
        split_part(lower(pg_get_functiondef(p.oid)), 'when ''inventory_turnover'' then', 2),
        'else', 1
      ), E' \n\r\t', ''
    )) > 0
),'rotación fail-closed documentada');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%accounts_receivable%'),'cuentas por cobrar incluida');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%dead_inventory_items%'),'inventario inmovilizado incluido');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%scope_note%'),'dashboard explica alcance');

SELECT * FROM finish();
ROLLBACK;
