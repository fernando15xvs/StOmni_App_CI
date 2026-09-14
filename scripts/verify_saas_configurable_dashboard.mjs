import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const sqlFiles=[
  'supabase/migrations/20260908052000_saas_configurable_dashboard_tenant.sql',
  'supabase/migrations/20260908052100_saas_configurable_dashboard_audit.sql',
];
const coreFiles=[
  'packages/core_logic/lib/features/reportes/domain/configurable_metric.dart',
  'packages/core_logic/lib/features/reportes/application/configurable_metrics_use_case.dart',
  'packages/core_logic/lib/features/reportes/data/supabase_configurable_metric_gateway.dart',
  'packages/core_logic/lib/features/reportes/providers/configurable_metric_providers.dart',
  'packages/mobile_app/lib/features/metricas/pages/metricas_configurables_page.dart',
  'packages/desktop_app/lib/features/metrics/desktop_metrics_panel.dart',
  'packages/desktop_app/lib/features/home/desktop_dashboard_controller.dart',
  'packages/desktop_app/lib/features/home/desktop_dashboard_panel.dart',
];
const read=f=>fs.readFileSync(path.join(root,f),'utf8');
const sql=()=>sqlFiles.map(read).join('\n');
const code=()=>coreFiles.map(read).join('\n');
const need=(errors,source,regex,label)=>{if(!regex.test(source))errors.push(`Falta: ${label}`);};

function verify(s,c){
  const errors=[];
  need(errors,s,/ALTER TABLE public\.business_metric_definitions[\s\S]{0,260}?ADD COLUMN organization_id uuid/i,'organization_id en definiciones');
  need(errors,s,/business_metric_definitions_organization_fkey[\s\S]{0,120}?REFERENCES public\.organizations\(id\)/i,'FK métricas -> organizations');
  need(errors,s,/PRIMARY KEY\(organization_id,source_key\)/i,'PK métricas tenant-aware');
  need(errors,s,/UNIQUE\(organization_id,position\)/i,'posición única por tenant');
  need(errors,s,/DROP COLUMN business_id/i,'business_id singleton retirado');
  need(errors,s,/organizations_create_default_business_metrics/i,'seed métricas para nuevos tenants');
  need(errors,s,/CREATE OR REPLACE FUNCTION public\.list_business_metrics_v1/i,'list_business_metrics_v1');
  need(errors,s,/WHERE d\.organization_id=v_org/i,'list filtra tenant');
  need(errors,s,/DELETE FROM public\.business_metric_definitions WHERE organization_id=v_org/i,'save elimina sólo tenant actual');
  need(errors,s,/INSERT INTO public\.business_metric_definitions\([\s\S]{0,120}?organization_id,source_key/i,'save inserta tenant explícito');
  need(errors,s,/CREATE OR REPLACE FUNCTION public\.get_configurable_dashboard_v1/i,'RPC dashboard');
  need(errors,s,/p_end-p_start>interval '366 days'/i,'periodo máximo dashboard');
  need(errors,s,/b\.organization_id=v_org AND b\.id=p_branch_id/i,'branch validado contra tenant');
  need(errors,s,/sale_belongs_unambiguously_to_branch/i,'atribución de venta por sucursal explícita');
  need(errors,s,/m\.organization_id=v_org[\s\S]{0,520}?cr\.branch_id=p_branch_id/i,'movimientos financieros branch-aware');
  need(errors,s,/im\.organization_id=v_org[\s\S]{0,420}?a\.branch_id=p_branch_id/i,'inventario branch-aware');
  need(errors,s,/WHEN 'gross_margin' THEN[\s\S]{0,260}?v_available:=false/i,'margen fail-closed sin costo histórico');
  need(errors,s,/costo histórico inmutable por línea de venta/i,'motivo margen documentado');
  need(errors,s,/WHEN 'inventory_turnover' THEN[\s\S]{0,260}?v_available:=false/i,'rotación fail-closed');
  need(errors,s,/business_metric_definitions_audit_change/i,'configuración dashboard auditada');
  need(errors,s,/private\.write_audit_log/i,'audit usa ledger F6.1');

  for(const source of ['sales_revenue','gross_margin','inventory_turnover','dead_inventory_items','accounts_receivable','cash_performance_percent']){
    need(errors,s,new RegExp(`'${source}'`),`source SQL ${source}`);
    need(errors,c,new RegExp(source.replaceAll('_','[_A-Za-z]*'),'i'),`source Dart ${source}`);
  }
  need(errors,c,/class ConfigurableDashboardSnapshot/i,'snapshot dashboard Dart');
  need(errors,c,/final bool available;/i,'métrica expone available');
  need(errors,c,/Future<ConfigurableDashboardSnapshot> loadDashboard/i,'gateway carga dashboard');
  need(errors,c,/['"]get_configurable_dashboard_v1['"]/i,'RPC dashboard literal');
  need(errors,c,/Future<ConfigurableDashboardSnapshot> dashboard/i,'use case dashboard');
  need(errors,c,/El dashboard admite periodos de hasta 366 días/i,'validación de periodo cliente');
  need(errors,c,/No disponible/i,'UI maneja métricas no disponibles');
  need(errors,c,/Últimos 30 días/i,'UI periodo explícito');
  need(errors,c,/packages\/desktop_app|configurableMetrics/i,'desktop consume dashboard configurable');

  if(/business_metric_definitions[\s\S]{0,260}?business_id\s*=\s*1/i.test(s.slice(s.indexOf('ALTER TABLE public.business_metric_definitions')))){
    errors.push('F6.3 no debe conservar business_id=1 en el contrato final');
  }
  if(/gross_margin[\s\S]{0,500}?precio_compra/i.test(s)){
    errors.push('Margen bruto no debe usar precio_compra actual como costo histórico');
  }
  if(/inventory_turnover[\s\S]{0,500}?precio_compra/i.test(s)){
    errors.push('Rotación no debe fingirse con costo actual');
  }
  return errors;
}

function selfTest(){
  const s=sql(),c=code();
  const cases=[
    ['válido',s,c,false],
    ['singleton',`${s}\nSELECT * FROM business_metric_definitions WHERE business_id=1;`,c,true],
    ['sin branch tenant',s.replace('b.organization_id=v_org AND b.id=p_branch_id','b.id=p_branch_id'),c,true],
    ['margen fake',`${s}\n-- gross_margin SELECT precio_compra FROM productos;`,c,true],
    ['rpc dinámico',s,c.replace("'get_configurable_dashboard_v1'",'rpcName'),true],
  ];
  const failed=[];
  for(const [name,a,b,shouldFail] of cases){if((verify(a,b).length>0)!==shouldFail)failed.push(name);}
  if(failed.length){console.error('SaaS configurable dashboard self-test FAILED:');failed.forEach(x=>console.error(`  - ${x}`));process.exit(1);}
  console.log(`SaaS configurable dashboard self-test OK (${cases.length} casos).`);
}

if(process.argv.includes('--self-test')){selfTest();process.exit(0);}
const errors=verify(sql(),code());
if(errors.length){console.error('SaaS configurable dashboard gate FAILED:');errors.forEach(x=>console.error(`  - ${x}`));process.exit(1);}
console.log('SaaS configurable dashboard gate OK (F6.3).');
