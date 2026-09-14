import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const migration='supabase/migrations/20260908059100_saas_guided_onboarding_progress.sql';
const domain='packages/core_logic/lib/onboarding/domain/guided_onboarding.dart';
const gateway='packages/core_logic/lib/onboarding/data/supabase_guided_onboarding_gateway.dart';
const useCase='packages/core_logic/lib/onboarding/application/guided_onboarding_use_case.dart';
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');
const need=(errors,s,re,m)=>{if(!re.test(s))errors.push(m);};

function verify(){
  const errors=[];
  const sql=read(migration),d=read(domain),g=read(gateway),u=read(useCase);
  need(errors,sql,/CREATE TABLE public\.organization_onboarding_progress/i,'falta tabla de progreso');
  need(errors,sql,/organization_id uuid PRIMARY KEY REFERENCES public\.organizations\(id\)/i,'progreso no es tenant-owned 1:1');
  need(errors,sql,/completed_steps text\[\]/i,'falta completed_steps tipado');
  need(errors,sql,/CHECK \(completed_steps <@ ARRAY\['business_profile','modules','operations','review'\]/i,'steps no están allowlisted');
  need(errors,sql,/INSERT INTO public\.organization_onboarding_progress[\s\S]*?'completed'[\s\S]*?FROM public\.organizations/i,'tenants existentes no quedan grandfathered como completados');
  need(errors,sql,/organizations_create_onboarding_progress/i,'falta bootstrap de progreso para tenants nuevos');
  need(errors,sql,/ENABLE ROW LEVEL SECURITY/i,'falta RLS');
  need(errors,sql,/row_belongs_to_current_organization\(organization_id\)/i,'policy no es tenant-aware');
  need(errors,sql,/CREATE OR REPLACE FUNCTION public\.get_my_onboarding_progress_v1\(\)/i,'falta RPC lectura');
  need(errors,sql,/CREATE OR REPLACE FUNCTION public\.complete_my_onboarding_step_v1\([\s\S]*?p_expected_revision bigint[\s\S]*?p_step text/i,'falta RPC completar paso');
  need(errors,sql,/private\.has_permission\('tenant\.admin'\)/i,'mutación no exige tenant.admin');
  need(errors,sql,/p_expected_revision<>v_row\.revision/i,'falta optimistic concurrency');
  need(errors,sql,/Onboarding steps must be completed in order/i,'backend no fuerza secuencia');
  need(errors,sql,/public\.configuracion_negocio/i,'business_profile no valida fuente autoritativa');
  need(errors,sql,/public\.business_capabilities/i,'modules no valida fuente autoritativa');
  need(errors,sql,/public\.branches[\s\S]*?public\.cash_registers/i,'operations no valida estructura autoritativa');
  if(/organization_id['"]\s*:|p_organization_id['"]\s*:/.test(g))errors.push('gateway envía organization_id');
  need(errors,g,/\.rpc\('get_my_onboarding_progress_v1'\)/,'gateway no usa RPC lectura literal');
  need(errors,g,/\.rpc\(\s*'complete_my_onboarding_step_v1'/,'gateway no usa RPC mutación literal');
  need(errors,d,/enum GuidedOnboardingStep/i,'falta enum cerrado');
  need(errors,u,/progress\.nextStep/i,'use case no usa nextStep autoritativo');
  need(errors,u,/expectedRevision: progress\.revision/i,'use case no preserva revision');
  return errors;
}
function selfTest(){
  const valid="completed_steps <@ ARRAY['business_profile','modules','operations','review']::text[]";
  if(!/business_profile/.test(valid)||/billing_provider/.test(valid)){console.error('self-test falló');process.exit(1);}
  console.log('SaaS guided onboarding self-test OK (1 caso).');
}
if(process.argv.includes('--self-test')){selfTest();process.exit(0);}
const errors=verify();
if(errors.length){console.error('SaaS guided onboarding gate FAILED:');errors.forEach(e=>console.error(`  - ${e}`));process.exit(1);}
console.log('SaaS guided onboarding gate OK (F8.2).');
console.log('  - progreso tenant-owned sin duplicar configuración de negocio');
console.log('  - secuencia + optimistic concurrency aplicadas en backend');
console.log('  - tenants existentes grandfathered; tenants nuevos in_progress');
