BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(30);

SELECT ok(to_regclass('public.operational_alert_settings') IS NOT NULL,'settings alertas existe');
SELECT ok(to_regclass('public.operational_alerts') IS NOT NULL,'operational_alerts existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.operational_alert_settings'::regclass AND attname='organization_id' AND attnotnull AND NOT attisdropped),'settings organization_id NOT NULL');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.operational_alert_settings'::regclass AND pg_get_constraintdef(oid) ILIKE '%organizations(id)%'),'settings pertenece a organization');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.operational_alerts'::regclass AND attname='organization_id' AND attnotnull AND NOT attisdropped),'alert organization_id NOT NULL');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.operational_alerts'::regclass AND pg_get_constraintdef(oid) ILIKE '%UNIQUE (organization_id, dedup_key)%'),'dedup por tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.operational_alerts'::regclass AND pg_get_constraintdef(oid) ILIKE '%stock_low%expiry%debt_overdue%purchase_pending%cash_session_open%task%'),'categorías operativas restringidas');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.operational_alerts'::regclass AND pg_get_constraintdef(oid) ILIKE '%pg_column_size(metadata)%16384%'),'metadata alertas <=16KiB');
SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='operational_alerts' AND policyname='operational_alerts_tenant_read' AND lower(qual) LIKE '%row_belongs_to_current_organization%' AND lower(qual) LIKE '%tenant.read%'),'RLS alertas tenant read');
SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='operational_alert_settings' AND policyname='operational_alert_settings_tenant_read' AND lower(qual) LIKE '%row_belongs_to_current_organization%'),'RLS settings tenant');
SELECT ok(NOT has_table_privilege('authenticated','public.operational_alerts','INSERT'),'authenticated sin INSERT alertas');
SELECT ok(NOT has_table_privilege('authenticated','public.operational_alerts','UPDATE'),'authenticated sin UPDATE alertas');
SELECT ok(NOT has_table_privilege('authenticated','public.operational_alert_settings','UPDATE'),'authenticated sin UPDATE settings');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.organizations'::regclass AND tgname='organizations_create_operational_alert_settings' AND NOT tgisinternal),'nuevos tenants reciben settings');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.inventario_almacen'::regclass AND tgname='operational_stock_alert_evaluate_tx' AND NOT tgisinternal AND tgdeferrable AND tginitdeferred),'stock alert diferida al final de tx');
SELECT ok(NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.inventario_almacen'::regclass AND tgname='trigger_stock_alert_evaluar_tx' AND NOT tgisinternal),'trigger OneSignal global retirado');
SELECT ok(NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.inventario_almacen'::regclass AND tgname='trigger_stock_alert_acumular_tx' AND NOT tgisinternal),'acumulador legacy retirado');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='private' AND p.proname='refresh_operational_alerts_for_org' AND lower(pg_get_functiondef(p.oid)) LIKE '%p.organization_id=p_organization_id%' AND lower(pg_get_functiondef(p.oid)) LIKE '%l.organization_id=p_organization_id%' AND lower(pg_get_functiondef(p.oid)) LIKE '%v.organization_id=p_organization_id%' AND lower(pg_get_functiondef(p.oid)) LIKE '%po.organization_id=p_organization_id%' AND lower(pg_get_functiondef(p.oid)) LIKE '%sc.organization_id=p_organization_id%'),'motor privado scopea todas las fuentes');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='private' AND p.proname='refresh_low_stock_alert_for_product' AND lower(pg_get_functiondef(p.oid)) LIKE '%ia.organization_id=p_organization_id%' AND lower(pg_get_functiondef(p.oid)) LIKE '%ia.producto_id=p_product_id%'),'stock event-driven tenant-safe');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.operational_alert_settings'::regclass AND tgname='operational_alert_settings_audit_change' AND NOT tgisinternal),'settings quedan en audit log');

SELECT ok(to_regprocedure('public.refresh_operational_alerts_v1()') IS NOT NULL,'refresh_operational_alerts_v1 existe');
SELECT ok(to_regprocedure('public.list_operational_alerts_v1(text,integer)') IS NOT NULL,'list_operational_alerts_v1 existe');
SELECT ok(to_regprocedure('public.acknowledge_operational_alert_v1(uuid)') IS NOT NULL,'acknowledge_operational_alert_v1 existe');
SELECT ok(to_regprocedure('public.create_operational_task_v1(text,text,timestamptz,text)') IS NOT NULL,'create_operational_task_v1 existe');
SELECT ok(to_regprocedure('public.resolve_operational_alert_v1(uuid)') IS NOT NULL,'resolve_operational_alert_v1 existe');
SELECT ok(to_regprocedure('public.get_operational_alert_settings_v1()') IS NOT NULL,'get_operational_alert_settings_v1 existe');
SELECT ok(to_regprocedure('public.update_operational_alert_settings_v1(bigint,jsonb)') IS NOT NULL,'update_operational_alert_settings_v1 existe');
SELECT ok(has_function_privilege('authenticated','public.list_operational_alerts_v1(text,integer)','EXECUTE'),'authenticated puede listar por RPC');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.update_operational_alert_settings_v1(bigint,jsonb)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%s.organization_id=v_org and s.revision=p_expected_revision%' AND lower(pg_get_functiondef(p.oid)) LIKE '%jsonb_object_keys(p_settings)%'),'settings usa tenant + optimistic concurrency + allowlist');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.create_operational_task_v1(text,text,timestamptz,text)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%tenant.admin%'),'tareas operativas requieren admin');

SELECT * FROM finish();
ROLLBACK;
