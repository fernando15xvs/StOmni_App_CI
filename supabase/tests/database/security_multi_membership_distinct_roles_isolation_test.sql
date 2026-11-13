-- I4 rehearsal ONLY. One auth.uid in two simulated organizations with distinct
-- server roles, per-request selection, RLS, revocation and no cross-company
-- leakage. Schema activation trigger is disabled only inside this ROLLBACK.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(28);

CREATE TEMP TABLE _i4_identity(label text PRIMARY KEY,uid uuid,org uuid) ON COMMIT DROP;
INSERT INTO _i4_identity SELECT label,gen_random_uuid(),NULL::uuid
FROM (VALUES('A'),('B')) t(label);
GRANT SELECT,UPDATE ON _i4_identity TO authenticated;

SET LOCAL session_replication_role=replica;
INSERT INTO auth.users(id,aud,role,email,email_confirmed_at)
SELECT uid,'authenticated','authenticated',
  'i4-roles-'||uid||'@example.invalid',now() FROM _i4_identity;
SET LOCAL session_replication_role=origin;

SET LOCAL ROLE authenticated;
SELECT set_config('request.headers','{}',true);
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _i4_identity WHERE label='A'),true);
UPDATE _i4_identity SET org=(
  public.create_my_organization_v1('I4 role A','PE','PEN','America/Lima')
  ->>'organization_id')::uuid WHERE label='A';
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _i4_identity WHERE label='B'),true);
UPDATE _i4_identity SET org=(
  public.create_my_organization_v1('I4 role B','PE','PEN','America/Lima')
  ->>'organization_id')::uuid WHERE label='B';

RESET ROLE;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _i4_identity WHERE label='A'),true);
SELECT set_config('request.headers','{}',true);

-- B's former owner stops being an active member. A becomes B operator under
-- the composite schema only within this reversible certification fixture.
UPDATE public.app_users SET status='disabled'
WHERE organization_id=(SELECT org FROM _i4_identity WHERE label='B')
  AND user_id=(SELECT uid FROM _i4_identity WHERE label='B');
ALTER TABLE public.app_users DISABLE TRIGGER app_users_multi_membership_activation_gate;
INSERT INTO public.app_users(organization_id,user_id,status,base_role)
VALUES ((SELECT org FROM _i4_identity WHERE label='B'),
        (SELECT uid FROM _i4_identity WHERE label='A'),'active','operador');
SELECT set_config('request.headers',jsonb_build_object(
  'x-stomni-organization-id',(SELECT org FROM _i4_identity WHERE label='B')
)::text,true);
UPDATE public.empleados SET
  app_user_id=(SELECT uid FROM _i4_identity WHERE label='A'),
  auth_id=(SELECT uid FROM _i4_identity WHERE label='A'),
  rol='operador'
WHERE organization_id=(SELECT org FROM _i4_identity WHERE label='B')
  AND app_user_id=(SELECT uid FROM _i4_identity WHERE label='B');

-- Replace B employee's original admin grant with the canonical operator
-- grant; the employee role is NOT imported from A's server identity.
DELETE FROM public.employee_roles er
WHERE er.organization_id=(SELECT org FROM _i4_identity WHERE label='B')
  AND er.employee_id IN (
    SELECT e.id FROM public.empleados e
    WHERE e.organization_id=er.organization_id
      AND e.app_user_id=(SELECT uid FROM _i4_identity WHERE label='A')
  );
INSERT INTO public.employee_roles(organization_id,employee_id,role_id)
SELECT e.organization_id,e.id,r.id
FROM public.empleados e
JOIN public.roles r ON r.organization_id=e.organization_id
 AND r.code='operator' AND r.status='active'
WHERE e.organization_id=(SELECT org FROM _i4_identity WHERE label='B')
 AND e.app_user_id=(SELECT uid FROM _i4_identity WHERE label='A');

SET LOCAL ROLE authenticated;
SELECT set_config('request.headers','{}',true);
SELECT is(private.current_organization_id(),NULL::uuid,'Ambiguous A/B does not auto-select a company');
SELECT is(private.current_base_role(),NULL::text,'Ambiguous A/B cannot inherit a global role');
SELECT is(private.has_permission('tenant.admin'),false,'Ambiguous A/B never permits administration');
SELECT throws_ok($q$SELECT private.require_current_organization_id()$q$,'42501',NULL,
  'Business RPC requires selection when same uid has A and B');

