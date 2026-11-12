BEGIN;
-- Two real synthetic tenant bootstraps + 22 reader RPCs per actor.
-- Tests positive A/B context, revoked JWT and missing membership. All rolled back.

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(28);
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
SELECT is(has_function_privilege('authenticated','private.resolve_selected_membership_v1()','EXECUTE'),false,'Not executable by authenticated directly');
SELECT is(has_function_privilege('anon','private.resolve_selected_membership_v1()','EXECUTE'),false,'Not executable by anon');
SELECT set_config('request.jwt.claim.sub',(SELECT uid FROM _reader_owner WHERE label='A')::text,true);
SELECT set_config('request.headers','{}',true);
SELECT is((SELECT organization_id FROM private.resolve_selected_membership_v1()),(SELECT org FROM _reader_owner WHERE label='A'),'Single member A selected without header');
SELECT is((SELECT base_role FROM private.resolve_selected_membership_v1()),'admin','A role fetched from same membership');
SELECT ok((SELECT employee_id IS NOT NULL FROM private.resolve_selected_membership_v1()),'A employee identity selected atomically');
SELECT ok((SELECT EXISTS(SELECT 1 FROM public.empleados e JOIN private.resolve_selected_membership_v1() s ON s.employee_id=e.id AND s.organization_id=e.organization_id)),'A employee ID matches selected company');
SELECT set_config('request.headers',jsonb_build_object('x-stomni-organization-id',(SELECT org FROM _reader_owner WHERE label='A'),'x-stomni-role','operator')::text,true);
SELECT is((SELECT organization_id FROM private.resolve_selected_membership_v1()),(SELECT org FROM _reader_owner WHERE label='A'),'Valid A selection succeeds');
SELECT is((SELECT base_role FROM private.resolve_selected_membership_v1()),'admin','Forged operator role header does not demote stored A admin');
SELECT set_config('request.headers',jsonb_build_object('x-stomni-organization-id',(SELECT org FROM _reader_owner WHERE label='B'),'x-stomni-role','admin')::text,true);
SELECT is((SELECT count(*)::int FROM private.resolve_selected_membership_v1()),0,'A cannot select B despite forged admin role');
SELECT is(private.current_organization_id(),NULL::uuid,'Current org rejects foreign A to B selector after I1 bridge');
SELECT set_config('request.headers','{"x-stomni-organization-id":"not-a-uuid"}',true);
SELECT throws_ok($q$SELECT * FROM private.resolve_selected_membership_v1()$q$,'42501',NULL,'Malformed org UUID rejected');
SELECT throws_ok($q$SELECT private.current_organization_id()$q$,'42501',NULL,'Current org also rejects malformed selector');
SELECT set_config('request.headers','[1,2,3]',true);
SELECT throws_ok($q$SELECT * FROM private.resolve_selected_membership_v1()$q$,'42501',NULL,'Non-object request headers rejected');
SELECT set_config('request.headers','{"x-stomni-organization-id":""}',true);
SELECT throws_ok($q$SELECT * FROM private.resolve_selected_membership_v1()$q$,'42501',NULL,'Empty explicit selector denied');
SELECT set_config('request.headers','not json',true);
SELECT throws_ok($q$SELECT * FROM private.resolve_selected_membership_v1()$q$,'42501',NULL,'Invalid headers JSON rejected');
SELECT set_config('request.headers',jsonb_build_object('x-stomni-organization-id',(SELECT org FROM _reader_owner WHERE label='B'))::text,true);
SELECT set_config('request.jwt.claim.sub',(SELECT uid FROM _reader_owner WHERE label='B')::text,true);
SELECT is((SELECT organization_id FROM private.resolve_selected_membership_v1()),(SELECT org FROM _reader_owner WHERE label='B'),'B explicit B selection succeeds');
SELECT is((SELECT base_role FROM private.resolve_selected_membership_v1()),'admin','B receives its own admin role');
SELECT is(private.current_organization_id(),(SELECT org FROM _reader_owner WHERE label='B'),'Current org follows explicit B selection');
SELECT is(private.current_base_role(),'admin','Current role follows same selected B membership');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _reader_owner WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _reader_owner WHERE label='B') AND organization_id=(SELECT org FROM _reader_owner WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _reader_owner WHERE label='B');
SET LOCAL session_replication_role=origin;
SELECT is((SELECT base_role FROM private.resolve_selected_membership_v1()),'operador','B role follows membership demotion');
SELECT is((SELECT organization_id FROM private.resolve_selected_membership_v1()),(SELECT org FROM _reader_owner WHERE label='B'),'B role demotion does not affect org choice');
SELECT set_config('request.headers',jsonb_build_object('x-stomni-organization-id',(SELECT org FROM _reader_owner WHERE label='A'),'x-stomni-role','admin')::text,true);
SELECT is((SELECT count(*)::int FROM private.resolve_selected_membership_v1()),0,'B cannot escalate with A org and admin header');
SELECT set_config('request.headers','{}',true);
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _reader_owner WHERE label='B') AND auth_id=(SELECT uid FROM _reader_owner WHERE label='B');
SET LOCAL session_replication_role=origin;
SELECT is((SELECT count(*)::int FROM private.resolve_selected_membership_v1()),0,'Revoked B has no selected membership');
SELECT is(private.current_organization_id(),NULL::uuid,'Revoked B has no active tenant context');
SELECT is(private.current_base_role(),NULL::text,'Revoked B has no active role context');
SELECT set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
SELECT is((SELECT count(*)::int FROM private.resolve_selected_membership_v1()),0,'Unknown JWT user no selected membership');
SELECT is(private.current_organization_id(),NULL::uuid,'Unknown JWT has no tenant context');
SELECT set_config('request.jwt.claim.sub','',true);
SELECT is((SELECT count(*)::int FROM private.resolve_selected_membership_v1()),0,'Missing JWT no selected membership');
SELECT * FROM finish();
ROLLBACK;
