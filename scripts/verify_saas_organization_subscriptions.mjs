import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const files=[
  'supabase/migrations/20260908055000_saas_organization_subscriptions.sql',
  'packages/core_logic/lib/billing/domain/organization_subscription.dart',
  'packages/core_logic/lib/billing/application/organization_subscription_gateway.dart',
  'packages/core_logic/lib/billing/data/supabase_organization_subscription_gateway.dart',
  'packages/core_logic/lib/billing/providers/organization_subscription_providers.dart',
  'packages/core_logic/lib/core_logic.dart',
];
const s=files.map(f=>fs.readFileSync(path.join(root,f),'utf8')).join('\n');
const need=(e,r,l)=>{if(!r.test(s))e.push(`Falta: ${l}`);};
function verify(){
 const e=[];
 need(e,/CREATE TABLE public\.organization_subscriptions/i,'tabla suscripciones');
 need(e,/organization_id uuid PRIMARY KEY REFERENCES public\.organizations/i,'una suscripción por organización');
 need(e,/plan_id uuid NOT NULL REFERENCES public\.subscription_plans/i,'FK plan global');
 need(e,/trialing','active','past_due','suspended','canceled'/i,'estados suscripción');
 need(e,/revision bigint NOT NULL DEFAULT 1/i,'optimistic concurrency');
 need(e,/CREATE POLICY organization_subscriptions_tenant_read/i,'RLS tenant read');
 need(e,/legacy_grandfathered/i,'compatibilidad rollout existentes');
 need(e,/bootstrap_default/i,'compatibilidad nuevos tenants');
 need(e,/code='enterprise'/i,'default transición full access');
 need(e,/organizations_create_default_subscription/i,'trigger nuevos tenants');
 need(e,/CREATE OR REPLACE FUNCTION public\.get_my_subscription_v1/i,'RPC current subscription');
 need(e,/v_org uuid:=private\.require_current_organization_id\(\)/i,'tenant server-side');
 need(e,/CREATE OR REPLACE FUNCTION private\.set_organization_subscription_v1/i,'writer privado');
 need(e,/current_user NOT IN \('postgres','service_role'\)/i,'writer sólo privilegiado');
 need(e,/s\.organization_id=p_organization_id AND s\.revision=p_expected_revision/i,'writer revision + tenant');
 need(e,/REVOKE ALL ON public\.organization_subscriptions FROM PUBLIC,anon,authenticated/i,'sin mutación directa');
 need(e,/class OrganizationSubscription/i,'modelo Dart');
 need(e,/['"]get_my_subscription_v1['"]/i,'RPC literal Dart');
 need(e,/currentOrganizationSubscriptionProvider/i,'provider subscription');
 return e;
}
function selfTest(){const errors=verify();if(errors.length){console.error(errors.join('\n'));process.exit(1);}console.log('SaaS organization subscriptions self-test OK.');}
if(process.argv.includes('--self-test')){selfTest();process.exit(0);}const errors=verify();if(errors.length){console.error('SaaS organization subscriptions gate FAILED:');errors.forEach(x=>console.error(`  - ${x}`));process.exit(1);}console.log('SaaS organization subscriptions gate OK (F7.2).');
