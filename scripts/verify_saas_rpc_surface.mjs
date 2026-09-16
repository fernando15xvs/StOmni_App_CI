import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const domainGates = [
  'scripts/verify_saas_bootstrap.mjs',
  'scripts/verify_saas_authorization.mjs',
  'scripts/verify_saas_domain_configuration.mjs',
  'scripts/verify_saas_catalog_foundation.mjs',
  'scripts/verify_saas_inventory.mjs',
  'scripts/verify_saas_inventory_runtime.mjs',
  'scripts/verify_saas_inventory_surface.mjs',
  'scripts/verify_saas_sales.mjs',
  'scripts/verify_saas_purchases.mjs',
  'scripts/verify_saas_fiscal.mjs',
  'scripts/verify_saas_edge_functions.mjs',
  'scripts/verify_saas_rpc_transversal.mjs',
  'scripts/verify_saas_branches.mjs',
  'scripts/verify_saas_warehouse_branches.mjs',
  'scripts/verify_saas_cash_registers.mjs',
  'scripts/verify_saas_employees_structure.mjs',
  'scripts/verify_saas_configurable_roles.mjs',
  'scripts/verify_saas_tenant_capabilities.mjs',
  'scripts/verify_saas_generic_catalog.mjs',
  'scripts/verify_saas_custom_fields.mjs',
  'scripts/verify_saas_dynamic_modules_ui.mjs',
  'scripts/verify_saas_enterprise_audit.mjs',
  'scripts/verify_saas_operational_alerts.mjs',
  'scripts/verify_saas_configurable_dashboard.mjs',
  'scripts/verify_saas_business_assistant.mjs',
  'scripts/verify_saas_subscription_plans.mjs',
  'scripts/verify_saas_organization_subscriptions.mjs',
  'scripts/verify_saas_plan_entitlements.mjs',
  'scripts/verify_saas_subscription_enforcement.mjs',
  'scripts/verify_saas_billing_provider_interface.mjs',
  'scripts/verify_saas_organization_signup.mjs',
  'scripts/verify_saas_guided_onboarding.mjs',
  'scripts/verify_saas_business_branding.mjs',
  'scripts/verify_saas_observability.mjs',
];

const internalContracts = [
  // This hardening predates the consolidated bootstrap and therefore lives in
  // migration_sources/pre_bootstrap. It remains part of the static RPC audit
  // corpus, but is no longer an executable post-bootstrap migration.
  'supabase/migration_sources/pre_bootstrap/20260818220125_internal_rpc_surface_hardening.sql',
  'supabase/migrations/20260908024500_saas_fiscal_internal_rpc_scope.sql',
  'supabase/migrations/20260908024800_saas_fiscal_reconciliation_scope.sql',
  'supabase/migrations/20260908025100_saas_deferred_operational_rpc_fail_closed.sql',
];

const legacyDenied = new Set([
  'process_sale',
  'process_sale_v3',
  'process_sale_with_units_v3',
  'receive_purchase_order_v1',
  'registrar_gasto',
  '_purchase_order_json',
]);

// RPC runtime cuya seguridad está cubierta por invariantes de un gate de dominio
// aunque ese gate no repita literalmente el nombre del RPC. La clasificación sólo
// es válida si el gate dueño forma parte de domainGates y, por tanto, se ejecuta.
const explicitlyClassified = new Map([
  ['get_my_tenant_context_v1', 'scripts/verify_saas_catalog_foundation.mjs'],
  ['update_employee_permission_overrides_v1', 'scripts/verify_saas_configurable_roles.mjs'],
  ['desactivar_almacen_seguro_v1', 'scripts/verify_saas_inventory.mjs'],
  ['reactivar_almacen_seguro_v1', 'scripts/verify_saas_inventory.mjs'],
  ['save_product_unit_profile_v1', 'scripts/verify_saas_catalog_foundation.mjs'],
  ['delete_product_variant_group_v1', 'scripts/verify_saas_catalog_foundation.mjs'],
  ['eliminar_borrador_guia_v1', 'scripts/verify_saas_fiscal.mjs'],
  ['guardar_guia_remision_v4', 'scripts/verify_saas_fiscal.mjs'],
  ['obtener_disponibilidad_nota_credito_v2', 'scripts/verify_saas_fiscal.mjs'],
  ['obtener_disponibilidad_nota_credito', 'scripts/verify_saas_fiscal.mjs'],
  ['crear_nota_credito_with_units_v3', 'scripts/verify_saas_fiscal.mjs'],
  ['crear_nota_credito_v1', 'scripts/verify_saas_fiscal.mjs'],
  ['solicitar_baja_tributaria_v1', 'scripts/verify_saas_fiscal.mjs'],
  ['save_business_metrics_v1', 'scripts/verify_saas_configurable_dashboard.mjs'],
  ['deactivate_service_v1', 'scripts/verify_saas_generic_catalog.mjs'],
  ['list_inventory_lots_v1', 'scripts/verify_saas_inventory_runtime.mjs'],
  ['list_inventory_serials_v1', 'scripts/verify_saas_inventory_runtime.mjs'],
  ['resolve_sale_price_v1', 'scripts/verify_saas_sales.mjs'],
  ['delete_sale_price_rule_v1', 'scripts/verify_saas_sales.mjs'],
  ['obtener_tendencia_movimientos', 'scripts/verify_saas_rpc_transversal.mjs'],
  ['record_observability_event_v1', 'scripts/verify_saas_observability.mjs'],
]);

