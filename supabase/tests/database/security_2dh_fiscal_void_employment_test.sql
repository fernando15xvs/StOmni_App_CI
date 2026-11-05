-- 2D-H: fiscal authorization precedes payload, idempotency and document lookup.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions, pg_catalog;
SELECT plan(4);

CREATE TEMP TABLE actors ON COMMIT DROP AS
SELECT label, base_role, employee_id, gen_random_uuid() AS org,
       gen_random_uuid() AS actor, gen_random_uuid() AS branch
FROM (VALUES
  ('A','admin',-840170101::bigint),
  ('B','operador',-840170102::bigint)
) AS fixture(label, base_role, employee_id);
GRANT SELECT ON actors TO authenticated;

-- Bypass provisioning triggers only while building the two isolated fixtures.
SET LOCAL session_replication_role = replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org,'2DH tenant ' || label,'PE','PEN','America/Lima' FROM actors;
INSERT INTO auth.users(id,aud,role)
SELECT actor,'authenticated','authenticated' FROM actors;
INSERT INTO public.app_users(user_id,organization_id,status,base_role)
SELECT actor,org,'active',base_role FROM actors;
INSERT INTO public.branches(id,organization_id,code,name,is_main,status)
SELECT branch,org,'MAIN','Fixture branch',true,'active' FROM actors;
INSERT INTO public.empleados(id,organization_id,branch_id,auth_id,app_user_id,nombre,rol,activo,employment_status)
SELECT employee_id,org,branch,actor,actor,'Fixture employee',base_role,true,'active' FROM actors;
SET LOCAL session_replication_role = origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
SELECT throws_ok($$SELECT public.solicitar_baja_tributaria_v1(NULL,'comprobante',NULL,'test')$$,'P0001','request_id y origen_id son obligatorios',
  'Active administrator reaches fiscal request validation');
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='B'),true);
SELECT throws_ok($$SELECT public.solicitar_baja_tributaria_v1(NULL,'comprobante',NULL,'test')$$,'P0001','Solo un administrador activo puede solicitar una baja tributaria',
  'Active operator fails authorization before request validation');
RESET ROLE;
SET LOCAL session_replication_role = replica;
UPDATE public.empleados SET employment_status='terminated'
WHERE id=(SELECT employee_id FROM actors WHERE label='A');
SET LOCAL session_replication_role = origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
SELECT throws_ok($$SELECT public.solicitar_baja_tributaria_v1(NULL,'comprobante',NULL,'test')$$,'P0001','Solo un administrador activo puede solicitar una baja tributaria',
  'Terminated administrator with activo=true is denied before payload processing');
SELECT throws_ok($$SELECT public.solicitar_baja_tributaria_v1(gen_random_uuid(),'comprobante',gen_random_uuid(),'fixture')$$,
  'P0001','Solo un administrador activo puede solicitar una baja tributaria',
  'Terminated administrator is denied before document lookup');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
