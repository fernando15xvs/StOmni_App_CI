import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const files=[
  'supabase/migrations/20260908051000_saas_operational_alerts_automation.sql',
  'supabase/migrations/20260908051100_saas_operational_alert_settings_safety.sql',
  'supabase/migrations/20260908051200_saas_operational_alert_event_driven_stock.sql',
];
const coreFiles=[
  'packages/core_logic/lib/automation/domain/operational_alert.dart',
  'packages/core_logic/lib/automation/application/operational_alert_gateway.dart',
  'packages/core_logic/lib/automation/data/supabase_operational_alert_gateway.dart',
  'packages/core_logic/lib/automation/providers/operational_alert_providers.dart',
];
const read=(f)=>fs.readFileSync(path.join(root,f),'utf8');
const sql=()=>files.map(read).join('\n');
const core=()=>coreFiles.map(read).join('\n');
const need=(e,s,r,l)=>{if(!r.test(s))e.push(`Falta: ${l}`);};

function verify(source,coreSource){
  const e=[];
  need(e,source,/CREATE TABLE public\.operational_alert_settings/i,'settings por tenant');
  need(e,source,/organization_id uuid PRIMARY KEY REFERENCES public\.organizations\(id\) ON DELETE CASCADE/i,'settings ownership tenant');
  need(e,source,/expiry_warning_days integer NOT NULL DEFAULT 30/i,'umbral vencimientos');
  need(e,source,/debt_overdue_days integer NOT NULL DEFAULT 30/i,'umbral antigüedad deuda');
  need(e,source,/purchase_pending_days integer NOT NULL DEFAULT 7/i,'umbral compra pendiente');
  need(e,source,/cash_session_max_hours integer NOT NULL DEFAULT 16/i,'umbral caja abierta');
  need(e,source,/organizations_create_operational_alert_settings/i,'settings automáticos para nuevos tenants');

  need(e,source,/CREATE TABLE public\.operational_alerts/i,'inbox operacional');
  need(e,source,/organization_id uuid NOT NULL REFERENCES public\.organizations\(id\) ON DELETE CASCADE/i,'alerta tenant-owned');
  need(e,source,/UNIQUE\(organization_id,dedup_key\)/i,'deduplicación por tenant');
  need(e,source,/category text NOT NULL CHECK\(category IN \('stock_low','expiry','debt_overdue','purchase_pending','cash_session_open','task'\)\)/i,'categorías roadmap');
  need(e,source,/metadata jsonb NOT NULL DEFAULT '\{\}'::jsonb[\s\S]{0,120}?pg_column_size\(metadata\)<=16384/i,'metadata alertas acotada');
  need(e,source,/ALTER TABLE public\.operational_alert_settings ENABLE ROW LEVEL SECURITY/i,'RLS settings');
  need(e,source,/ALTER TABLE public\.operational_alerts ENABLE ROW LEVEL SECURITY/i,'RLS alertas');
  need(e,source,/REVOKE ALL ON public\.operational_alert_settings,public\.operational_alerts FROM PUBLIC,anon,authenticated/i,'sin mutación Data API');
  need(e,source,/row_belongs_to_current_organization\(organization_id\)[\s\S]{0,100}?tenant\.read/i,'lectura tenant-aware');

  need(e,source,/CREATE OR REPLACE FUNCTION private\.refresh_operational_alerts_for_org/i,'motor privado de refresco');
  need(e,source,/p\.organization_id=p_organization_id[\s\S]{0,300}?stock_minimo/i,'stock bajo scopeado');
  need(e,source,/l\.organization_id=p_organization_id[\s\S]{0,220}?expiry_date/i,'vencimientos scopeados');
  need(e,source,/v\.organization_id=p_organization_id[\s\S]{0,180}?v\.estado='pendiente'/i,'deuda scopeada');
  need(e,source,/po\.organization_id=p_organization_id[\s\S]{0,180}?partially_received/i,'compras scopeadas');
  need(e,source,/sc\.organization_id=p_organization_id[\s\S]{0,180}?sc\.estado='ABIERTA'/i,'cajas scopeadas');
  need(e,source,/esquema legacy de deuda no tiene fecha contractual de vencimiento/i,'semántica deuda documentada en SQL');
  need(e,source,/last_detected_at<v_run/i,'resolución automática de alertas obsoletas');

  need(e,source,/DROP TRIGGER IF EXISTS trigger_stock_alert_evaluar_tx ON public\.inventario_almacen/i,'retira push global stock');
  need(e,source,/CREATE CONSTRAINT TRIGGER operational_stock_alert_evaluate_tx[\s\S]{0,160}?DEFERRABLE INITIALLY DEFERRED/i,'stock event-driven al final de tx');
  need(e,source,/private\.refresh_low_stock_alert_for_product/i,'reemplazo tenant-aware de stock');
  need(e,source,/ia\.organization_id=p_organization_id AND ia\.producto_id=p_product_id/i,'stock final filtrado por tenant');
  need(e,source,/operational_alert_settings_audit_change/i,'cambios de settings auditados');

  for(const rpc of ['refresh_operational_alerts_v1','list_operational_alerts_v1','acknowledge_operational_alert_v1','create_operational_task_v1','resolve_operational_alert_v1','get_operational_alert_settings_v1','update_operational_alert_settings_v1']){
    need(e,source,new RegExp(`CREATE OR REPLACE FUNCTION public\\.${rpc}\\b`,'i'),`RPC ${rpc}`);
    need(e,coreSource,new RegExp(`['"]${rpc}['"]`),`core usa RPC literal ${rpc}`);
  }
  need(e,source,/v_org uuid:=private\.require_current_organization_id\(\)/i,'RPC derivan tenant server-side');
  need(e,source,/p_expected_revision[\s\S]{0,1800}?s\.organization_id=v_org AND s\.revision=p_expected_revision/i,'settings optimistic concurrency tenant-aware');
  need(e,source,/jsonb_object_keys\(p_settings\) AS x\(key\)/i,'allowlist settings corregida');
  need(e,source,/Only tenant admin can create operational tasks/i,'tareas sólo admin');
  need(e,source,/Only tenant admin can resolve alerts manually/i,'resolución manual admin');

  need(e,coreSource,/enum OperationalAlertCategory/i,'modelo categorías Dart');
  need(e,coreSource,/class OperationalAlertSettings/i,'modelo settings Dart');
  need(e,coreSource,/abstract interface class OperationalAlertGateway/i,'contrato gateway');
  need(e,coreSource,/class SupabaseOperationalAlertGateway implements OperationalAlertGateway/i,'adaptador Supabase');
  need(e,coreSource,/operationalAlertGatewayProvider/i,'provider Riverpod');

  const migrationDir=path.join(root,'supabase','migrations');
  const all=fs.readdirSync(migrationDir).filter(x=>x.endsWith('.sql')).sort().map(x=>fs.readFileSync(path.join(migrationDir,x),'utf8')).join('\n');
  const oldCreate=Math.max(all.lastIndexOf('CREATE CONSTRAINT TRIGGER trigger_stock_alert_evaluar_tx'),all.lastIndexOf('CREATE TRIGGER trigger_stock_alert_evaluar_tx'));
  const oldDrop=all.lastIndexOf('DROP TRIGGER IF EXISTS trigger_stock_alert_evaluar_tx ON public.inventario_almacen');
  if(oldCreate>oldDrop)e.push('el trigger OneSignal global de stock fue reactivado después de F6.2');
  const postF62=fs.readdirSync(migrationDir).filter(x=>x>='20260908051000'&&x.endsWith('.sql')).sort().map(x=>fs.readFileSync(path.join(migrationDir,x),'utf8')).join('\n');
  if(/included_segments[\s\S]{0,120}?['"]All['"]/i.test(postF62))e.push('F6.2+ no puede volver a notificaciones globales segment=All');
  if(/GRANT\s+(?:INSERT|UPDATE|DELETE|ALL)[^;]*ON[^;]*operational_alerts[^;]*authenticated/i.test(source))e.push('authenticated no debe escribir operational_alerts directamente');
  return e;
}

function selfTest(){
  const s=sql(),c=core();
  const cases=[
    ['válido',s,c,false],
    ['sin tenant deuda',s.replace('v.organization_id=p_organization_id','true'),c,true],
    ['sin trigger diferido',s.replace('DEFERRABLE INITIALLY DEFERRED',''),c,true],
    ['settings sin revision tenant',s.replace('s.organization_id=v_org AND s.revision=p_expected_revision','s.revision=p_expected_revision'),c,true],
    ['RPC dinámico',s,c.replace("'refresh_operational_alerts_v1'",'rpcName'),true],
  ];
  const failed=[];
  for(const [n,a,b,shouldFail] of cases){if((verify(a,b).length>0)!==shouldFail)failed.push(n);}
  if(failed.length){console.error('SaaS operational alerts self-test FAILED:');failed.forEach(x=>console.error(`  - ${x}`));process.exit(1);}
  console.log(`SaaS operational alerts self-test OK (${cases.length} casos).`);
}

if(process.argv.includes('--self-test')){selfTest();process.exit(0);}
const errors=verify(sql(),core());
if(errors.length){console.error('SaaS operational alerts gate FAILED:');errors.forEach(x=>console.error(`  - ${x}`));process.exit(1);}
console.log('SaaS operational alerts gate OK (F6.2).');
