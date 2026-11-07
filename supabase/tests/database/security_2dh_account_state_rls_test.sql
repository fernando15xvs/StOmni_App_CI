-- 2D-H: revoke direct organization/membership metadata without breaking F8.1.
-- Synthetic identities; every change is rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(12);
CREATE TEMP TABLE actors ON COMMIT DROP AS
 SELECT label,gen_random_uuid() org,gen_random_uuid() actor,gen_random_uuid() branch
 FROM (VALUES ('A'),('B'),('C')) x(label);
GRANT SELECT ON actors TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org,'Private account fixture '||label,'PE','PEN','America/Lima' FROM actors;
INSERT INTO auth.users(id,aud,role) SELECT actor,'authenticated','authenticated' FROM actors;
INSERT INTO public.app_users(user_id,organization_id,status,base_role)
SELECT actor,org,'active','admin' FROM actors;
INSERT INTO public.branches(id,organization_id,code,name,is_main,status)
SELECT branch,org,'MAIN','Test',true,'active' FROM actors;
INSERT INTO public.empleados(organization_id,branch_id,auth_id,app_user_id,nombre,rol,activo,employment_status)
SELECT org,branch,actor,actor,'Test admin','admin',label='A',
 CASE WHEN label='A' THEN 'active' ELSE 'inactive' END
FROM actors WHERE label IN ('A','B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
SELECT is((SELECT count(*)::int FROM public.organizations),1,'Active tenant sees exactly its organization');
SELECT is((SELECT count(*)::int FROM public.app_users),1,'Active tenant sees exactly its membership');
SELECT is((public.get_organization_signup_state_v1()->>'state'),'attached','Active member stays attached');
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='B'),true);
SELECT is((SELECT count(*)::int FROM public.organizations),0,'Revoked employee sees no organization');
SELECT is((SELECT count(*)::int FROM public.app_users),0,'Revoked employee sees no membership');
SELECT is((public.get_organization_signup_state_v1()->>'state'),'access_revoked','Revoked state reported explicitly');
SELECT ok((public.get_organization_signup_state_v1()->>'organization_id') IS NULL,'Revoked state redacts organization id');
SELECT ok((public.get_organization_signup_state_v1() ? 'display_name') IS FALSE,'Revoked state redacts organization name');
SELECT throws_ok($q$SELECT private.require_current_organization_id()$q$,'42501',NULL,'Revoked employee cannot access privileged context');
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='C'),true);
SELECT is((SELECT count(*)::int FROM public.app_users),0,'Pre-employee bootstrap does not expose membership table');
SELECT is((public.get_organization_signup_state_v1()->>'state'),'attached','Pre-employee bootstrap account-state remains readable');
SELECT set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
SELECT is((public.get_organization_signup_state_v1()->>'state'),'eligible','Fresh user can create a business');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
