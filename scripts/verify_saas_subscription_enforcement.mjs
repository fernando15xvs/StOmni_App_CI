import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const files=[
 'supabase/migrations/20260908056100_saas_plan_entitlements_expiry_feature.sql',
 'supabase/migrations/20260908057000_saas_subscription_backend_enforcement.sql',
 'supabase/migrations/20260908057100_saas_subscription_analytics_assistant_enforcement.sql',
 'supabase/migrations/20260908057200_saas_subscription_change_audit.sql',
];
const read=f=>fs.readFileSync(path.join(root,f),'utf8');
const source=()=>files.map(read).join('\n');
const need=(e,s,r,l)=>{if(!r.test(s))e.push(`Falta: ${l}`);};

function verify(s){
 const e=[];
 need(e,s,/feature\.expiry_tracking/i,'entitlement expiry_tracking');
 need(e,s,/CREATE OR REPLACE FUNCTION private\.subscription_access_allowed/i,'helper subscription usable');
 need(e,s,/CREATE OR REPLACE FUNCTION private\.assert_plan_compatible_with_organization/i,'validador downgrade');
 for(const pair of [
   ['inventory_enabled','feature.inventory'],['multiple_branches','feature.multiple_branches'],['multiple_warehouses','feature.multiple_warehouses'],
   ['credit_sales','feature.credit_sales'],['electronic_invoicing','feature.electronic_invoicing'],['purchase_management','feature.purchase_management'],
   ['services','feature.services'],['variants','feature.variants'],['lot_tracking','feature.lot_tracking'],['expiry_tracking','feature.expiry_tracking'],
   ['serial_number_tracking','feature.serial_tracking']]){
   need(e,s,new RegExp(`${pair[0]}[\\s\\S]{0,160}?${pair[1].replace('.','\\.')}`,'i'),`mapping ${pair[0]} -> ${pair[1]}`);
 }
 for(const key of ['limit.users','limit.branches','limit.warehouses','limit.cash_registers']) need(e,s,new RegExp(key.replace('.','\\.'),'i'),`enforcement ${key}`);
 need(e,s,/zz_app_users_subscription_limit/i,'trigger users');
 need(e,s,/zz_branches_subscription_limit/i,'trigger branches');
 need(e,s,/zz_almacenes_subscription_limit/i,'trigger warehouses');
 need(e,s,/zz_cash_registers_subscription_limit/i,'trigger cash registers');
 need(e,s,/zz_business_capabilities_subscription_guard/i,'trigger capabilities');
 need(e,s,/p_status IN \('active','trialing'\)[\s\S]{0,120}?assert_plan_compatible_with_organization/i,'downgrade preflight');
 need(e,s,/FOR v_org IN SELECT s\.organization_id[\s\S]{0,260}?assert_plan_compatible_with_organization/i,'cambio packaging valida tenants asignados');
 need(e,s,/require_subscription_feature_for_org\(v_org,''feature\.analytics''\)/i,'analytics backend entitlement');
 need(e,s,/require_subscription_feature_for_org\(v_org,''feature\.business_assistant''\)/i,'assistant backend entitlement');
 need(e,s,/Unexpected dashboard BEGIN contract/i,'patch dashboard fail-closed');
 need(e,s,/Unexpected assistant context definition/i,'patch assistant fail-closed');
 need(e,s,/organization_subscriptions_audit_change/i,'audit subscription changes');
 need(e,s,/subscription\.updated/i,'evento auditoría suscripción');
 if(/organization_id\s*=>|p_organization_id['"]\s*:/i.test(s)) e.push('F7.4 no debe introducir tenant controlado por cliente');
 return e;
}

function selfTest(){
 const s=source();
 const cases=[
  ['válido',s,false],
  ['sin user limit',s.replace('zz_app_users_subscription_limit','removed_user_limit'),true],
  ['sin analytics',s.replace("require_subscription_feature_for_org(v_org,''feature.analytics'')","PERFORM true"),true],
  ['sin downgrade preflight',s.replace("IF p_status IN ('active','trialing') THEN PERFORM private.assert_plan_compatible_with_organization(p_organization_id,v_plan); END IF;",''),true],
 ];
 const failed=[];
 for(const [name,text,shouldFail] of cases){if((verify(text).length>0)!==shouldFail)failed.push(name);}
 if(failed.length){console.error('SaaS subscription enforcement self-test FAILED:');failed.forEach(x=>console.error(`  - ${x}`));process.exit(1);}
 console.log(`SaaS subscription enforcement self-test OK (${cases.length} casos).`);
}
if(process.argv.includes('--self-test')){selfTest();process.exit(0);}const e=verify(source());if(e.length){console.error('SaaS subscription enforcement gate FAILED:');e.forEach(x=>console.error(`  - ${x}`));process.exit(1);}console.log('SaaS subscription enforcement gate OK (F7.4).');
