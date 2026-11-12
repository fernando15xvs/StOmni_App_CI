BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(12);

CREATE TEMP TABLE _i2_audit_actor(label text PRIMARY KEY, uid uuid NOT NULL, org uuid) ON COMMIT DROP;
INSERT INTO _i2_audit_actor SELECT label,gen_random_uuid(),NULL::uuid FROM (VALUES('A'),('B')) AS t(label);
GRANT SELECT,UPDATE ON _i2_audit_actor TO authenticated;

SET LOCAL session_replication_role=replica;
INSERT INTO auth.users(id,aud,role,email,email_confirmed_at)
SELECT uid,'authenticated','authenticated','i2-audit-'||uid||'@example.invalid',now()
FROM _i2_audit_actor;
SET LOCAL session_replication_role=origin;

SET LOCAL ROLE authenticated;
SELECT set_config('request.headers','{}',true);
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _i2_audit_actor WHERE label='A'),true);
UPDATE _i2_audit_actor SET org=(public.create_my_organization_v1('I2 audit A','PE','PEN','America/Lima')->>'organization_id')::uuid WHERE label='A';
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _i2_audit_actor WHERE label='B'),true);
UPDATE _i2_audit_actor SET org=(public.create_my_organization_v1('I2 audit B','PE','PEN','America/Lima')->>'organization_id')::uuid WHERE label='B';
RESET ROLE;

SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _i2_audit_actor WHERE label='A'),true);
SELECT set_config('request.headers','{}',true);
SELECT is(private.current_organization_id(),(SELECT org FROM _i2_audit_actor WHERE label='A'),'A resolves own tenant');
SELECT is(private.current_base_role(),'admin','A role from active membership');
SELECT lives_ok($q$SELECT private.write_audit_log((SELECT org FROM _i2_audit_actor WHERE label='A'),'identity.i2-a','membership','1','i2_contract','INSERT',NULL,'{}'::jsonb)$q$,'A may audit its own organization');
SELECT is((SELECT actor_role FROM public.audit_logs WHERE organization_id=(SELECT org FROM _i2_audit_actor WHERE label='A') AND action='identity.i2-a' ORDER BY id DESC LIMIT 1),'admin','A audit actor role sourced from selected membership');
SELECT throws_ok($q$SELECT private.write_audit_log((SELECT org FROM _i2_audit_actor WHERE label='B'),'identity.i2-cross','membership','1','i2_contract','INSERT',NULL,'{}'::jsonb)$q$,'42501',NULL,'A cannot audit B');
SELECT set_config('request.headers',jsonb_build_object('x-stomni-organization-id',(SELECT org FROM _i2_audit_actor WHERE label='B'))::text,true);
SELECT throws_ok($q$SELECT private.write_audit_log((SELECT org FROM _i2_audit_actor WHERE label='A'),'identity.i2-spoof','membership','1','i2_contract','INSERT',NULL,'{}'::jsonb)$q$,'42501',NULL,'Forged B selection does not authorize A audit');

SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _i2_audit_actor WHERE label='B'),true);
SELECT set_config('request.headers',jsonb_build_object('x-stomni-organization-id',(SELECT org FROM _i2_audit_actor WHERE label='A'))::text,true);
SELECT throws_ok($q$SELECT private.write_audit_log((SELECT org FROM _i2_audit_actor WHERE label='B'),'identity.i2-foreign','membership','1','i2_contract','INSERT',NULL,'{}'::jsonb)$q$,'42501',NULL,'B cannot audit with A selector');
SELECT set_config('request.headers',jsonb_build_object('x-stomni-organization-id',(SELECT org FROM _i2_audit_actor WHERE label='B'))::text,true);
SELECT lives_ok($q$SELECT private.write_audit_log((SELECT org FROM _i2_audit_actor WHERE label='B'),'identity.i2-b','membership','1','i2_contract','INSERT',NULL,'{}'::jsonb)$q$,'B explicitly selecting B can audit B');
SELECT is((SELECT actor_user_id FROM public.audit_logs WHERE organization_id=(SELECT org FROM _i2_audit_actor WHERE label='B') AND action='identity.i2-b' ORDER BY id DESC LIMIT 1),(SELECT uid FROM _i2_audit_actor WHERE label='B'),'B audit actor cannot be A');

SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive'
WHERE organization_id=(SELECT org FROM _i2_audit_actor WHERE label='B')
AND (app_user_id=(SELECT uid FROM _i2_audit_actor WHERE label='B') OR auth_id=(SELECT uid FROM _i2_audit_actor WHERE label='B'));
SET LOCAL session_replication_role=origin;
SELECT set_config('request.headers','{}',true);
SELECT is(private.current_organization_id(),NULL::uuid,'Revoked B has no current organization');
SELECT throws_ok($q$SELECT private.write_audit_log((SELECT org FROM _i2_audit_actor WHERE label='B'),'identity.i2-revoked','membership','1','i2_contract','INSERT',NULL,'{}'::jsonb)$q$,'42501',NULL,'Revoked B cannot attribute an audit event');
SELECT set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
SELECT throws_ok($q$SELECT private.write_audit_log((SELECT org FROM _i2_audit_actor WHERE label='A'),'identity.i2-unknown','membership','1','i2_contract','INSERT',NULL,'{}'::jsonb)$q$,'42501',NULL,'Unknown user cannot audit an active organization');

SELECT * FROM finish();
ROLLBACK;
