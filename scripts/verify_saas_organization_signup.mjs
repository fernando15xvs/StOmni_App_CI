import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const migrationPath='supabase/migrations/20260908059000_saas_self_service_organization_signup.sql';
const domainPath='packages/core_logic/lib/onboarding/domain/organization_signup.dart';
const gatewayPath='packages/core_logic/lib/onboarding/data/supabase_organization_signup_gateway.dart';
const useCasePath='packages/core_logic/lib/onboarding/application/organization_signup_use_case.dart';

function read(p){return fs.readFileSync(path.join(root,p),'utf8');}
function need(errors,source,re,message){if(!re.test(source))errors.push(message);}
function verify(){
  const errors=[];
  const sql=read(migrationPath);
  const domain=read(domainPath);
  const gateway=read(gatewayPath);
  const useCase=read(useCasePath);

  need(errors,sql,/CREATE OR REPLACE FUNCTION public\.get_organization_signup_state_v1\(\)/i,'falta RPC de estado pre-tenant');
  need(errors,sql,/CREATE OR REPLACE FUNCTION public\.create_my_organization_v1\([\s\S]*?p_display_name text[\s\S]*?p_country_code text[\s\S]*?p_currency_code text[\s\S]*?p_timezone text/i,'falta RPC autoservicio tipada');
  need(errors,sql,/v_user uuid:=auth\.uid\(\)/i,'alta no deriva identidad de auth.uid()');
  need(errors,sql,/v_org:=public\.bootstrap_organization_v1\(/i,'alta no reutiliza bootstrap transaccional F1.4');
  need(errors,sql,/private\.set_organization_subscription_v1\([\s\S]*?v_org,'starter','active','bootstrap_default'/i,'alta nueva no queda en Starter bootstrap_default');
  need(errors,sql,/REVOKE EXECUTE ON FUNCTION public\.bootstrap_organization_v1\(text,text,text,text,text\)[\s\S]*?FROM authenticated/i,'bootstrap técnico sigue expuesto a authenticated');
  need(errors,sql,/GRANT EXECUTE ON FUNCTION public\.create_my_organization_v1\(text,text,text,text,text\) TO authenticated/i,'RPC de alta no está concedida a authenticated');
  need(errors,sql,/legacy_identity_requires_migration/i,'estado no distingue identidad legacy');
  if(/create_my_organization_v1\([\s\S]*?organization_id/i.test(sql.split('RETURNS jsonb')[0]??''))errors.push('alta acepta organization_id del cliente');
  if(/p_plan_code/i.test(sql))errors.push('alta acepta plan_code del cliente');
  if(/EXCEPTION\s+WHEN\s+OTHERS/i.test(sql))errors.push('alta captura WHEN OTHERS y puede ocultar rollback');

  need(errors,domain,/enum OrganizationSignupStateKind/i,'falta enum de estado onboarding');
  need(errors,domain,/class OrganizationSignupRequest/i,'falta request tipado');
  need(errors,domain,/class OrganizationSignupResult/i,'falta resultado tipado');
  need(errors,gateway,/\.rpc\('get_organization_signup_state_v1'\)/,'gateway no usa RPC literal de estado');
  need(errors,gateway,/\.rpc\(\s*'create_my_organization_v1'/,'gateway no usa RPC literal de alta');
  if(/organization_id['"]\s*:|p_organization_id['"]\s*:/.test(gateway))errors.push('gateway envía organization_id');
  if(/plan_code['"]\s*:|p_plan_code['"]\s*:/.test(gateway))errors.push('gateway envía plan_code');
  need(errors,useCase,/\^\[A-Z\]\{2\}\$/,'use case no normaliza/valida country code');
  need(errors,useCase,/\^\[A-Z\]\{3\}\$/,'use case no normaliza/valida currency code');

  return errors;
}

function selfTest(){
  const safe="CREATE OR REPLACE FUNCTION public.create_my_organization_v1(p_display_name text,p_country_code text,p_currency_code text,p_timezone text,p_legal_name text DEFAULT NULL) RETURNS jsonb AS $$ BEGIN v_org:=public.bootstrap_organization_v1(p_display_name,p_country_code,p_currency_code,p_timezone,p_legal_name); END $$;";
  if(/p_organization_id/i.test(safe)||/p_plan_code/i.test(safe)){console.error('self-test falló');process.exit(1);}
  const forged=safe.replace('p_display_name text','p_organization_id uuid,p_display_name text');
  if(!/p_organization_id/i.test(forged)){console.error('self-test negativo falló');process.exit(1);}
  console.log('SaaS organization signup self-test OK (2 casos).');
}

if(process.argv.includes('--self-test')){selfTest();process.exit(0);}
const errors=verify();
if(errors.length){console.error('SaaS organization signup gate FAILED:');for(const e of errors)console.error(`  - ${e}`);process.exit(1);}
console.log('SaaS organization signup gate OK (F8.1).');
console.log('  - identidad derivada server-side y bootstrap técnico no expuesto');
console.log('  - tenants autoservicio inician en Starter sin plan controlado por cliente');
console.log('  - gateway/core tipados sin organization_id manipulable');
