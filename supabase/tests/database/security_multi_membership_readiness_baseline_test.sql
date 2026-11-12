-- Two real synthetic tenant bootstraps + 22 reader RPCs per actor.
-- Tests positive A/B context, revoked JWT and missing membership. All rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(23);
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
-- 2D-I readiness: never grant multiple memberships until org AND role are selected atomically.
SELECT set_config('request.jwt.claim.sub',(SELECT uid FROM _reader_owner WHERE label='A')::text,true);
SELECT set_config('request.headers','{}',true);
SELECT is(private.current_organization_id(),(SELECT org FROM _reader_owner WHERE label='A'),'A resolves own unique active organization');
SELECT is(private.current_base_role(),'admin','A resolves admin role from same membership');
SELECT is(public.get_user_role(),'admin','A employee role also admin');
SELECT is(private.require_current_organization_id(),(SELECT org FROM _reader_owner WHERE label='A'),'A require-current-org checks active employment');
SELECT set_config('request.headers',jsonb_build_object('x-stomni-organization-id',(SELECT org FROM _reader_owner WHERE label='B'),'x-stomni-role','admin')::text,true);
SELECT is(private.current_organization_id(),(SELECT org FROM _reader_owner WHERE label='A'),'A cannot change org by forged B header');
SELECT is(private.current_base_role(),'admin','A role comes from server-side member row, not header');
SELECT is((public.get_business_profile_v1()->>'organization_id')::uuid,(SELECT org FROM _reader_owner WHERE label='A'),'A remains confined to A profile on forged B header');
SELECT set_config('request.jwt.claim.sub',(SELECT uid FROM _reader_owner WHERE label='B')::text,true);
SELECT set_config('request.headers',jsonb_build_object('x-stomni-organization-id',(SELECT org FROM _reader_owner WHERE label='A'),'x-stomni-role','admin')::text,true);
SELECT is(private.current_organization_id(),(SELECT org FROM _reader_owner WHERE label='B'),'B cannot change org by forged A header');
SELECT is(private.current_base_role(),'admin','B initially admin via B member row');
SELECT is((public.get_my_subscription_v1()->>'organization_id')::uuid,(SELECT org FROM _reader_owner WHERE label='B'),'B subscription always B despite A header');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _reader_owner WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _reader_owner WHERE label='B') AND organization_id=(SELECT org FROM _reader_owner WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _reader_owner WHERE label='B') AND employee_id IN(SELECT id FROM public.empleados WHERE auth_id=(SELECT uid FROM _reader_owner WHERE label='B'));
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid FROM _reader_owner WHERE label='B')::text,true);
SELECT is(private.current_organization_id(),(SELECT org FROM _reader_owner WHERE label='B'),'B role change does not change organization');
SELECT is(private.current_base_role(),'operador','B demotion reflected in server-side base_role');
SELECT is(public.get_user_role(),'operador','B employee role follows same demotion');
SELECT is(private.has_permission('tenant.admin'),false,'B operator cannot spoof tenant.admin with role header');
SELECT is((public.get_my_subscription_v1()->>'organization_id')::uuid,(SELECT org FROM _reader_owner WHERE label='B'),'B role change still permits only own reads');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _reader_owner WHERE label='A') AND auth_id=(SELECT uid FROM _reader_owner WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid FROM _reader_owner WHERE label='A')::text,true);
SELECT is(private.current_base_role(),NULL::text,'Revoked A cannot resolve privileged base role');
SELECT throws_ok($q$SELECT private.require_current_organization_id()$q$,'42501',NULL,'Revoked A cannot require active tenant');
SELECT throws_ok($q$SELECT public.get_business_profile_v1()$q$,'42501',NULL,'Revoked A cannot read tenant profile');
SELECT set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
SELECT is(private.current_organization_id(),NULL::uuid,'Unknown user resolves no organization');
SELECT is(private.current_base_role(),NULL::text,'Unknown user resolves no role');
SELECT throws_ok($q$SELECT private.require_current_organization_id()$q$,'42501',NULL,'Unknown user cannot require tenant');
RESET ROLE;
SET LOCAL session_replication_role=replica;
SELECT throws_ok($q$INSERT INTO public.app_users(user_id,organization_id,status,base_role) VALUES ((SELECT uid FROM _reader_owner WHERE label='A'),(SELECT org FROM _reader_owner WHERE label='B'),'active','admin')$q$,'23505',NULL,'Current app_users user_id primary key blocks cross-org membership; migration required');
SELECT throws_ok($q$INSERT INTO public.empleados(organization_id,branch_id,nombre,rol,activo,employment_status,app_user_id,auth_id) VALUES ((SELECT org FROM _reader_owner WHERE label='B'),(SELECT id FROM public.branches WHERE organization_id=(SELECT org FROM _reader_owner WHERE label='B') AND is_main),'Second membership','operador',true,'active',(SELECT uid FROM _reader_owner WHERE label='A'),(SELECT uid FROM _reader_owner WHERE label='A'))$q$,'23505',NULL,'Current employee app_user_id global unique blocks cross-org employee; migration required');
SET LOCAL session_replication_role=origin;
SELECT * FROM finish();
ROLLBACK;
