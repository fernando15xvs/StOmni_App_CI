-- 2D-I2: composite schema in DEV, but the I4 activation gate stays shut.
-- Both synthetic tenants and attempted cross-company writes are rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(14);

CREATE TEMP TABLE _i2_schema_actors (
  label text PRIMARY KEY,uid uuid NOT NULL,org uuid
) ON COMMIT DROP;
INSERT INTO _i2_schema_actors(label,uid)
SELECT label,gen_random_uuid() FROM (VALUES('A'),('B')) t(label);
GRANT SELECT,UPDATE ON _i2_schema_actors TO authenticated;

SET LOCAL session_replication_role=replica;
INSERT INTO auth.users(id,aud,role,email,email_confirmed_at)
SELECT uid,'authenticated','authenticated',
 'i2-schema-'||uid||'@example.invalid',now()
FROM _i2_schema_actors;
SET LOCAL session_replication_role=origin;

SET LOCAL ROLE authenticated;
SELECT set_config('request.headers','{}',true);
SELECT set_config('request.jwt.claim.sub',
  (SELECT uid::text FROM _i2_schema_actors WHERE label='A'),true);
UPDATE _i2_schema_actors SET org=(
  public.create_my_organization_v1('I2 composite schema A','PE','PEN','America/Lima')
  ->>'organization_id')::uuid WHERE label='A';
SELECT set_config('request.jwt.claim.sub',
  (SELECT uid::text FROM _i2_schema_actors WHERE label='B'),true);
UPDATE _i2_schema_actors SET org=(
  public.create_my_organization_v1('I2 composite schema B','PE','PEN','America/Lima')
  ->>'organization_id')::uuid WHERE label='B';
RESET ROLE;
SELECT set_config('request.headers','{}',true);

SELECT is(
 (SELECT pg_get_constraintdef(oid) FROM pg_constraint
  WHERE conrelid='public.app_users'::regclass AND conname='app_users_pkey'),
 'PRIMARY KEY (organization_id, user_id)',
 'App-users primary key is organization plus user');
SELECT is(
 (SELECT pg_get_constraintdef(oid) FROM pg_constraint
  WHERE conrelid='public.empleados'::regclass
    AND conname='empleados_organization_app_user_key'),
 'UNIQUE (organization_id, app_user_id)',
 'Employees enforce tenant-composite login uniqueness');
SELECT is(
 (SELECT count(*)::int FROM pg_constraint WHERE conrelid='public.empleados'::regclass
  AND conname='empleados_app_user_id_key'),0,
 'Global employee login UNIQUE has been removed');
SELECT is(
 (SELECT count(*)::int FROM pg_index i
  WHERE i.indrelid='public.app_users'::regclass AND i.indisunique
    AND pg_get_indexdef(i.indexrelid) LIKE '%(user_id)%'),0,
 'No global user_id-only unique index remains');
SELECT is(
 (SELECT tgenabled FROM pg_trigger WHERE tgrelid='public.app_users'::regclass
 AND tgname='app_users_multi_membership_activation_gate'),'O',
 'I4 activation guard trigger is active');
SELECT is(
 (SELECT prosecdef FROM pg_proc WHERE oid=
  'private.enforce_single_membership_until_i4()'::regprocedure),true,
 'Activation guard runs with controlled privileges');
SELECT is(has_function_privilege('authenticated',
  'private.enforce_single_membership_until_i4()','EXECUTE'),false,
 'Client cannot invoke guard function directly');
SELECT is(has_function_privilege('anon',
  'private.enforce_single_membership_until_i4()','EXECUTE'),false,
 'Anonymous caller cannot invoke guard function directly');
SELECT ok(EXISTS(
 SELECT 1 FROM pg_constraint c
 WHERE c.conrelid='public.empleados'::regclass
  AND c.conname='empleados_organization_app_user_fkey'
  AND c.conindid='public.app_users_organization_user_key'::regclass),
 'Existing composite FK still targets canonical membership unique key');
SELECT ok((SELECT prosrc FROM pg_proc
 WHERE oid='private.enforce_single_membership_until_i4()'::regprocedure)
 LIKE '%FOR UPDATE%',
 'Activation trigger locks Auth user row to close concurrent insert race');

SELECT throws_ok($q$
 INSERT INTO public.app_users(user_id,organization_id,status,base_role)
 VALUES ((SELECT uid FROM _i2_schema_actors WHERE label='A'),
         (SELECT org FROM _i2_schema_actors WHERE label='B'),'active','operador')
$q$,'23505',NULL,
 'Same authenticated account cannot persist a second tenant membership');

SELECT throws_ok($q$
 INSERT INTO public.empleados(
   organization_id,branch_id,nombre,rol,activo,employment_status,app_user_id,auth_id
 ) VALUES (
   (SELECT org FROM _i2_schema_actors WHERE label='B'),
   (SELECT id FROM public.branches
    WHERE organization_id=(SELECT org FROM _i2_schema_actors WHERE label='B')
     AND is_main),
   'Invalid employee cross-tenant link','operador',true,'active',
   (SELECT uid FROM _i2_schema_actors WHERE label='A'),
   (SELECT uid FROM _i2_schema_actors WHERE label='A')
 )
$q$,'23503',NULL,
 'Composite FK blocks employees without a matching local membership');

SELECT is(
 (SELECT count(*)::int FROM (
  SELECT user_id FROM public.app_users GROUP BY user_id HAVING count(*)>1
 ) d),0,'No duplicated Auth identity persists in I2 staged schema');
SELECT is(
 (SELECT count(*)::int FROM public.app_users a JOIN _i2_schema_actors t
   ON a.user_id=t.uid),2,'Both independent ordinary tenant bootstraps still work');

SELECT * FROM finish();
ROLLBACK;
