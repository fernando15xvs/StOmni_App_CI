-- 2D-H: real A/B tenant-specific subscription/config/permissions/cash readers.
-- Tests positive A/B context, revoked JWT and missing membership. All rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(58);
CREATE TEMP TABLE _reader_owner(label text,uid uuid,org uuid) ON COMMIT DROP;
INSERT INTO _reader_owner SELECT label,gen_random_uuid(),NULL::uuid FROM (VALUES('A'),('B')) t(label);
GRANT SELECT,UPDATE ON _reader_owner TO authenticated;
CREATE TEMP TABLE _reader_invocation(sig text,call_sql text) ON COMMIT DROP;
INSERT INTO _reader_invocation VALUES ('get_business_profile_v1()','get_business_profile_v1()'),
('get_current_business_configuration_v1()','get_current_business_configuration_v1()'),
('get_estado_caja_chica()','get_estado_caja_chica()'),
('get_my_subscription_v1()','get_my_subscription_v1()'),
('get_my_billing_summary_v1()','get_my_billing_summary_v1()'),
('get_my_effective_permissions_v1()','get_my_effective_permissions_v1()'),
('get_my_onboarding_progress_v1()','get_my_onboarding_progress_v1()'),
('get_business_assistant_settings_v1()','get_business_assistant_settings_v1()'),
('get_operational_alert_settings_v1()','get_operational_alert_settings_v1()'),
('get_user_role()','get_user_role()'),
('get_observability_metrics_v1(integer)','get_observability_metrics_v1(10)'),
('get_dashboard_summary(timestamp with time zone,timestamp with time zone)','get_dashboard_summary(now()-interval ''1 day'',now())'),
('get_configurable_dashboard_v1(timestamp with time zone,timestamp with time zone,uuid)','get_configurable_dashboard_v1(now()-interval ''1 day'',now(),NULL)'),
('get_my_entitlements_v1()','get_my_entitlements_v1()'),
('list_purchase_orders_v1(text,integer)','list_purchase_orders_v1(NULL,10)'),
('list_services_v1(boolean)','list_services_v1(true)'),
('list_custom_field_definitions_v1(text,boolean)','list_custom_field_definitions_v1(''catalog_item'',true)'),
('list_sale_price_rules_v1()','list_sale_price_rules_v1()'),
('list_business_metrics_v1()','list_business_metrics_v1()'),
('list_audit_logs_v1(integer,bigint,text,text)','list_audit_logs_v1(10,NULL,NULL,NULL)'),
('list_recent_observability_errors_v1(integer)','list_recent_observability_errors_v1(10)'),
('list_operational_alerts_v1(text,integer)','list_operational_alerts_v1(NULL,10)');
GRANT SELECT ON _reader_invocation TO authenticated;
CREATE TEMP TABLE _reader_probe(stage text,sig text,outcome text,error_code text,payload jsonb) ON COMMIT DROP;
GRANT SELECT,INSERT ON _reader_probe TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO auth.users(id,aud,role,email,email_confirmed_at)
SELECT uid,'authenticated','authenticated','2dh-reader-'||uid||'@example.invalid',now() FROM _reader_owner;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='A'),true);
UPDATE _reader_owner SET org=(public.create_my_organization_v1('2DH reader tenant A','PE','PEN','America/Lima')->>'organization_id')::uuid WHERE label='A';
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='B'),true);
UPDATE _reader_owner SET org=(public.create_my_organization_v1('2DH reader tenant B','PE','PEN','America/Lima')->>'organization_id')::uuid WHERE label='B';
RESET ROLE;
CREATE TEMP TABLE _cash_context(label text,sid uuid) ON COMMIT DROP;
INSERT INTO _cash_context(label,sid) SELECT label,gen_random_uuid() FROM _reader_owner;
GRANT SELECT ON _cash_context TO authenticated;
SET LOCAL session_replication_role=replica;
UPDATE public.configuracion_negocio
SET nombre_comercial=CASE WHEN organization_id=(SELECT org FROM _reader_owner WHERE label='A') THEN 'AUDIT READ A SAC' ELSE 'AUDIT READ B SAC' END
WHERE organization_id IN ((SELECT org FROM _reader_owner WHERE label='A'),(SELECT org FROM _reader_owner WHERE label='B'));
UPDATE public.business_assistant_settings SET
  max_result_items=CASE WHEN organization_id=(SELECT org FROM _reader_owner WHERE label='A') THEN 7 ELSE 9 END,
  default_period_days=CASE WHEN organization_id=(SELECT org FROM _reader_owner WHERE label='A') THEN 14 ELSE 21 END
WHERE organization_id IN ((SELECT org FROM _reader_owner WHERE label='A'),(SELECT org FROM _reader_owner WHERE label='B'));
UPDATE public.organization_onboarding_progress SET
 completed_steps=CASE WHEN organization_id=(SELECT org FROM _reader_owner WHERE label='A') THEN ARRAY['business_profile','modules']::text[] ELSE ARRAY['business_profile']::text[] END,
 revision=CASE WHEN organization_id=(SELECT org FROM _reader_owner WHERE label='A') THEN 3 ELSE 2 END
