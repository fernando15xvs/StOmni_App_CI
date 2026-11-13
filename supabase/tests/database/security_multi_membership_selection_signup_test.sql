-- 2D-I2: Real authenticated account state, tenant listing, selector denial,
-- and a rollback-only simulation of a future second membership. Never activate
-- multiple memberships in the persistent schema from this test.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(35);

CREATE TEMP TABLE _i2_member_actor(
  label text PRIMARY KEY,
  uid uuid NOT NULL,
  org uuid
) ON COMMIT DROP;
INSERT INTO _i2_member_actor(label,uid)
SELECT label,gen_random_uuid() FROM (VALUES('A'),('B'),('C')) AS v(label);
GRANT SELECT,UPDATE ON _i2_member_actor TO authenticated;
INSERT INTO auth.users(id,aud,role,email,email_confirmed_at)
SELECT uid,'authenticated','authenticated',
  'i2-membership-'||uid||'@example.invalid',now()
FROM _i2_member_actor;

SELECT ok(to_regprocedure('public.list_my_organization_memberships_v1()') IS NOT NULL,
  'User membership list RPC exists');
SELECT is(has_function_privilege('authenticated','public.list_my_organization_memberships_v1()','EXECUTE'),true,
  'Authenticated clients can enumerate only their membership rows');
SELECT is(has_function_privilege('anon','public.list_my_organization_memberships_v1()','EXECUTE'),false,
  'Anonymous clients cannot call member list');
SELECT ok((SELECT prosecdef FROM pg_proc WHERE oid='public.list_my_organization_memberships_v1()'::regprocedure),
  'Membership list is a reviewed fixed-search-path definer');

SET LOCAL ROLE authenticated;
SELECT set_config('request.headers','{}',true);
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _i2_member_actor WHERE label='A'),true);
UPDATE _i2_member_actor SET org=(
  public.create_my_organization_v1('I2 membership A','PE','PEN','America/Lima')->>'organization_id'
)::uuid WHERE label='A';
SELECT is(public.get_organization_signup_state_v1()->>'state','attached',
  'A bootstrap returns legacy attached state');
SELECT is((public.get_organization_signup_state_v1()->>'organization_id')::uuid,
 (SELECT org FROM _i2_member_actor WHERE label='A'),'A signup returns its own org');
SELECT is(jsonb_array_length(public.list_my_organization_memberships_v1()),1,
  'A initially has exactly one active membership');
SELECT is(public.list_my_organization_memberships_v1()->0->>'base_role','admin',
  'Listed role comes from A database membership');

SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _i2_member_actor WHERE label='B'),true);
UPDATE _i2_member_actor SET org=(
  public.create_my_organization_v1('I2 membership B','PE','PEN','America/Lima')->>'organization_id'
)::uuid WHERE label='B';

SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _i2_member_actor WHERE label='A'),true);
SELECT set_config('request.headers',jsonb_build_object(
  'x-stomni-organization-id',(SELECT org FROM _i2_member_actor WHERE label='B')
)::text,true);
SELECT is(public.get_organization_signup_state_v1()->>'state','access_revoked',
  'Forged foreign B selection cannot read A signup state');
SELECT is(public.get_organization_signup_state_v1()->>'organization_id',NULL::text,
  'Foreign tenant id and metadata are redacted');
SELECT is(jsonb_array_length(public.list_my_organization_memberships_v1()),1,
  'Foreign selection never adds B to A memberships');
SELECT is((public.list_my_organization_memberships_v1()->0->>'organization_id')::uuid,
  (SELECT org FROM _i2_member_actor WHERE label='A'),
  'Membership list always scoped to auth.uid regardless of header');
SELECT set_config('request.jwt.claim.sub','',true);
SELECT throws_ok($q$SELECT public.get_organization_signup_state_v1()$q$,'28000',NULL,
  'Signup RPC requires an authenticated identity');
SELECT throws_ok($q$SELECT public.list_my_organization_memberships_v1()$q$,'28000',NULL,
  'Membership list RPC requires an authenticated identity');

RESET ROLE;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _i2_member_actor WHERE label='A'),true);
SELECT set_config('request.headers','{}',true);

-- Only within this transaction: an administrator temporarily disables the
-- I4 activation trigger to emulate the future schema. ROLLBACK restores it.
-- Disabling B's old membership avoids subscription user limits.
UPDATE public.app_users SET status='disabled'
 WHERE user_id=(SELECT uid FROM _i2_member_actor WHERE label='B')
   AND organization_id=(SELECT org FROM _i2_member_actor WHERE label='B');
ALTER TABLE public.app_users DISABLE TRIGGER app_users_multi_membership_activation_gate;
INSERT INTO public.app_users(user_id,organization_id,status,base_role)
VALUES(
 (SELECT uid FROM _i2_member_actor WHERE label='A'),
 (SELECT org FROM _i2_member_actor WHERE label='B'),
 'active','admin'
);
SELECT set_config('request.headers',jsonb_build_object(
  'x-stomni-organization-id',(SELECT org FROM _i2_member_actor WHERE label='B')
)::text,true);
UPDATE public.empleados
SET app_user_id=(SELECT uid FROM _i2_member_actor WHERE label='A'),
    auth_id=(SELECT uid FROM _i2_member_actor WHERE label='A')
