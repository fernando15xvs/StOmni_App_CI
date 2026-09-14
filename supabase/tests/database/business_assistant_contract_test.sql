BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(28);

SELECT ok(to_regclass('public.business_assistant_settings') IS NOT NULL,'business_assistant_settings existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.business_assistant_settings'::regclass AND attname='organization_id' AND attnotnull AND NOT attisdropped),'organization_id NOT NULL');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.business_assistant_settings'::regclass AND contype='p' AND pg_get_constraintdef(oid) ILIKE '%organization_id%'),'PK por organization');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.business_assistant_settings'::regclass AND contype='f' AND pg_get_constraintdef(oid) ILIKE '%organizations(id)%'),'FK organization');
SELECT ok(EXISTS(SELECT 1 FROM pg_attrdef d JOIN pg_attribute a ON a.attrelid=d.adrelid AND a.attnum=d.adnum WHERE d.adrelid='public.business_assistant_settings'::regclass AND a.attname='enabled' AND pg_get_expr(d.adbin,d.adrelid)='false'),'asistente deshabilitado por defecto');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.business_assistant_settings'::regclass AND pg_get_constraintdef(oid) ILIKE '%max_result_items%1%50%'),'max_result_items acotado');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.business_assistant_settings'::regclass AND pg_get_constraintdef(oid) ILIKE '%default_period_days%1%365%'),'periodo acotado');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.organizations'::regclass AND tgname='organizations_create_business_assistant_settings' AND NOT tgisinternal),'nuevos tenants reciben settings');
SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='business_assistant_settings' AND policyname='business_assistant_settings_tenant_read' AND lower(qual) LIKE '%row_belongs_to_current_organization%' AND lower(qual) LIKE '%tenant.read%'),'RLS settings tenant-aware');
SELECT ok(NOT has_table_privilege('authenticated','public.business_assistant_settings','UPDATE'),'authenticated sin UPDATE directo');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.business_assistant_settings'::regclass AND tgname='business_assistant_settings_audit_change' AND NOT tgisinternal),'settings auditados');

SELECT ok(to_regprocedure('public.get_business_assistant_settings_v1()') IS NOT NULL,'get settings existe');
SELECT ok(to_regprocedure('public.update_business_assistant_settings_v1(bigint,boolean,integer,integer)') IS NOT NULL,'update settings existe');
SELECT ok(to_regprocedure('public.get_business_assistant_context_v1(text,integer,uuid,integer)') IS NOT NULL,'context RPC existe');
SELECT ok(has_function_privilege('authenticated','public.get_business_assistant_context_v1(text,integer,uuid,integer)','EXECUTE'),'authenticated puede ejecutar contexto');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_business_assistant_context_v1(text,integer,uuid,integer)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%require_current_organization_id%'),'contexto deriva tenant server-side');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_business_assistant_context_v1(text,integer,uuid,integer)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%reports.view_profit%'),'contexto exige reportes');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_business_assistant_context_v1(text,integer,uuid,integer)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%business assistant is disabled for this organization%'),'asistente requiere opt-in');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_business_assistant_context_v1(text,integer,uuid,integer)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%replenishment%non_moving_products%overdue_receivables%margin_diagnostics%'),'intenciones cerradas');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_business_assistant_context_v1(text,integer,uuid,integer)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%v_days not between 1 and 365%'),'periodo validado');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_business_assistant_context_v1(text,integer,uuid,integer)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%v_limit not between 1 and v_settings.max_result_items%'),'límite validado contra settings');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_business_assistant_context_v1(text,integer,uuid,integer)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%b.organization_id=v_org and b.id=p_branch_id%'),'branch tenant-aware');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_business_assistant_context_v1(text,integer,uuid,integer)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%p.organization_id=v_org%' AND lower(pg_get_functiondef(p.oid)) LIKE '%stock_minimo%'),'reposición tenant-aware');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_business_assistant_context_v1(text,integer,uuid,integer)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%im.organization_id=v_org%' AND lower(pg_get_functiondef(p.oid)) LIKE '%salida_cant%'),'no rotación tenant-aware');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_business_assistant_context_v1(text,integer,uuid,integer)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%v.organization_id=v_org%' AND lower(pg_get_functiondef(p.oid)) LIKE '%v.estado=''pendiente''%'),'receivables tenant-aware');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_business_assistant_context_v1(text,integer,uuid,integer)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%sale_belongs_unambiguously_to_branch%'),'receivables branch-safe');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_business_assistant_context_v1(text,integer,uuid,integer)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%margen no disponible con rigor%' AND lower(pg_get_functiondef(p.oid)) NOT LIKE '%precio_compra from%'),'margen fail-closed');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.update_business_assistant_settings_v1(bigint,boolean,integer,integer)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%organization_id=v_org and revision=p_expected_revision%' AND lower(pg_get_functiondef(p.oid)) LIKE '%tenant.admin%'),'settings tenant+revision+admin');

SELECT * FROM finish();
ROLLBACK;