WHERE organization_id IN ((SELECT org FROM _reader_owner WHERE label='A'),(SELECT org FROM _reader_owner WHERE label='B'));
UPDATE public.organization_subscriptions SET
 plan_id=(SELECT id FROM public.subscription_plans WHERE code='pro'),revision=revision+1
WHERE organization_id=(SELECT org FROM _reader_owner WHERE label='B');
UPDATE public.plan_entitlements SET limit_value=7
WHERE plan_id=(SELECT id FROM public.subscription_plans WHERE code='pro') AND entitlement_key='limit.branches';
INSERT INTO public.billing_provider_accounts(organization_id,provider_code,external_customer_ref)
VALUES ((SELECT org FROM _reader_owner WHERE label='B'),'devmock','B-FAKE-ONLY-TRANSACTION');
INSERT INTO public.sesiones_caja(id,organization_id,branch_id,cash_register_id,usuario_id,estado,monto_apertura,fecha_apertura)
SELECT c.sid,a.org,b.id,r.id,a.uid,'ABIERTA',CASE a.label WHEN 'A' THEN 100 ELSE 200 END,now()-interval '10 minutes'
FROM _reader_owner a JOIN _cash_context c ON c.label=a.label
JOIN public.branches b ON b.organization_id=a.org AND b.is_main
JOIN public.cash_registers r ON r.organization_id=a.org AND r.is_default;
INSERT INTO public.pagos_venta(organization_id,metodo,monto,fecha,cash_session_id)
SELECT a.org,'efectivo',CASE a.label WHEN 'A' THEN 11 ELSE 29 END,now(),c.sid
FROM _reader_owner a JOIN _cash_context c ON c.label=a.label;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='A'),true);
SELECT is((public.get_business_profile_v1()->>'organization_id')::uuid,(SELECT org FROM _reader_owner WHERE label='A'),'A profile organization scoped');
SELECT is(public.get_business_profile_v1()->>'display_name','AUDIT READ A SAC','A profile uses unique own name');
SELECT is(public.get_current_business_configuration_v1()->>'nombre_comercial','AUDIT READ A SAC','A configuration own name');
SELECT is((public.get_current_business_configuration_v1()->>'organization_id')::uuid,(SELECT org FROM _reader_owner WHERE label='A'),'A configuration tenant scoped');
SELECT is((public.get_business_assistant_settings_v1()->>'max_result_items')::int,7,'A assistant preference own limit');
SELECT is((public.get_business_assistant_settings_v1()->>'default_period_days')::int,14,'A assistant preference own period');
SELECT is((public.get_my_onboarding_progress_v1()->>'revision')::int,3,'A onboarding revision distinct');
SELECT is(public.get_my_onboarding_progress_v1()->>'next_step','operations','A onboarding next step distinct');
SELECT is(public.get_my_subscription_v1()->>'plan_code','starter','A starter subscription');
SELECT is((public.get_my_subscription_v1()->>'organization_id')::uuid,(SELECT org FROM _reader_owner WHERE label='A'),'A subscription tenant scoped');
SELECT is((public.get_my_billing_summary_v1()->>'organization_id')::uuid,(SELECT org FROM _reader_owner WHERE label='A'),'A billing summary tenant scoped');
SELECT is((public.get_my_billing_summary_v1()->>'provider_account_bound')::boolean,false,'A has no billing provider binding');
SELECT is((SELECT x->>'limit_value' FROM public.get_my_entitlements_v1() x WHERE x->>'key'='limit.branches'),NULL::text,'A branch limit remains unlimited');
SELECT ok((SELECT count(*)>=15 FROM public.get_my_entitlements_v1()),'A entitlements populated');
SELECT is(public.get_my_effective_permissions_v1()->>'role','admin','A effective admin role');
SELECT ok((public.get_my_effective_permissions_v1()->'permissions') ? 'business.configure','A has authorized business configure');
SELECT is(public.get_estado_caja_chica()::jsonb->>'estado','ABIERTA','A open cash session visible');
SELECT is((public.get_estado_caja_chica()::jsonb->>'saldo_esperado')::numeric,111::numeric,'A expected cash 100+11 excludes B');
SELECT is((public.get_estado_caja_chica()::jsonb->>'ingresos_efectivo')::numeric,11::numeric,'A cash credits exclude B');
SELECT is((public.get_estado_caja_chica()::jsonb->'sesion'->>'organization_id')::uuid,(SELECT org FROM _reader_owner WHERE label='A'),'A sees only its own cash session');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='B'),true);
SELECT is((public.get_business_profile_v1()->>'organization_id')::uuid,(SELECT org FROM _reader_owner WHERE label='B'),'B profile tenant scoped');
SELECT is(public.get_business_profile_v1()->>'display_name','AUDIT READ B SAC','B profile own name');
SELECT is(public.get_current_business_configuration_v1()->>'nombre_comercial','AUDIT READ B SAC','B current configuration own name');
SELECT is((public.get_current_business_configuration_v1()->>'organization_id')::uuid,(SELECT org FROM _reader_owner WHERE label='B'),'B config own organization');
SELECT is((public.get_business_assistant_settings_v1()->>'max_result_items')::int,9,'B assistant preference own limit');
SELECT is((public.get_business_assistant_settings_v1()->>'default_period_days')::int,21,'B assistant preference own period');
SELECT is((public.get_my_onboarding_progress_v1()->>'revision')::int,2,'B onboarding revision isolated');
SELECT is(public.get_my_onboarding_progress_v1()->>'next_step','modules','B onboarding next step isolated');
SELECT is(public.get_my_subscription_v1()->>'plan_code','pro','B synthetic pro subscription');
SELECT is((public.get_my_subscription_v1()->>'organization_id')::uuid,(SELECT org FROM _reader_owner WHERE label='B'),'B subscription tenant scoped');
SELECT is(public.get_my_billing_summary_v1()->>'billing_provider','devmock','B own provider binding code');
SELECT is((public.get_my_billing_summary_v1()->>'provider_account_bound')::boolean,true,'B own provider account bound');
SELECT is((public.get_my_billing_summary_v1()->>'organization_id')::uuid,(SELECT org FROM _reader_owner WHERE label='B'),'B billing summary tenant scoped');
SELECT is((SELECT (x->>'limit_value')::bigint FROM public.get_my_entitlements_v1() x WHERE x->>'key'='limit.branches'),7::bigint,'B pro entitlement limit distinct');
SELECT ok((SELECT count(*)>=15 FROM public.get_my_entitlements_v1()),'B entitlements populated');
SELECT is(public.get_my_effective_permissions_v1()->>'role','admin','B initial effective admin');
SELECT is(public.get_estado_caja_chica()::jsonb->>'estado','ABIERTA','B own open cash session');
SELECT is((public.get_estado_caja_chica()::jsonb->>'saldo_esperado')::numeric,229::numeric,'B cash balance 200+29 excludes A');
SELECT is((public.get_estado_caja_chica()::jsonb->>'ingresos_efectivo')::numeric,29::numeric,'B cash income excludes A');
SELECT is((public.get_estado_caja_chica()::jsonb->'sesion'->>'organization_id')::uuid,(SELECT org FROM _reader_owner WHERE label='B'),'B cash session organization scoped');
RESET ROLE;
SELECT is((SELECT count(*)::integer FROM public.billing_provider_accounts WHERE organization_id IN((SELECT org FROM _reader_owner WHERE label='A'),(SELECT org FROM _reader_owner WHERE label='B'))),1,'Only B has provider binding');
SELECT ok((SELECT count(*)=2 FROM public.sesiones_caja WHERE organization_id IN((SELECT org FROM _reader_owner WHERE label='A'),(SELECT org FROM _reader_owner WHERE label='B')) AND estado='ABIERTA'),'Two independent open cash sessions');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _reader_owner WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _reader_owner WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _reader_owner WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='B'),true);
SELECT is(public.get_my_effective_permissions_v1()->>'role','operator','B demoted role visible in permissions reader');
SELECT ok(NOT (public.get_my_effective_permissions_v1()->'permissions' ? 'business.configure'),'B operator lacks business configure');
SELECT is(public.get_my_subscription_v1()->>'plan_code','pro','B operator reads only own subscription');
SELECT is((public.get_my_billing_summary_v1()->>'provider_account_bound')::boolean,true,'B operator can see own provider binding');
SELECT is((public.get_estado_caja_chica()::jsonb->>'saldo_esperado')::numeric,229::numeric,'B operator sees own cash only');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _reader_owner WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='A'),true);
SELECT throws_ok($q$SELECT get_business_profile_v1()$q$,'42501',NULL,'Revoked A profile denied');
SELECT throws_ok($q$SELECT get_current_business_configuration_v1()$q$,'42501',NULL,'Revoked A config denied');
SELECT throws_ok($q$SELECT get_business_assistant_settings_v1()$q$,'42501',NULL,'Revoked A assistant settings denied');
SELECT throws_ok($q$SELECT get_my_onboarding_progress_v1()$q$,'42501',NULL,'Revoked A onboarding denied');
SELECT throws_ok($q$SELECT get_my_subscription_v1()$q$,'42501',NULL,'Revoked A subscription denied');
SELECT throws_ok($q$SELECT get_my_billing_summary_v1()$q$,'42501',NULL,'Revoked A billing denied');
SELECT throws_ok($q$SELECT get_my_effective_permissions_v1()$q$,'42501',NULL,'Revoked A effective permissions denied');
SELECT throws_ok($q$SELECT get_estado_caja_chica()$q$,'42501',NULL,'Revoked A cash session denied');
SELECT throws_ok($q$SELECT (SELECT count(*) FROM public.get_my_entitlements_v1())$q$,'42501',NULL,'Revoked A entitlements denied');
SELECT set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
SELECT throws_ok($q$SELECT public.get_business_profile_v1()$q$,'42501',NULL,'Missing membership cannot read profile');
SELECT throws_ok($q$SELECT public.get_my_subscription_v1()$q$,'42501',NULL,'Missing membership cannot read subscriptions');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