WHERE organization_id=(SELECT org FROM _i2_member_actor WHERE label='B')
  AND app_user_id=(SELECT uid FROM _i2_member_actor WHERE label='B');
SET LOCAL ROLE authenticated;
SELECT set_config('request.headers','{}',true);
SELECT is(public.get_organization_signup_state_v1()->>'state','selection_required',
  'Two active memberships require an explicit company selection');
SELECT is(public.get_organization_signup_state_v1()->>'organization_id',NULL::text,
  'Ambiguous signup response never exposes an arbitrary company');
SELECT is(jsonb_array_length(public.list_my_organization_memberships_v1()),2,
  'User can enumerate two companies to choose between');
SELECT is(private.current_organization_id(),NULL::uuid,
  'Operational identity without selection fails closed');
SELECT is(private.current_base_role(),NULL::text,
  'Role without selection cannot inherit another company permissions');
SELECT throws_ok($q$SELECT public.get_my_tenant_context_v1()$q$,'42501',NULL,
  'Business context cannot be used before choosing a company');

SELECT set_config('request.headers',jsonb_build_object(
  'x-stomni-organization-id',(SELECT org FROM _i2_member_actor WHERE label='A')
)::text,true);
SELECT is((public.get_organization_signup_state_v1()->>'organization_id')::uuid,
  (SELECT org FROM _i2_member_actor WHERE label='A'),'Explicit A returns only A');
SELECT is(private.current_base_role(),'admin','Explicit A role remains its own admin');
SELECT set_config('request.headers',jsonb_build_object(
  'x-stomni-organization-id',(SELECT org FROM _i2_member_actor WHERE label='B')
)::text,true);
SELECT is((public.get_organization_signup_state_v1()->>'organization_id')::uuid,
  (SELECT org FROM _i2_member_actor WHERE label='B'),'Explicit B returns only B');
SELECT is((public.get_my_tenant_context_v1()->>'organization_id')::uuid,
  (SELECT org FROM _i2_member_actor WHERE label='B'),'Operational context follows B request');
SELECT is(private.current_base_role(),'admin','Explicit B role follows selected B membership');

SELECT set_config('request.headers',jsonb_build_object(
  'x-stomni-organization-id',gen_random_uuid()
)::text,true);
SELECT is(public.get_organization_signup_state_v1()->>'state','access_revoked',
  'Unknown tenant selector is denied');
SELECT is(public.get_organization_signup_state_v1()->>'organization_id',NULL::text,
  'Denied selector exposes no tenant id');
SELECT set_config('request.headers','{"x-stomni-organization-id":"not-a-uuid"}',true);
SELECT throws_ok($q$SELECT public.get_organization_signup_state_v1()$q$,'42501',NULL,
  'Malformed company UUID cannot be selected');

RESET ROLE;
SELECT set_config('request.headers',jsonb_build_object(
  'x-stomni-organization-id',(SELECT org FROM _i2_member_actor WHERE label='B')
)::text,true);
UPDATE public.empleados
SET activo=false,employment_status='inactive'
WHERE organization_id=(SELECT org FROM _i2_member_actor WHERE label='B')
  AND app_user_id=(SELECT uid FROM _i2_member_actor WHERE label='A');
SET LOCAL ROLE authenticated;
SELECT set_config('request.headers','{}',true);
SELECT is(jsonb_array_length(public.list_my_organization_memberships_v1()),1,
  'Revoking B employment removes B from selectable memberships');
SELECT is((public.get_organization_signup_state_v1()->>'organization_id')::uuid,
  (SELECT org FROM _i2_member_actor WHERE label='A'),
  'A remains active after B employment is revoked');
SELECT set_config('request.headers',jsonb_build_object(
  'x-stomni-organization-id',(SELECT org FROM _i2_member_actor WHERE label='B')
)::text,true);
SELECT is(public.get_organization_signup_state_v1()->>'state','access_revoked',
  'Revoked selected B cannot reveal business data');

SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _i2_member_actor WHERE label='B'),true);
SELECT set_config('request.headers','{}',true);
SELECT is(public.get_organization_signup_state_v1()->>'state','access_revoked',
  'Former B user with disabled membership is not eligible to create a tenant');
SELECT is(jsonb_array_length(public.list_my_organization_memberships_v1()),0,
  'Disabled original B membership cannot be enumerated');

SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _i2_member_actor WHERE label='C'),true);
SELECT is(public.get_organization_signup_state_v1()->>'state','eligible',
  'New C without membership can still perform signup');
SELECT is(jsonb_array_length(public.list_my_organization_memberships_v1()),0,
  'New C without membership sees no foreign companies');

SELECT * FROM finish();
ROLLBACK;
