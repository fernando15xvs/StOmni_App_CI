-- Two real synthetic tenant bootstraps + 22 reader RPCs per actor.
-- Tests positive A/B context, revoked JWT and missing membership. All rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(36);
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
CREATE TEMP TABLE _staff(label text,role_id uuid) ON COMMIT DROP;
INSERT INTO _staff(label) SELECT label FROM _reader_owner;
GRANT SELECT,UPDATE ON _staff TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.empleados(id,organization_id,branch_id,nombre,rol,activo,employment_status)
SELECT CASE a.label WHEN 'A' THEN -840235101 ELSE -840235102 END,a.org,b.id,'Employee '||a.label,'operador',true,'active'
FROM _reader_owner a JOIN public.branches b ON b.organization_id=a.org AND b.is_main;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='A'),true);
UPDATE _staff SET role_id=(public.create_role_v1('audit_team','Team A',ARRAY['products.update'])->>'id')::uuid WHERE label='A';
SELECT ok((SELECT role_id FROM _staff WHERE label='A') IS NOT NULL,'A created custom team role');
SELECT is((public.get_employee_permission_settings_v1(-840235101)->>'employee_id')::bigint,-840235101::bigint,'A reads own employee settings');
SELECT is(public.get_employee_permission_settings_v1(-840235101)->>'role','operator','A employee defaults to operator without roles');
SELECT is((public.set_role_permissions_v1((SELECT role_id FROM _staff WHERE label='A'),ARRAY['products.update','sales.create'])->'permissions') ? 'sales.create',true,'A adds sales create to role');
SELECT throws_ok($q$SELECT public.set_role_permissions_v1((SELECT role_id FROM _staff WHERE label='A'),ARRAY['unlisted.permission'])$q$,'22023',NULL,'A cannot assign unrecognized permission');
SELECT throws_ok($q$SELECT public.set_employee_roles_v1(-840235101,ARRAY[]::uuid[])$q$,'23514',NULL,'A employee must keep one role');
SELECT is((public.set_employee_roles_v1(-840235101,ARRAY[(SELECT role_id FROM _staff WHERE label='A')])->>'role'),'audit_team','A assigns custom role to own employee');
SELECT is((public.get_employee_permission_settings_v1(-840235101)->'permissions'->'products.update'->>'allowed')::boolean,true,'A employee granted product updates via role');
SELECT is((public.get_employee_permission_settings_v1(-840235101)->'permissions'->'sales.create'->>'allowed')::boolean,true,'A employee granted sales via role');
SELECT is((public.update_employee_permission_overrides_v1(-840235101,'{"products.update":false,"sales.create":true}'::jsonb)->'permissions'->'products.update'->>'allowed')::boolean,false,'A override denies products');
SELECT is((public.get_employee_permission_settings_v1(-840235101)->'permissions'->'products.update'->>'override')::boolean,false,'A override persists negative state');
SELECT throws_ok($q$SELECT public.update_employee_permission_overrides_v1(-840235101,'{"products.update":"allowed"}'::jsonb)$q$,'22023',NULL,'A permission override must be boolean');
SELECT throws_ok($q$SELECT public.update_employee_permission_overrides_v1(-840235101,'{"invalid.feature":true}'::jsonb)$q$,'22023',NULL,'A unknown override denied');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='B'),true);
UPDATE _staff SET role_id=(public.create_role_v1('audit_team','Team B',ARRAY['products.update'])->>'id')::uuid WHERE label='B';
SELECT ok((SELECT role_id FROM _staff WHERE label='B') IS NOT NULL,'B created custom team role with same code');
SELECT isnt((SELECT role_id FROM _staff WHERE label='A'),(SELECT role_id FROM _staff WHERE label='B'),'A/B custom roles have different IDs');
SELECT is((public.get_employee_permission_settings_v1(-840235102)->>'employee_id')::bigint,-840235102::bigint,'B employee details scoped');
SELECT throws_ok($q$SELECT public.get_employee_permission_settings_v1(-840235101)$q$,'P0002',NULL,'B cannot read A employee permissions');
SELECT throws_ok($q$SELECT public.set_employee_roles_v1(-840235101,ARRAY[(SELECT role_id FROM _staff WHERE label='B')])$q$,'P0002',NULL,'B cannot edit A employee roles');
SELECT throws_ok($q$SELECT public.set_role_permissions_v1((SELECT role_id FROM _staff WHERE label='A'),ARRAY['sales.create'])$q$,'P0002',NULL,'B cannot edit A role permissions');
SELECT throws_ok($q$SELECT public.set_employee_roles_v1(-840235102,ARRAY[(SELECT role_id FROM _staff WHERE label='A')])$q$,'P0002',NULL,'B cannot attach A role to B employee');
SELECT is((public.set_role_permissions_v1((SELECT role_id FROM _staff WHERE label='B'),ARRAY['products.update'])->'permissions') ? 'products.update',true,'B role permissions local');
SELECT is((public.set_employee_roles_v1(-840235102,ARRAY[(SELECT role_id FROM _staff WHERE label='B')])->>'role'),'audit_team','B assigns own role');
SELECT is((public.update_employee_permission_overrides_v1(-840235102,'{"products.update":true}'::jsonb)->'permissions'->'products.update'->>'override')::boolean,true,'B can override own employee');
SELECT throws_ok($q$SELECT public.update_employee_permission_overrides_v1(-840235101,'{"products.update":true}'::jsonb)$q$,'P0002',NULL,'B cannot override A employee');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.get_employee_permission_settings_v1(-840235102)$q$,'P0002',NULL,'A cannot read B employee permissions');
SELECT throws_ok($q$SELECT public.set_role_permissions_v1((SELECT role_id FROM _staff WHERE label='B'),ARRAY['sales.create'])$q$,'P0002',NULL,'A cannot edit B role');
SELECT throws_ok($q$SELECT public.set_employee_roles_v1(-840235102,ARRAY[(SELECT role_id FROM _staff WHERE label='A')])$q$,'P0002',NULL,'A cannot edit B employee');
RESET ROLE;
SELECT ok((SELECT count(*)=2 FROM public.roles r JOIN _staff s ON s.role_id=r.id JOIN _reader_owner a ON a.label=s.label AND a.org=r.organization_id),'A/B roles stored in distinct organizations');
SELECT ok((SELECT count(*)=2 FROM public.employee_roles er JOIN _staff s ON s.role_id=er.role_id JOIN _reader_owner a ON a.label=s.label AND a.org=er.organization_id),'A/B employee-role links scoped');
SELECT ok((SELECT count(*)=3 FROM public.employee_permission_overrides o JOIN _reader_owner a ON a.org=o.organization_id WHERE o.employee_id IN(-840235101,-840235102)),'Overrides persisted without crossing tenant');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _reader_owner WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _reader_owner WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _reader_owner WHERE label='B') AND employee_id IN(SELECT id FROM public.empleados WHERE auth_id=(SELECT uid FROM _reader_owner WHERE label='B'));
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.get_employee_permission_settings_v1(-840235102)$q$,'42501',NULL,'Operator B cannot read privileged employee settings');
SELECT throws_ok($q$SELECT public.set_employee_roles_v1(-840235102,ARRAY[(SELECT role_id FROM _staff WHERE label='B')])$q$,'42501',NULL,'Operator B cannot assign employee roles');
SELECT throws_ok($q$SELECT public.set_role_permissions_v1((SELECT role_id FROM _staff WHERE label='B'),ARRAY['sales.create'])$q$,'42501',NULL,'Operator B cannot edit role permissions');
SELECT throws_ok($q$SELECT public.update_employee_permission_overrides_v1(-840235102,'{}')$q$,'42501',NULL,'Operator B cannot override employee');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _reader_owner WHERE label='A') AND auth_id=(SELECT uid FROM _reader_owner WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _reader_owner WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.get_employee_permission_settings_v1(-840235101)$q$,'42501',NULL,'Revoked A cannot view employee rights');
SELECT throws_ok($q$SELECT public.set_role_permissions_v1((SELECT role_id FROM _staff WHERE label='A'),ARRAY['sales.create'])$q$,'42501',NULL,'Revoked A cannot edit roles');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
