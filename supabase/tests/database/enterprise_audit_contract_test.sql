BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(28);

SELECT ok(to_regclass('public.audit_logs') IS NOT NULL,'audit_logs existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.audit_logs'::regclass AND attname='organization_id' AND attnotnull AND NOT attisdropped),'audit_logs.organization_id NOT NULL');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.audit_logs'::regclass AND pg_get_constraintdef(oid) ILIKE '%FOREIGN KEY (organization_id)%organizations(id)%'),'audit_logs pertenece a organizations');
SELECT ok(EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.audit_logs'::regclass AND attname='metadata' AND attnotnull AND NOT attisdropped),'metadata NOT NULL');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.audit_logs'::regclass AND pg_get_constraintdef(oid) ILIKE '%pg_column_size(metadata)%32768%'),'metadata limitada a 32 KiB');
SELECT ok(EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='audit_logs' AND indexname='audit_logs_organization_time_idx'),'índice tenant/tiempo existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='audit_logs' AND policyname='audit_logs_tenant_admin_select' AND lower(qual) LIKE '%tenant.admin%' AND lower(qual) LIKE '%row_belongs_to_current_organization%'),'RLS lectura admin tenant-aware');
SELECT ok(NOT has_table_privilege('authenticated','public.audit_logs','INSERT'),'authenticated sin INSERT directo');
SELECT ok(NOT has_table_privilege('authenticated','public.audit_logs','UPDATE'),'authenticated sin UPDATE directo');
SELECT ok(NOT has_table_privilege('authenticated','public.audit_logs','DELETE'),'authenticated sin DELETE directo');
SELECT ok(NOT has_table_privilege('authenticated','public.audit_logs','SELECT'),'authenticated sin SELECT directo');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.audit_logs'::regclass AND tgname='audit_logs_block_mutation' AND NOT tgisinternal),'trigger append-only existe');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='private' AND p.proname='write_audit_log' AND lower(pg_get_functiondef(p.oid)) LIKE '%cross-tenant audit event is not allowed%'),'writer bloquea cross-tenant');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='private' AND p.proname='write_audit_log' AND lower(pg_get_functiondef(p.oid)) LIKE '%e.organization_id=p_organization_id%' AND lower(pg_get_functiondef(p.oid)) LIKE '%e.app_user_id=v_user or e.auth_id=v_user%'),'actor se resuelve dentro del tenant');
SELECT ok(NOT has_function_privilege('authenticated','private.write_audit_log(uuid,text,text,text,text,text,uuid,jsonb)','EXECUTE'),'writer privado no ejecutable por authenticated');

SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.productos'::regclass AND tgname='productos_audit_price_change' AND NOT tgisinternal),'precio producto auditado');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.sale_price_rules'::regclass AND tgname='sale_price_rules_audit_change' AND NOT tgisinternal),'reglas de precio auditadas');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.inventario_movimientos'::regclass AND tgname='inventario_movimientos_audit_adjustment' AND NOT tgisinternal),'ajustes de inventario auditados');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.ventas_requests_anulados'::regclass AND tgname='ventas_requests_anulados_audit' AND NOT tgisinternal),'anulaciones auditadas');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.ventas'::regclass AND tgname='ventas_audit_sensitive_discount' AND NOT tgisinternal),'descuentos sensibles auditados');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.role_permissions'::regclass AND tgname='role_permissions_audit_change' AND NOT tgisinternal),'permisos de rol auditados');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.employee_roles'::regclass AND tgname='employee_roles_audit_change' AND NOT tgisinternal),'roles de empleado auditados');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.employee_permission_overrides'::regclass AND tgname='employee_permission_overrides_audit_change' AND NOT tgisinternal),'overrides auditados');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.business_capabilities'::regclass AND tgname='business_capabilities_audit_change' AND NOT tgisinternal),'capacidades auditadas');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.custom_field_definitions'::regclass AND tgname='custom_field_definitions_audit_change' AND NOT tgisinternal),'campos configurables auditados');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.configuracion_negocio'::regclass AND tgname='configuracion_negocio_audit_change' AND NOT tgisinternal),'configuración negocio auditada');

SELECT ok(to_regprocedure('public.list_audit_logs_v1(integer,bigint,text,text)') IS NOT NULL,'RPC list_audit_logs_v1 existe');
SELECT ok(has_function_privilege('authenticated','public.list_audit_logs_v1(integer,bigint,text,text)','EXECUTE') AND EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.list_audit_logs_v1(integer,bigint,text,text)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%where a.organization_id=v_org%' AND lower(pg_get_functiondef(p.oid)) LIKE '%tenant.admin%'),'RPC audit expuesto sólo con tenant/admin');

SELECT * FROM finish();
ROLLBACK;
