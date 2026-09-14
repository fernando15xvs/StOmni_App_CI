import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const sqlFiles=[
  'supabase/migrations/20260908053000_saas_business_assistant_safe_context.sql',
  'supabase/migrations/20260908053100_saas_business_assistant_audit.sql',
];
const coreFiles=[
  'packages/core_logic/lib/assistant/domain/business_assistant.dart',
  'packages/core_logic/lib/assistant/application/business_assistant_gateway.dart',
  'packages/core_logic/lib/assistant/application/business_assistant_use_case.dart',
  'packages/core_logic/lib/assistant/data/supabase_business_assistant_gateway.dart',
  'packages/core_logic/lib/assistant/providers/business_assistant_providers.dart',
  'packages/core_logic/lib/core_logic.dart',
];
const read=f=>fs.readFileSync(path.join(root,f),'utf8');
const sql=()=>sqlFiles.map(read).join('\n');
const core=()=>coreFiles.map(read).join('\n');
const need=(e,s,r,l)=>{if(!r.test(s))e.push(`Falta: ${l}`);};

function executableSql(source){
  return source
    .replace(/--.*$/gm,' ')
    .replace(/\/\*[\s\S]*?\*\//g,' ')
    .replace(/'(?:''|[^'])*'/g,"''");
}

function verify(s,c){
  const e=[];
  need(e,s,/CREATE TABLE public\.business_assistant_settings/i,'settings asistente');
  need(e,s,/organization_id uuid PRIMARY KEY REFERENCES public\.organizations\(id\) ON DELETE CASCADE/i,'settings tenant-owned');
  need(e,s,/enabled boolean NOT NULL DEFAULT false/i,'asistente deshabilitado por defecto');
  need(e,s,/max_result_items integer NOT NULL DEFAULT 20[\s\S]{0,100}?BETWEEN 1 AND 50/i,'límite máximo resultados');
  need(e,s,/default_period_days integer NOT NULL DEFAULT 30[\s\S]{0,100}?BETWEEN 1 AND 365/i,'periodo acotado');
  need(e,s,/revision bigint NOT NULL DEFAULT 1/i,'optimistic concurrency');
  need(e,s,/organizations_create_business_assistant_settings/i,'settings para nuevos tenants');
  need(e,s,/ALTER TABLE public\.business_assistant_settings ENABLE ROW LEVEL SECURITY/i,'RLS settings');
  need(e,s,/REVOKE ALL ON public\.business_assistant_settings FROM PUBLIC,anon,authenticated/i,'sin mutación tabla directa');
  need(e,s,/row_belongs_to_current_organization\(organization_id\)[\s\S]{0,120}?tenant\.read/i,'lectura settings tenant-aware');

  need(e,s,/CREATE OR REPLACE FUNCTION public\.get_business_assistant_context_v1/i,'RPC contexto');
  need(e,s,/v_org uuid:=private\.require_current_organization_id\(\)/i,'tenant derivado server-side');
  need(e,s,/reports\.view_profit/i,'permiso reportes requerido');
  need(e,s,/NOT v_settings\.enabled[\s\S]{0,120}?Business assistant is disabled/i,'feature opt-in por tenant');
  need(e,s,/v_intent NOT IN \('replenishment','non_moving_products','overdue_receivables','margin_diagnostics'\)/i,'intenciones allowlisted');
  need(e,s,/v_days NOT BETWEEN 1 AND 365/i,'periodo validado backend');
  need(e,s,/v_limit NOT BETWEEN 1 AND v_settings\.max_result_items/i,'limit validado backend');
  need(e,s,/b\.organization_id=v_org AND b\.id=p_branch_id/i,'branch pertenece tenant');
  need(e,s,/p\.organization_id=v_org[\s\S]{0,500}?stock_minimo/i,'reposición tenant-aware');
  need(e,s,/im\.organization_id=v_org[\s\S]{0,500}?salida_cant/i,'no-rotación tenant-aware');
  need(e,s,/v\.organization_id=v_org[\s\S]{0,400}?v\.estado='pendiente'/i,'cuentas por cobrar tenant-aware');
  need(e,s,/sale_belongs_unambiguously_to_branch\(v_org,v\.id,p_branch_id\)/i,'receivables branch-safe');
  need(e,s,/WHEN 'margin_diagnostics' THEN[\s\S]{0,300}?costo histórico inmutable/i,'margen fail-closed');
  need(e,s,/no generan compras automáticamente/i,'reposición sólo recomendación');
  need(e,s,/business_assistant_settings_audit_change/i,'settings auditados');
  need(e,s,/private\.write_audit_log/i,'auditoría usa ledger F6.1');

  for(const rpc of ['get_business_assistant_settings_v1','update_business_assistant_settings_v1','get_business_assistant_context_v1']){
    need(e,s,new RegExp(`CREATE OR REPLACE FUNCTION public\\.${rpc}\\b`,'i'),`RPC ${rpc}`);
    need(e,c,new RegExp(`['"]${rpc}['"]`),`core usa RPC literal ${rpc}`);
  }
  need(e,s,/WHERE organization_id=v_org AND revision=p_expected_revision/i,'settings update tenant+revision');
  need(e,s,/Only tenant admin can configure business assistant/i,'settings sólo admin');
  need(e,c,/enum BusinessAssistantIntent/i,'enum intención Dart');
  need(e,c,/abstract interface class BusinessAssistantGateway/i,'gateway Dart');
  need(e,c,/class SupabaseBusinessAssistantGateway implements BusinessAssistantGateway/i,'adaptador Supabase');
  need(e,c,/class BusinessAssistantUseCase/i,'use case Dart');
  need(e,c,/BusinessAssistantIntent intent/i,'use case sólo intención tipada');
  need(e,c,/businessAssistantUseCaseProvider/i,'provider Riverpod');
  need(e,c,/assistant\/domain\/business_assistant\.dart/i,'barrel exporta asistente');

  if(/\b(sql|query|table|schema|organization_id|p_organization_id)\b\s*:/i.test(c.match(/client\.rpc\('get_business_assistant_context_v1'[\s\S]*?\);/i)?.[0]??'')){
    e.push('cliente asistente no debe enviar SQL, tabla, schema ni organization_id');
  }

  const executable=executableSql(s);
  if(/\bservice_role\b/i.test(executable))e.push('F6.4 no debe depender de service_role para contexto del asistente');
  if(/EXECUTE\s+format\s*\(|EXECUTE\s+p_/i.test(executable))e.push('F6.4 no admite SQL dinámico ejecutable');
  if(/\bprecio_compra\b/i.test(executable))e.push('diagnóstico de margen no debe usar costo actual como histórico');
  return e;
}

function selfTest(){
  const s=sql(),c=core();
  const cases=[
    ['válido',s,c,false],
    ['service role ejecutable',`${s}\nDO $$ BEGIN PERFORM service_role; END $$;`,c,true],
    ['costo actual ejecutable',`${s}\nSELECT precio_compra FROM public.inventario_almacen;`,c,true],
    ['intent abierto',s.replace("v_intent NOT IN ('replenishment','non_moving_products','overdue_receivables','margin_diagnostics')","false"),c,true],
    ['branch sin tenant',s.replace('b.organization_id=v_org AND b.id=p_branch_id','b.id=p_branch_id'),c,true],
    ['RPC dinámico',s,c.replace("'get_business_assistant_context_v1'",'rpcName'),true],
  ];
  const failed=[];
  for(const [n,a,b,shouldFail] of cases){if((verify(a,b).length>0)!==shouldFail)failed.push(n);}
  if(failed.length){console.error('SaaS business assistant self-test FAILED:');failed.forEach(x=>console.error(`  - ${x}`));process.exit(1);}
  console.log(`SaaS business assistant self-test OK (${cases.length} casos).`);
}

if(process.argv.includes('--self-test')){selfTest();process.exit(0);}
const errors=verify(sql(),core());
if(errors.length){console.error('SaaS business assistant gate FAILED:');errors.forEach(x=>console.error(`  - ${x}`));process.exit(1);}
console.log('SaaS business assistant gate OK (F6.4).');
