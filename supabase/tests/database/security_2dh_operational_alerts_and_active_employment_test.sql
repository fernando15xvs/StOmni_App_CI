-- 2D-H: authenticated RPC tests for alerts, tasks, settings and inactive employees.
-- All fixture changes are rolled back; baseline before the fix fails inactive-employee cases.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(41);
CREATE TEMP TABLE actors ON COMMIT DROP AS
SELECT label,base_role,employee_id,gen_random_uuid() org,gen_random_uuid() actor,
       gen_random_uuid() branch,gen_random_uuid() role_id
FROM (VALUES ('A','admin',-840190101::bigint),('B','operador',-840190102::bigint))
AS fixture(label,base_role,employee_id);
CREATE TEMP TABLE alerts ON COMMIT DROP AS
SELECT label,gen_random_uuid() id,
 CASE WHEN label LIKE 'A%' THEN (SELECT org FROM actors WHERE label='A')
 ELSE (SELECT org FROM actors WHERE label='B') END AS org
FROM (VALUES ('A1'),('A2'),('B1'),('B2')) x(label);
GRANT SELECT ON actors,alerts TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org,'2DH alerts '||label,'PE','PEN','America/Lima' FROM actors;
INSERT INTO auth.users(id,aud,role) SELECT actor,'authenticated','authenticated' FROM actors;
INSERT INTO public.app_users(user_id,organization_id,status,base_role)
SELECT actor,org,'active',base_role FROM actors;
INSERT INTO public.branches(id,organization_id,code,name,is_main,status)
SELECT branch,org,'MAIN','Test branch',true,'active' FROM actors;
INSERT INTO public.empleados(id,organization_id,branch_id,auth_id,app_user_id,nombre,rol,activo,employment_status)
SELECT employee_id,org,branch,actor,actor,'Test employee',base_role,true,'active' FROM actors;
INSERT INTO public.roles(id,organization_id,code,name,is_system,status)
SELECT role_id,org,CASE label WHEN 'A' THEN 'admin' ELSE 'operator' END,'Test role',true,'active' FROM actors;
INSERT INTO public.employee_roles(organization_id,employee_id,role_id)
SELECT org,employee_id,role_id FROM actors;
INSERT INTO public.operational_alert_settings(organization_id) SELECT org FROM actors;
INSERT INTO public.operational_alerts(id,organization_id,category,severity,status,dedup_key,title,message)
SELECT id,org,'task','info',CASE WHEN label='A2' THEN 'resolved' ELSE 'open' END,
 'test-alert-'||id,'Test alert '||label,'Tenant isolation fixture' FROM alerts;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