function read(relativePath) { return fs.readFileSync(path.join(root, relativePath), 'utf8'); }
function walk(dir) { if (!fs.existsSync(dir)) return []; const files=[]; for (const entry of fs.readdirSync(dir,{withFileTypes:true})) { const full=path.join(dir,entry.name); if (entry.isDirectory()) { if (['.dart_tool','build','coverage','node_modules'].includes(entry.name)) continue; files.push(...walk(full)); } else if (entry.isFile()) files.push(full); } return files; }
function relative(file){return path.relative(root,file).replaceAll(path.sep,'/');}
function runtimeFiles(){return [path.join(root,'apps'),path.join(root,'packages'),path.join(root,'supabase','functions')].flatMap(walk).filter(file=>{const rel=relative(file);if (/\.(g|freezed)\.dart$/.test(rel)) return false;if (/^supabase\/functions\//.test(rel)) return /\.ts$/.test(rel);return /^(apps|packages)\/[^/]+\/lib\/.*\.dart$/.test(rel);});}
function stripComments(source){return source.replace(/\/\*[\s\S]*?\*\//g,'').replace(/\/\/.*$/gm,'');}
function collectRpcCalls(source){const clean=stripComments(source),calls=[];const literal=/\.rpc\s*\(\s*['"]([a-zA-Z0-9_]+)['"]/g;for(const match of clean.matchAll(literal))calls.push({name:match[1],index:match.index??0});return{clean,calls};}
function hasDynamicRpc(clean,literalCount){return [...clean.matchAll(/\.rpc\s*\(/g)].length>literalCount;}
function lineNumber(source,index){return source.slice(0,index).split('\n').length;}
function auditCorpus(){return [...domainGates.map(read),...internalContracts.map(read)].join('\n');}
function rpcIsAudited(name,corpus){
  const owner=explicitlyClassified.get(name);
  if(owner) return domainGates.includes(owner);
  const escaped=name.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
  return new RegExp(`\\b${escaped}\\b`).test(corpus);
}
function verifyClassifications(){
  const errors=[];
  for(const [rpc,gate] of explicitlyClassified){
    if(!domainGates.includes(gate)) errors.push(`${rpc}: gate dueño no se ejecuta: ${gate}`);
    if(!fs.existsSync(path.join(root,gate))) errors.push(`${rpc}: gate dueño inexistente: ${gate}`);
  }
  return errors;
}
function verifyInternalContracts(){const errors=[];const hardening=read(internalContracts[0]),fiscalInternal=read(internalContracts[1]),reconciliation=read(internalContracts[2]),deferred=read(internalContracts[3]);if(!/REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated/i.test(hardening))errors.push('hardening interno no revoca EXECUTE cliente');if(!/GRANT EXECUTE ON FUNCTION %s TO service_role/i.test(hardening))errors.push('hardening interno no limita RPC a service_role');if(!/private\.require_service_organization_id\(\)/i.test(fiscalInternal))errors.push('RPC fiscales service_role no exigen tenant interno');if(!/x-stomni-organization-id/i.test(fiscalInternal))errors.push('contrato de header tenant interno ausente');if(!/CREATE OR REPLACE FUNCTION public\.resolver_resultado_incierto_v1/i.test(reconciliation))errors.push('resolver_resultado_incierto_v1 no está endurecido');if(!/v_org uuid := private\.require_service_organization_id\(\)/i.test(reconciliation))errors.push('reconciliación no exige tenant service_role');if(!/WHERE organization_id = v_org[\s\S]{0,100}?AND id = p_documento_id/i.test(reconciliation))errors.push('reconciliación no filtra documento por tenant');if(!/INSERT INTO public\.documentos_tributarios_reconciliaciones\(\s*organization_id,/i.test(reconciliation))errors.push('reconciliación no persiste organization_id');if(!/REVOKE ALL ON FUNCTION public\.resolver_resultado_incierto_v1[\s\S]{0,180}?FROM PUBLIC, anon, authenticated/i.test(reconciliation))errors.push('reconciliación no revoca clientes');if(!/CREATE OR REPLACE FUNCTION public\.get_estado_caja_chica\(\)[\s\S]{0,420}?private\.require_current_organization_id\(\)/i.test(deferred))errors.push('transición de Caja diferida no exigía tenant válido');if(!/REVOKE ALL ON FUNCTION public\.registrar_pago_empleado_mixto[\s\S]{0,180}?FROM PUBLIC, anon, authenticated/i.test(deferred))errors.push('transición de pagos de empleado no estuvo fail-closed antes de F4.4');return errors;}
function verifyRuntime(){const errors=[],corpus=auditCorpus(),seen=new Map();for(const file of runtimeFiles()){const rel=relative(file),source=fs.readFileSync(file,'utf8'),{clean,calls}=collectRpcCalls(source);if(hasDynamicRpc(clean,calls.length))errors.push(`${rel}: llamada rpc() dinámica/no literal; no puede auditarse de forma determinista`);for(const call of calls){if(!seen.has(call.name))seen.set(call.name,[]);seen.get(call.name).push(`${rel}:${lineNumber(clean,call.index)}`);if(legacyDenied.has(call.name)){errors.push(`${rel}: RPC legacy prohibido en runtime: ${call.name}`);continue;}if(!rpcIsAudited(call.name,corpus))errors.push(`${rel}: RPC sin clasificación/gate SaaS: ${call.name}`);const window=clean.slice(call.index,call.index+900);if(/['"](?:organization_id|p_organization_id)['"]\s*:/i.test(window))errors.push(`${rel}: ${call.name} recibe organization_id desde el llamador`);}}return{errors,seen};}
function runDomainGates(){const errors=[];for(const gate of domainGates){const result=spawnSync(process.execPath,[path.join(root,gate)],{cwd:root,encoding:'utf8',env:process.env});if(result.status!==0){errors.push(`${gate} falló`);const output=`${result.stdout??''}\n${result.stderr??''}`.trim();if(output)errors.push(output);}}return errors;}
function selfTest(){const corpus="need(errors, x, /create_purchase_order_v1/, 'auditado');";const safe=collectRpcCalls("await client.rpc('create_purchase_order_v1', params: {'p_id': 1});");if(safe.calls.length!==1||safe.calls[0].name!=='create_purchase_order_v1')process.exitCode=1;if(!rpcIsAudited('create_purchase_order_v1',corpus))process.exitCode=1;const dynamic=collectRpcCalls('await client.rpc(rpcName, params: {});');if(!hasDynamicRpc(dynamic.clean,dynamic.calls.length))process.exitCode=1;const forged=collectRpcCalls("await client.rpc('safe_v1', params: {'p_organization_id': forged});");const forgedWindow=forged.clean.slice(forged.calls[0].index,forged.calls[0].index+900);if(!/['"](?:organization_id|p_organization_id)['"]\s*:/i.test(forgedWindow))process.exitCode=1;if(!legacyDenied.has('receive_purchase_order_v1')||legacyDenied.has('registrar_pago_empleado_mixto'))process.exitCode=1;if(!rpcIsAudited('record_observability_event_v1',''))process.exitCode=1;if(verifyClassifications().length)process.exitCode=1;if(process.exitCode){console.error('SaaS RPC self-test FAILED');process.exit(1);}console.log('SaaS RPC self-test OK (6 casos).');}
if(process.argv.includes('--self-test')){selfTest();process.exit(0);}const runtime=verifyRuntime();const errors=[...runtime.errors,...verifyClassifications(),...verifyInternalContracts(),...runDomainGates()];if(errors.length){console.error('SaaS RPC surface gate FAILED:');errors.forEach(error=>console.error(`  - ${error}`));process.exit(1);}console.log('SaaS RPC surface gate OK.');console.log(`  - ${runtime.seen.size} RPC runtime/Edge clasificados`);console.log(`  - ${domainGates.length} gates de dominio ejecutados`);console.log(`  - ${internalContracts.length} contratos service_role/transición auditados`);console.log('  - cero RPC dinámicos sin nombre literal');console.log('  - cero organization_id controlados por llamador');console.log('  - RPC legacy críticos bloqueados; reaperturas operativas requieren gate de fase');
