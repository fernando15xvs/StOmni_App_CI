BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(30);

SELECT ok(EXISTS(SELECT 1 FROM public.entitlement_definitions WHERE key='feature.expiry_tracking' AND kind='feature'),'expiry entitlement existe');
SELECT ok(to_regprocedure('private.subscription_access_allowed(uuid)') IS NOT NULL,'subscription_access_allowed existe');
SELECT ok(to_regprocedure('private.plan_feature_enabled(uuid,text)') IS NOT NULL,'plan_feature_enabled existe');
SELECT ok(to_regprocedure('private.plan_limit_value(uuid,text)') IS NOT NULL,'plan_limit_value existe');
SELECT ok(to_regprocedure('private.require_subscription_feature_for_org(uuid,text)') IS NOT NULL,'require feature existe');
SELECT ok(to_regprocedure('private.assert_plan_compatible_with_organization(uuid,uuid)') IS NOT NULL,'assert plan compatible existe');
SELECT ok(NOT has_function_privilege('authenticated','private.require_subscription_feature_for_org(uuid,text)','EXECUTE'),'helper feature no expuesto');
SELECT ok(NOT has_function_privilege('authenticated','private.assert_plan_compatible_with_organization(uuid,uuid)','EXECUTE'),'assert plan no expuesto');

SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.business_capabilities'::regclass AND tgname='zz_business_capabilities_subscription_guard' AND NOT tgisinternal),'trigger capabilities');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.app_users'::regclass AND tgname='zz_app_users_subscription_limit' AND NOT tgisinternal),'trigger users');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.branches'::regclass AND tgname='zz_branches_subscription_limit' AND NOT tgisinternal),'trigger branches');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.almacenes'::regclass AND tgname='zz_almacenes_subscription_limit' AND NOT tgisinternal),'trigger warehouses');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.cash_registers'::regclass AND tgname='zz_cash_registers_subscription_limit' AND NOT tgisinternal),'trigger cash registers');

SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='private.assert_plan_compatible_with_organization(uuid,uuid)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%feature.inventory%' AND lower(pg_get_functiondef(p.oid)) LIKE '%feature.expiry_tracking%' AND lower(pg_get_functiondef(p.oid)) LIKE '%feature.serial_tracking%'),'plan compatibility cubre capabilities');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='private.assert_plan_compatible_with_organization(uuid,uuid)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%limit.users%' AND lower(pg_get_functiondef(p.oid)) LIKE '%limit.branches%' AND lower(pg_get_functiondef(p.oid)) LIKE '%limit.warehouses%' AND lower(pg_get_functiondef(p.oid)) LIKE '%limit.cash_registers%'),'plan compatibility cubre límites');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='private.enforce_subscription_business_capabilities()'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%feature.inventory%' AND lower(pg_get_functiondef(p.oid)) LIKE '%feature.electronic_invoicing%'),'capability trigger consulta entitlements');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='private.enforce_subscription_count_limit()'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%subscription_access_allowed%' AND lower(pg_get_functiondef(p.oid)) LIKE '%subscription_limit_value%'),'count limit exige suscripción y límite');

SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='private.set_organization_subscription_v1(uuid,text,text,text,bigint,timestamptz,timestamptz,boolean)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%assert_plan_compatible_with_organization%'),'cambio plan valida compatibilidad');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='private.set_plan_entitlement_v1(text,text,boolean,bigint)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%assert_plan_compatible_with_organization%'),'cambio entitlement valida tenants');
SELECT ok(NOT has_function_privilege('authenticated','private.set_organization_subscription_v1(uuid,text,text,text,bigint,timestamptz,timestamptz,boolean)','EXECUTE'),'writer subscription sigue privado');
SELECT ok(NOT has_function_privilege('authenticated','private.set_plan_entitlement_v1(text,text,boolean,bigint)','EXECUTE'),'writer entitlement sigue privado');

SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%feature.analytics%'),'dashboard exige analytics');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.list_business_metrics_v1()'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%feature.analytics%'),'list metrics exige analytics');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.save_business_metrics_v1(jsonb)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%feature.analytics%'),'save metrics exige analytics');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.get_business_assistant_context_v1(text,integer,uuid,integer)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%feature.business_assistant%'),'assistant context exige entitlement');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='public.update_business_assistant_settings_v1(bigint,boolean,integer,integer)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%feature.business_assistant%'),'habilitar assistant exige entitlement');

SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.organization_subscriptions'::regclass AND tgname='organization_subscriptions_audit_change' AND NOT tgisinternal),'audit trigger suscripción');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='private.audit_organization_subscription_change()'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%subscription.updated%' AND lower(pg_get_functiondef(p.oid)) LIKE '%write_audit_log%'),'audit subscription usa ledger');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='private.enforce_subscription_count_limit()'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%coalesce(v_count,0)+1>v_limit%'),'límite bloquea alta que excede');
SELECT ok(EXISTS(SELECT 1 FROM pg_proc p WHERE p.oid='private.set_plan_entitlement_v1(text,text,boolean,bigint)'::regprocedure AND lower(pg_get_functiondef(p.oid)) LIKE '%s.status in (''active'',''trialing'')%'),'packaging valida suscripciones utilizables');

SELECT * FROM finish();
ROLLBACK;