SELECT is((SELECT count(*)::int FROM public.list_operational_alerts_v1(NULL,100)),2,'A lists only its own alerts');
SELECT is((SELECT count(*)::int FROM public.list_operational_alerts_v1('open',100)),1,'A status filter excludes resolved alert');
SELECT is((public.get_operational_alert_settings_v1()->>'revision')::int,1,'A reads own settings');
SELECT throws_ok($q$SELECT public.list_operational_alerts_v1('bad',100)$q$,'22023',NULL,'Invalid status rejected');
SELECT throws_ok($q$SELECT public.list_operational_alerts_v1(NULL,201)$q$,'22023',NULL,'Excess page size rejected');
SELECT throws_ok($q$SELECT public.acknowledge_operational_alert_v1((SELECT id FROM alerts WHERE label='B1'))$q$,'P0002',NULL,'A cannot acknowledge B alert');
SELECT throws_ok($q$SELECT public.resolve_operational_alert_v1((SELECT id FROM alerts WHERE label='B1'))$q$,'P0002',NULL,'A cannot resolve B alert');
SELECT is((public.acknowledge_operational_alert_v1((SELECT id FROM alerts WHERE label='A1'))->>'status'),'acknowledged','A acknowledges own alert');
SELECT is((public.resolve_operational_alert_v1((SELECT id FROM alerts WHERE label='A1'))->>'status'),'resolved','A resolves own alert');
SELECT is((public.acknowledge_operational_alert_v1((SELECT id FROM alerts WHERE label='A1'))->>'status'),'resolved','Acknowledging resolved alert does not reopen it');
SELECT is((public.create_operational_task_v1('Team followup','Check stock',NULL,'warning')->>'status'),'open','A creates own task');
SELECT is((SELECT count(*)::int FROM public.list_operational_alerts_v1(NULL,100)),3,'A task visible only to A');
SELECT is((public.update_operational_alert_settings_v1(1,'{"low_stock_enabled":false}'::jsonb)->>'revision')::int,2,'A updates own settings by revision');
SELECT throws_ok($q$SELECT public.update_operational_alert_settings_v1(1,'{"low_stock_enabled":true}'::jsonb)$q$,'40001',NULL,'Stale settings revision rejected');
SELECT throws_ok($q$SELECT public.update_operational_alert_settings_v1(2,'{"foreign":true}'::jsonb)$q$,'22023',NULL,'Unknown settings key rejected');
SELECT throws_ok($q$SELECT public.create_operational_task_v1('Task','Message',NULL,'invalid')$q$,'22023',NULL,'Invalid severity rejected');
SELECT throws_ok($q$SELECT public.create_operational_task_v1(' ','Message')$q$,'22023',NULL,'Blank task title rejected');
SELECT is((public.refresh_operational_alerts_v1()->>'success')::boolean,true,'A refreshes own alert context');
SELECT is((SELECT count(*)::int FROM public.list_operational_alerts_v1(NULL,100)),3,'A refresh retains tasks');
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='B'),true);
SELECT is((SELECT count(*)::int FROM public.list_operational_alerts_v1(NULL,100)),2,'B lists only own alerts');
SELECT is((public.get_operational_alert_settings_v1()->>'revision')::int,1,'B reads B settings');
SELECT throws_ok($q$SELECT public.acknowledge_operational_alert_v1((SELECT id FROM alerts WHERE label='A1'))$q$,'P0002',NULL,'B cannot acknowledge A alert');
SELECT throws_ok($q$SELECT public.resolve_operational_alert_v1((SELECT id FROM alerts WHERE label='A1'))$q$,'42501',NULL,'Operator cannot resolve alert');
SELECT throws_ok($q$SELECT public.create_operational_task_v1('Operator','No admin')$q$,'42501',NULL,'Operator cannot create task');
SELECT throws_ok($q$SELECT public.update_operational_alert_settings_v1(1,'{"low_stock_enabled":false}'::jsonb)$q$,'42501',NULL,'Operator cannot update settings');
SELECT is((public.acknowledge_operational_alert_v1((SELECT id FROM alerts WHERE label='B1'))->>'status'),'acknowledged','B can acknowledge own alert');
SELECT is((public.refresh_operational_alerts_v1()->>'success')::boolean,true,'B can refresh own alerts');
SELECT is((SELECT count(*)::int FROM public.list_operational_alerts_v1(NULL,100)),2,'B refresh does not leak A alerts');
SELECT set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
SELECT throws_ok($q$SELECT public.list_operational_alerts_v1()$q$,'42501',NULL,'No membership cannot list');
SELECT throws_ok($q$SELECT public.get_operational_alert_settings_v1()$q$,'42501',NULL,'No membership cannot read settings');
SELECT throws_ok($q$SELECT public.acknowledge_operational_alert_v1((SELECT id FROM alerts WHERE label='B1'))$q$,'42501',NULL,'No membership cannot acknowledge');
SELECT throws_ok($q$SELECT public.create_operational_task_v1('Task','Message')$q$,'42501',NULL,'No membership cannot create task');
SELECT throws_ok($q$SELECT public.refresh_operational_alerts_v1()$q$,'42501',NULL,'No membership cannot refresh');
RESET ROLE;
SELECT is((SELECT status FROM public.operational_alerts WHERE id=(SELECT id FROM alerts WHERE label='B1')),'acknowledged','B alert modified only by B');
SELECT is((SELECT status FROM public.operational_alerts WHERE id=(SELECT id FROM alerts WHERE label='A1')),'resolved','A alert remains resolved');
SELECT is((SELECT count(*)::int FROM public.operational_alerts WHERE organization_id=(SELECT org FROM actors WHERE label='B')),2,'B alerts not changed by A');
UPDATE public.empleados SET activo=false WHERE id=(SELECT employee_id FROM actors WHERE label='A');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.list_operational_alerts_v1()$q$,'42501',NULL,'Inactive employee cannot list alerts');
SELECT throws_ok($q$SELECT public.create_operational_task_v1('Former employee','No access')$q$,'42501',NULL,'Inactive employee cannot create tasks');
SELECT throws_ok($q$SELECT public.update_operational_alert_settings_v1(2,'{"low_stock_enabled":true}'::jsonb)$q$,'42501',NULL,'Inactive employee cannot update settings');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
UPDATE public.empleados SET employment_status='inactive' WHERE id=(SELECT employee_id FROM actors WHERE label='B');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.get_operational_alert_settings_v1()$q$,'42501',NULL,'Inactive employment status blocks settings');
SELECT throws_ok($q$SELECT public.acknowledge_operational_alert_v1((SELECT id FROM alerts WHERE label='B2'))$q$,'42501',NULL,'Inactive employment status blocks mutations');

RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