SELECT set_config('request.headers',jsonb_build_object(
  'x-stomni-organization-id',(SELECT org FROM _i4_identity WHERE label='A')
)::text,true);
SELECT is(private.current_organization_id(),(SELECT org FROM _i4_identity WHERE label='A'),
  'A selected organization matches A');
SELECT is(private.current_base_role(),'admin','A base role is admin');
SELECT is(public.get_user_role(),'admin','A employee role is admin');
SELECT is(private.has_permission('tenant.admin'),true,'A can administer A');
SELECT is((public.get_my_subscription_v1()->>'organization_id')::uuid,
  (SELECT org FROM _i4_identity WHERE label='A'),'A subscription is A only');
SELECT is(public.get_my_effective_permissions_v1()->>'role','admin',
  'A effective role is A admin');

SELECT set_config('request.headers',jsonb_build_object(
  'x-stomni-organization-id',(SELECT org FROM _i4_identity WHERE label='B')
)::text,true);
SELECT is(private.current_organization_id(),(SELECT org FROM _i4_identity WHERE label='B'),
  'B selected organization matches B');
SELECT is(private.current_base_role(),'operador','B base role is operator');
SELECT is(public.get_user_role(),'operador','B employee role is operator');
SELECT is(private.has_permission('tenant.admin'),false,'B cannot administer through A role');
SELECT is(private.has_permission('tenant.read'),true,'B retains selected tenant read role');
SELECT is((public.get_my_subscription_v1()->>'organization_id')::uuid,
  (SELECT org FROM _i4_identity WHERE label='B'),'B subscription is B only');
SELECT is(public.get_my_effective_permissions_v1()->>'role','operator',
  'B effective role is B operator');
SELECT is(
  (public.get_my_effective_permissions_v1()->'permissions')
  ? 'business.configure',
  false,'B cannot inherit A business.configure privilege');
SELECT is((SELECT count(*)::int FROM public.organizations
 WHERE id=(SELECT org FROM _i4_identity WHERE label='A')),0,
 'B selected request cannot read A organization through RLS');
SELECT is((SELECT count(*)::int FROM public.organizations
 WHERE id=(SELECT org FROM _i4_identity WHERE label='B')),1,
 'B selected request can read its own organization');

SELECT set_config('request.headers',jsonb_build_object(
  'x-stomni-organization-id',gen_random_uuid()
)::text,true);
SELECT is(private.current_organization_id(),NULL::uuid,
  'Foreign selector fails closed with two real active memberships');
SELECT throws_ok($q$SELECT public.get_my_tenant_context_v1()$q$,'42501',NULL,
  'Unknown company context cannot reveal any business');

SELECT set_config('request.headers',jsonb_build_object(
  'x-stomni-organization-id',(SELECT org FROM _i4_identity WHERE label='A')
)::text,true);
SELECT is(private.current_base_role(),'admin',
  'Interleaving B request does not mutate the next A authorization');

RESET ROLE;
SELECT set_config('request.headers',jsonb_build_object(
  'x-stomni-organization-id',(SELECT org FROM _i4_identity WHERE label='B')
)::text,true);
UPDATE public.empleados
SET activo=false,employment_status='inactive'
WHERE organization_id=(SELECT org FROM _i4_identity WHERE label='B')
 AND app_user_id=(SELECT uid FROM _i4_identity WHERE label='A');

SET LOCAL ROLE authenticated;
SELECT is(private.current_base_role(),NULL::text,
  'Revoked B employee immediately loses selected B role');
SELECT throws_ok($q$SELECT public.get_my_subscription_v1()$q$,'42501',NULL,
  'Revoked B cannot read its subscription');
SELECT set_config('request.headers',jsonb_build_object(
  'x-stomni-organization-id',(SELECT org FROM _i4_identity WHERE label='A')
)::text,true);
SELECT is(private.current_base_role(),'admin','A stays admin when B employment revoked');
SELECT is(jsonb_array_length(public.list_my_organization_memberships_v1()),1,
  'Revoked B disappears from A membership list');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _i4_identity WHERE label='B'),true);
SELECT set_config('request.headers','{}',true);
SELECT is(private.current_organization_id(),NULL::uuid,
  'Former B-only user cannot regain a disabled tenant context');

SELECT * FROM finish();
ROLLBACK;
