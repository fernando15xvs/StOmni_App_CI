-- 2D-H: privileged tenant context requires an ACTIVE employee, not merely app_users.
-- All synthetic tenant/identity objects and grants are transactional, ending in ROLLBACK.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(13);
CREATE TEMP TABLE actors ON COMMIT DROP AS
SELECT label,base_role,employee_id,gen_random_uuid() org,
  gen_random_uuid() actor,gen_random_uuid() branch
FROM (VALUES ('A','admin',-840193101::bigint),('B','operador',-840193102::bigint))
 AS f(label,base_role,employee_id);
GRANT SELECT ON actors TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org,'2D-H strict context '||label,'PE','PEN','America/Lima' FROM actors;
INSERT INTO auth.users(id,aud,role) SELECT actor,'authenticated','authenticated' FROM actors;
INSERT INTO public.app_users(user_id,organization_id,status,base_role)
SELECT actor,org,'active',base_role FROM actors;
INSERT INTO public.branches(id,organization_id,code,name,is_main,status)
SELECT branch,org,'MAIN','Test branch',true,'active' FROM actors;
INSERT INTO public.empleados(id,organization_id,branch_id,auth_id,app_user_id,nombre,rol,activo,employment_status)
SELECT employee_id,org,branch,actor,actor,'Test employee',base_role,
       label='A',CASE WHEN label='A' THEN 'active' ELSE 'inactive' END
FROM actors;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='B'),true);
SELECT throws_ok($q$SELECT private.require_current_organization_id()$q$,'42501',NULL,'Inactive member lacks privileged organization context');
SELECT throws_ok($q$SELECT public.get_estado_caja_chica()$q$,'42501',NULL,'Inactive member cannot read cash state');
SELECT throws_ok($q$SELECT public.get_my_subscription_v1()$q$,'42501',NULL,'Inactive member cannot read subscription');
SELECT throws_ok($q$SELECT public.get_my_entitlements_v1()$q$,'42501',NULL,'Inactive member cannot enumerate entitlements');
SELECT throws_ok($q$SELECT public.get_my_billing_summary_v1()$q$,'42501',NULL,'Inactive member cannot read billing summary');
SELECT throws_ok($q$SELECT public.get_business_profile_v1()$q$,'42501',NULL,'Inactive member cannot read business profile');
SELECT throws_ok($q$SELECT public.get_current_business_configuration_v1()$q$,'42501',NULL,'Inactive member cannot read business configuration');
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
SELECT is(private.require_current_organization_id(),(SELECT org FROM actors WHERE label='A'),'Active admin retains organization context');
SELECT is(private.has_permission('tenant.admin'),true,'Active admin retains administrative permission');
SELECT is((public.get_estado_caja_chica()->>'estado')::text,'CERRADA','Active admin cash reader remains valid');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
UPDATE public.empleados SET employment_status='inactive',activo=false WHERE id=(SELECT employee_id FROM actors WHERE label='A');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
SELECT throws_ok($q$SELECT private.require_current_organization_id()$q$,'42501',NULL,'Revoked admin loses privileged context immediately');
SELECT throws_ok($q$SELECT public.get_estado_caja_chica()$q$,'42501',NULL,'Revoked admin cannot see cash reader');
SELECT set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
SELECT throws_ok($q$SELECT private.require_current_organization_id()$q$,'42501',NULL,'Missing membership rejected');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
