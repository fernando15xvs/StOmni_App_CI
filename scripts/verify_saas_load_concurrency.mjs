import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8');
const need = (errors, source, expression, message) => {
  if (!expression.test(source)) errors.push(message);
};
const forbid = (errors, source, expression, message) => {
  if (expression.test(source)) errors.push(message);
};

function verifyProbeBoundaries(errors, source) {
  need(errors, source,
    /function assertLocalSupabase\([\s\S]*?127\.0\.0\.1[\s\S]*?localhost[\s\S]*?url\.protocol !== 'http:'/,
    'probe F9.2 no falla cerrado fuera de HTTP loopback');
  forbid(errors, source, /https:\/\/[^'"`\s]*supabase\.co/i,
    'probe F9.2 contiene URL Supabase remota');
  need(errors, source, /STOMNI_LOAD_CONCURRENCY[\s\S]*?max: 64/,
    'probe F9.2 no limita concurrencia máxima');
  need(errors, source, /STOMNI_LOAD_CUSTOMERS_PER_TENANT[\s\S]*?max: 2000/,
    'probe F9.2 no limita fixtures de clientes');
  need(errors, source, /STOMNI_LOAD_INVENTORY_WRITES_PER_TENANT[\s\S]*?max: 1000/,
    'probe F9.2 no limita escrituras de inventario');

  const provisionStart = source.indexOf('async function provisionAuthUser');
  const provisionEnd = source.indexOf('async function signIn', provisionStart);
  const provisioning = provisionStart >= 0
    ? source.slice(provisionStart, provisionEnd > provisionStart ? provisionEnd : undefined)
    : '';
  need(errors, provisioning, /serviceRoleKey/,
    'service_role no está confinado al provisioning Auth');

  const tableStart = source.indexOf('async function table');
  const tableEnd = source.indexOf('async function createTenant', tableStart);
  const businessClient = tableStart >= 0
    ? source.slice(tableStart, tableEnd > tableStart ? tableEnd : undefined)
    : '';
  need(errors, businessClient, /apiKey: config\.anonKey[\s\S]*?token/,
    'Data API del probe no usa anon key + JWT authenticated');
  forbid(errors, businessClient, /serviceRoleKey/,
    'Data API del probe usa service_role y elude RLS');

  for (const scenario of [
    'sameTenantRetryRace',
    'crossTenantSameRequest',
    'inventoryBurst',
    'customerBurst',
    'readBurst',
    'verifyCustomerIsolation',
  ]) {
    need(errors, source, new RegExp(`function ${scenario}|async function ${scenario}`),
      `falta escenario F9.2 ${scenario}`);
  }

  need(errors, source,
    /sharedCreateRequest[\s\S]*?createProductWithSharedRequest\(config, a[\s\S]*?createProductWithSharedRequest\(config, b/,
    'probe no reutiliza el mismo request_id entre ORG_A y ORG_B al crear producto');
  need(errors, source,
    /Promise\.all\(\[[\s\S]*?registrar_ingreso_mercaderia_scaled_v2[\s\S]*?registrar_ingreso_mercaderia_scaled_v2/,
    'probe no ejerce contención simultánea real sobre inventario');
  need(errors, source, /same_tenant_retry_exactly_once: true/,
    'reporte no registra assertion exactly-once del retry');
  need(errors, source, /cross_tenant_same_request_allowed: true/,
    'reporte no registra namespace independiente A/B');
  need(errors, source, /concurrent_inventory_delta_exact: true/,
    'reporte no exige delta exacto después de carga concurrente');
  need(errors, source, /p50_ms[\s\S]*?p95_ms[\s\S]*?p99_ms/,
    'probe no calcula percentiles p50/p95/p99');
  need(errors, source, /dynamic_certification: 'T17_PENDING_REVIEW'/,
    'probe pretende certificar performance fuera de T17');
  need(errors, source, /\.dart_tool\/saas\/f9_2_load_report\.json/,
    'probe no deja artefacto de evidencia local por defecto');
}

function verify() {
  const errors = [];
  const migration = read('supabase/migrations/20260908059200_saas_inventory_request_scope_hardening.sql');
  const contract = read('supabase/tests/database/load_concurrency_contract_test.sql');
  const fiscalConcurrency = read('supabase/migrations/20260908024500_saas_fiscal_internal_rpc_scope.sql');
  const fiscalSales = read('supabase/migrations/20260908024000_saas_fiscal_rpc_guards.sql');
  const probe = read('supabase/tests/performance/multi_tenant_concurrency_probe.mjs');
  const map = read('docs/saas/99_MAPA_MAESTRO_PRUEBAS_SAAS.md');
  const audit = read('docs/saas/41_FASE9_2_CARGA_CONCURRENCIA.md');
  const checklist = read('docs/ROADMAP_SAAS_MULTI_TENANT_CHECKLIST.md');

  need(errors, migration,
    /CREATE OR REPLACE FUNCTION private\.assert_inventory_request_scope[\s\S]*?require_current_organization_id[\s\S]*?request_id is required/,
    'migración F9.2 no redefine request scope tenant-local');
  forbid(errors, migration,
    /assert_inventory_request_scope[\s\S]{0,1200}?organization_id IS DISTINCT FROM/,
    'guard F9.2 sigue consultando disponibilidad de UUID en otro tenant');
  for (const table of [
    'inventario_operaciones_idempotentes',
    'sys_processed_requests',
    'transferencias_stock',
  ]) {
    need(errors, migration, new RegExp(table),
      `migración F9.2 no cubre ${table}`);
  }
  need(errors, migration, /PRIMARY KEY \(organization_id,request_id\)|UNIQUE \(organization_id,request_id\)/,
    'migración F9.2 no crea claves tenant+request');
  need(errors, migration,
    /pg_index[\s\S]*?indisunique[\s\S]*?indnkeyatts=1[\s\S]*?pg_get_indexdef\(i\.indexrelid,1,true\)='request_id'/,
    'migración F9.2 no elimina UNIQUE INDEX request_id-only standalone');
  need(errors, migration,
    /CREATE OR REPLACE FUNCTION private\.inventory_tenant_request_key_v1[\s\S]*?md5\('stomni:inventory-trace-receipt:v1:'/,
    'recepción trazable no tiene namespace interno determinista por tenant');
  need(errors, migration,
    /register_traceable_merchandise_receipt_v1[\s\S]*?organization_id=v_organization_id[\s\S]*?inventory_tenant_request_key_v1/,
    'wrapper trazable no conserva retry legacy propio antes de namespacing');

  need(errors, contract, /SELECT plan\(19\)/,
    'pgTAP F9.2 no congela sus 19 assertions');
  need(errors, contract, /no conservan constraint ni índice UNIQUE request_id-only/,
    'pgTAP no detecta constraint/índice UNIQUE global por request_id');
  need(errors, contract, /índice tenant-leading/,
    'pgTAP no revisa índices tenant-leading');
  need(errors, contract, /FOR UPDATE/,
    'pgTAP no revisa bloqueo de consumo trazable');
  need(errors, contract, /purchase_orders[\s\S]*?purchase_receipts/,
    'pgTAP no conserva compras como referencia tenant-local de idempotencia');
  need(errors, contract,
    /correlativos_procesos_tributarios[\s\S]*?PRIMARY KEY \(organization_id, tipo_proceso, fecha_referencia\)/,
    'pgTAP no congela namespace de correlativos tributarios');
  need(errors, contract,
    /tributario_preparar_procesos[\s\S]*?pg_advisory_xact_lock[\s\S]*?FORUPDATESKIPLOCKED/,
    'pgTAP no cubre contención de preparación tributaria');
  need(errors, contract,
    /process_sale_v3[\s\S]*?series_comprobantes[\s\S]*?ultimo_correlativo/,
    'pgTAP no cubre correlativo de comprobantes por tenant');

  need(errors, fiscalConcurrency,
    /pg_advisory_xact_lock\(hashtextextended\(v_org::text\|\|':'\|\|v_grupo\.tipo_proceso\|\|':'\|\|v_grupo\.fecha_documento::text,0\)\)/,
    'motor tributario no bloquea correlativo por tenant/tipo/fecha');
  need(errors, fiscalConcurrency,
    /ON CONFLICT \(organization_id,tipo_proceso,fecha_referencia\)/,
    'motor tributario no incrementa correlativo en namespace tenant-local');
  need(errors, fiscalConcurrency, /FOR UPDATE SKIP LOCKED/,
    'motor tributario no reparte trabajo concurrente con SKIP LOCKED');
  need(errors, fiscalSales,
    /FROM public\.series_comprobantes AS sc[\s\S]*?organization_id = private\.require_current_organization_id\(\)[\s\S]*?FOR UPDATE/,
    'venta fiscal no bloquea la serie del tenant antes del correlativo');

  verifyProbeBoundaries(errors, probe);

  need(errors, map,
    /node scripts\/verify_saas_load_concurrency\.mjs --self-test[\s\S]*?node scripts\/verify_saas_load_concurrency\.mjs/,
    'T02 no ejecuta gate F9.2');
  need(errors, map,
    /load_concurrency_contract_test\.sql/,
    'mapa maestro no incorpora contrato pgTAP F9.2');
  need(errors, map,
    /# T17[\s\S]*?node supabase\/tests\/performance\/multi_tenant_concurrency_probe\.mjs/,
    'T17 no ejecuta probe dinámico F9.2');
  need(errors, map,
    /STOMNI_LOAD_CONCURRENCY/,
    'T17 no documenta configuración reproducible de carga');
  need(errors, map,
    /correlativo[\s\S]*?ORG_A[\s\S]*?ORG_B/i,
    'T17 no conserva escenario dinámico de correlativos independientes A/B');

  need(errors, audit, /VALIDACIÓN DINÁMICA LOCAL PENDIENTE/,
    'auditoría F9.2 no deja T17 pendiente explícitamente');
  need(errors, audit, /p50[\s\S]*?p95[\s\S]*?p99/i,
    'auditoría F9.2 no documenta percentiles de evidencia');
  need(errors, audit, /sin SLO comercial/i,
    'auditoría F9.2 inventa o deja ambiguo un SLO comercial');
  need(errors, audit, /correlativos_procesos_tributarios[\s\S]*?FOR UPDATE SKIP LOCKED/i,
    'auditoría F9.2 no explica la estrategia de correlativos concurrentes');

  need(errors, checklist, /\[x\] Fase 9\.2 — Carga y concurrencia/,
    'checklist no registra F9.2 implementada');
  need(errors, checklist, /\[ \] \*\*GATE BLOQUE 9 VERDE\*\*/,
    'Gate Bloque 9 se cerró antes de T17/T18/T19');
  return errors;
}

function selfTest() {
  const safe = `
    function assertLocalSupabase(rawUrl) {
      const url = new URL(rawUrl);
      const loopback = ['127.0.0.1','localhost'];
      if (url.protocol !== 'http:' || !loopback.includes(url.hostname)) throw Error();
    }
    STOMNI_LOAD_CONCURRENCY max: 64
    STOMNI_LOAD_CUSTOMERS_PER_TENANT max: 2000
    STOMNI_LOAD_INVENTORY_WRITES_PER_TENANT max: 1000
    async function provisionAuthUser(config) { return config.serviceRoleKey; }
    async function signIn() {}
    async function table(config, token) { return {apiKey: config.anonKey, token}; }
    async function createTenant() {}
    async function sameTenantRetryRace() { return registrar_ingreso_mercaderia_scaled_v2; }
    async function crossTenantSameRequest() { return registrar_ingreso_mercaderia_scaled_v2; }
    async function inventoryBurst() {}
    async function customerBurst() {}
    async function readBurst() {}
    async function verifyCustomerIsolation() {}
    const sharedCreateRequest = 1;
    createProductWithSharedRequest(config, a, sharedCreateRequest);
    createProductWithSharedRequest(config, b, sharedCreateRequest);
    Promise.all([registrar_ingreso_mercaderia_scaled_v2, registrar_ingreso_mercaderia_scaled_v2]);
    same_tenant_retry_exactly_once: true
    cross_tenant_same_request_allowed: true
    concurrent_inventory_delta_exact: true
    p50_ms p95_ms p99_ms
    dynamic_certification: 'T17_PENDING_REVIEW'
    .dart_tool/saas/f9_2_load_report.json
  `;
  const safeErrors = [];
  verifyProbeBoundaries(safeErrors, safe);
  if (safeErrors.length) {
    console.error('F9.2 gate self-test seguro falló:', safeErrors);
    process.exit(1);
  }

  const unsafe = safe
    .replace("url.protocol !== 'http:'", "url.protocol !== 'https:'")
    .replace('apiKey: config.anonKey, token', 'serviceRoleKey')
    .replace("dynamic_certification: 'T17_PENDING_REVIEW'", "dynamic_certification: 'GREEN'")
    .replace('p50_ms p95_ms p99_ms', 'mean_ms');
  const unsafeErrors = [];
  verifyProbeBoundaries(unsafeErrors, unsafe);
  if (unsafeErrors.length < 4) {
    console.error('F9.2 gate self-test negativo falló:', unsafeErrors);
    process.exit(1);
  }
  console.log('SaaS load/concurrency gate self-test OK (4 fronteras negativas).');
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify();
if (errors.length) {
  console.error('SaaS load/concurrency gate FAILED:');
  errors.forEach((error) => console.error(`  - ${error}`));
  process.exit(1);
}
console.log('SaaS load/concurrency gate OK (F9.2).');
console.log('  - idempotencia de inventario tenant-local congelada');
console.log('  - constraint/índice UNIQUE request-only global prohibido');
console.log('  - contención exactly-once y mismo UUID A/B cubiertos');
console.log('  - índices tenant-leading y correlativos concurrentes auditados');
console.log('  - probe restringido a Supabase local y JWT authenticated');
console.log('  - percentiles se registran como evidencia; certificación queda en T17');
