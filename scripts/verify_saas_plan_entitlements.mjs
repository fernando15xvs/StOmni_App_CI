import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const files=[
 'supabase/migrations/20260908056000_saas_plan_entitlements_limits.sql',
 'packages/core_logic/lib/billing/domain/subscription_entitlement.dart',
 'packages/core_logic/lib/billing/application/subscription_entitlement_gateway.dart',
 'packages/core_logic/lib/billing/data/supabase_subscription_entitlement_gateway.dart',
 'packages/core_logic/lib/billing/providers/subscription_entitlement_providers.dart',
];
const s=files.map(f=>fs.readFileSync(path.join(root,f),'utf8')).join('\n');
const need=(e,r,l)=>{if(!r.test(s))e.push(`Falta: ${l}`);};
function verify(){
 const e=[];
 need(e,/CREATE TABLE public\.entitlement_definitions/i,'definiciones');
 need(e,/kind text NOT NULL CHECK \(kind IN \('feature','limit'\)\)/i,'tipos feature/limit');
 need(e,/CREATE TABLE public\.plan_entitlements/i,'plan_entitlements');
 need(e,/PRIMARY KEY\(plan_id,entitlement_key\)/i,'PK plan+entitlement');
 need(e,/limit_value bigint/i,'limit_value');
 need(e,/feature\.inventory/i,'feature inventory');
 need(e,/feature\.business_assistant/i,'feature assistant');
 need(e,/limit\.users/i,'limit users');
 need(e,/limit\.branches/i,'limit branches');
 need(e,/limit\.warehouses/i,'limit warehouses');
 need(e,/limit\.cash_registers/i,'limit cash registers');
 need(e,/Seed neutral/i,'seed neutral documentado');
 need(e,/SELECT p\.id,d\.key,true,NULL/i,'entitlements neutrales sin límites inventados');
 need(e,/CREATE OR REPLACE FUNCTION public\.get_my_entitlements_v1/i,'RPC entitlements');
 need(e,/private\.require_current_organization_id\(\)/i,'tenant server-side');
 need(e,/private\.subscription_feature_enabled/i,'helper feature');
 need(e,/private\.subscription_limit_value/i,'helper límite');
 need(e,/private\.set_plan_entitlement_v1/i,'writer privilegiado');
 need(e,/current_user NOT IN \('postgres','service_role'\)/i,'writer privilegiado');
 need(e,/class SubscriptionEntitlement/i,'modelo Dart');
 need(e,/['"]get_my_entitlements_v1['"]/i,'RPC literal Dart');
 if(/limit\.users[\s\S]{0,80}?VALUES?\s*\([^\)]*[1-9][0-9]*/i.test(s))e.push('No inventar límites comerciales en F7.3');
 return e;
}
if(process.argv.includes('--self-test')){const e=verify();if(e.length){console.error(e.join('\n'));process.exit(1);}console.log('SaaS plan entitlements self-test OK.');process.exit(0);}const e=verify();if(e.length){console.error('SaaS plan entitlements gate FAILED:');e.forEach(x=>console.error(`  - ${x}`));process.exit(1);}console.log('SaaS plan entitlements gate OK (F7.3).');
