import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const files=[
  'supabase/migrations/20260908054000_saas_subscription_plan_catalog.sql',
  'packages/core_logic/lib/billing/domain/subscription_plan.dart',
  'packages/core_logic/lib/billing/application/subscription_plan_gateway.dart',
  'packages/core_logic/lib/billing/data/supabase_subscription_plan_gateway.dart',
  'packages/core_logic/lib/billing/providers/subscription_plan_providers.dart',
  'packages/core_logic/lib/core_logic.dart',
];
const read=f=>fs.readFileSync(path.join(root,f),'utf8');
const source=()=>files.map(read).join('\n');
const need=(e,s,r,l)=>{if(!r.test(s))e.push(`Falta: ${l}`);};

function verify(s){
  const e=[];
  need(e,s,/CREATE TABLE public\.subscription_plans/i,'subscription_plans');
  need(e,s,/code text NOT NULL UNIQUE/i,'code global estable');
  need(e,s,/tier_rank integer NOT NULL UNIQUE/i,'orden global estable');
  need(e,s,/status text NOT NULL DEFAULT 'active'[\s\S]{0,100}?active','archived'/i,'estado de plan');
  need(e,s,/pg_column_size\(metadata\) <= 8192/i,'metadata acotada');
  need(e,s,/ALTER TABLE public\.subscription_plans ENABLE ROW LEVEL SECURITY/i,'RLS catálogo');
  need(e,s,/CREATE POLICY subscription_plans_public_read/i,'lectura pública autenticada');
  need(e,s,/REVOKE INSERT,UPDATE,DELETE ON TABLE public\.subscription_plans FROM authenticated/i,'catálogo inmutable para tenant');
  for(const code of ['starter','business','pro','enterprise']) need(e,s,new RegExp(`\\('${code}'`,'i'),`seed ${code}`);
  need(e,s,/CREATE OR REPLACE FUNCTION public\.list_subscription_plans_v1/i,'RPC list plans');
  need(e,s,/WHERE p\.status='active' AND p\.is_public/i,'RPC sólo planes visibles');
  need(e,s,/class SubscriptionPlan\b/i,'modelo Dart');
  need(e,s,/abstract interface class SubscriptionPlanGateway/i,'gateway Dart');
  need(e,s,/class SupabaseSubscriptionPlanGateway implements SubscriptionPlanGateway/i,'adaptador Supabase');
  need(e,s,/['"]list_subscription_plans_v1['"]/i,'RPC literal');
  need(e,s,/publicSubscriptionPlansProvider/i,'provider catálogo');
  need(e,s,/billing\/domain\/subscription_plan\.dart/i,'barrel billing');
  if(/(?:stripe|paddle|mercadopago|paypal|provider_price|price_id)/i.test(s)) e.push('F7.1 no debe acoplar catálogo a proveedor de pagos');
  if(/monthly_price|annual_price|price_cents/i.test(s)) e.push('F7.1 no debe inventar precios comerciales');
  return e;
}

function selfTest(){
  const s=source();
  const cases=[
    ['válido',s,false],
    ['sin RLS',s.replace('ALTER TABLE public.subscription_plans ENABLE ROW LEVEL SECURITY;',''),true],
    ['sin enterprise',s.replace("('enterprise','Enterprise'","('enterprise_removed','Enterprise'"),true],
    ['precio inventado',`${s}\nmonthly_price integer;`,true],
  ];
  const failed=[];
  for(const [name,text,shouldFail] of cases){if((verify(text).length>0)!==shouldFail)failed.push(name);}
  if(failed.length){console.error('SaaS subscription plans self-test FAILED:');failed.forEach(x=>console.error(`  - ${x}`));process.exit(1);}
  console.log(`SaaS subscription plans self-test OK (${cases.length} casos).`);
}

if(process.argv.includes('--self-test')){selfTest();process.exit(0);}
const errors=verify(source());
if(errors.length){console.error('SaaS subscription plans gate FAILED:');errors.forEach(x=>console.error(`  - ${x}`));process.exit(1);}
console.log('SaaS subscription plans gate OK (F7.1).');
