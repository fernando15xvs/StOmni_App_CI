import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { execFileSync } from 'node:child_process';
import { performance } from 'node:perf_hooks';

const DEFAULT_CUSTOMERS_PER_TENANT = 40;
const DEFAULT_INVENTORY_WRITES_PER_TENANT = 20;
const DEFAULT_READS_PER_TENANT = 40;
const DEFAULT_CONCURRENCY = 8;
const REPORT_PATH = process.env.STOMNI_LOAD_REPORT ?? '.dart_tool/saas/f9_2_load_report.json';

const fail = (message) => { throw new Error(message); };
const ensure = (condition, message) => { if (!condition) fail(message); };

function boundedInt(name, fallback, { min = 1, max }) {
  const raw = process.env[name];
  const value = raw == null ? fallback : Number.parseInt(raw, 10);
  ensure(Number.isInteger(value) && value >= min && value <= max,
    `${name} debe ser entero entre ${min} y ${max}.`);
  return value;
}

const limits = Object.freeze({
  customersPerTenant: boundedInt('STOMNI_LOAD_CUSTOMERS_PER_TENANT', DEFAULT_CUSTOMERS_PER_TENANT, { max: 2000 }),
  inventoryWritesPerTenant: boundedInt('STOMNI_LOAD_INVENTORY_WRITES_PER_TENANT', DEFAULT_INVENTORY_WRITES_PER_TENANT, { max: 1000 }),
  readsPerTenant: boundedInt('STOMNI_LOAD_READS_PER_TENANT', DEFAULT_READS_PER_TENANT, { max: 2000 }),
  concurrency: boundedInt('STOMNI_LOAD_CONCURRENCY', DEFAULT_CONCURRENCY, { max: 64 }),
});

function parseEnvOutput(raw) {
  const values = {};
  for (const line of raw.split(/\r?\n/)) {
    const match = line.trim().match(/^([A-Z0-9_]+)=(?:"([^"]*)"|'([^']*)'|(.*))$/);
    if (match) values[match[1]] = match[2] ?? match[3] ?? match[4] ?? '';
  }
  return values;
}

function assertLocalSupabase(rawUrl) {
  let url;
  try { url = new URL(rawUrl); } catch { fail('SUPABASE_URL/API_URL inválida.'); }
  const loopback = new Set(['127.0.0.1', 'localhost', '[::1]', '::1']);
  if (url.protocol !== 'http:' || !loopback.has(url.hostname)) {
    fail(`F9.2 sólo puede ejecutarse contra Supabase local HTTP loopback; recibido ${url.origin}`);
  }
  return url.origin;
}

function loadConfig() {
  const direct = {
    API_URL: process.env.SUPABASE_URL ?? process.env.API_URL,
    ANON_KEY: process.env.SUPABASE_ANON_KEY ?? process.env.ANON_KEY,
    SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY ?? process.env.SERVICE_ROLE_KEY,
  };
  let status = {};
  if (!direct.API_URL || !direct.ANON_KEY || !direct.SERVICE_ROLE_KEY) {
    try {
      status = parseEnvOutput(execFileSync('supabase', ['status', '-o', 'env'], {
        encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
      }));
    } catch (error) {
      fail(`No se pudo leer Supabase local. Ejecuta "supabase start" después de db reset. ${error.message}`);
    }
  }
  const apiUrl = assertLocalSupabase(direct.API_URL ?? status.API_URL ?? '');
  const anonKey = direct.ANON_KEY ?? status.ANON_KEY;
  const serviceRoleKey = direct.SERVICE_ROLE_KEY ?? status.SERVICE_ROLE_KEY;
  ensure(anonKey, 'Falta ANON_KEY local.');
  ensure(serviceRoleKey, 'Falta SERVICE_ROLE_KEY local.');
  return { apiUrl, anonKey, serviceRoleKey };
}

async function httpJson({ url, method = 'GET', apiKey, token, body, prefer }) {
  const headers = { apikey: apiKey, Authorization: `Bearer ${token ?? apiKey}` };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (prefer) headers.Prefer = prefer;
  const response = await fetch(url, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let data = null;
  if (text.trim()) {
    try { data = JSON.parse(text); } catch { data = text; }
  }
  return { ok: response.ok, status: response.status, data };
}

function describe(response) {
  return typeof response.data === 'string'
    ? response.data.slice(0, 500)
    : JSON.stringify(response.data)?.slice(0, 500);
}

async function requireOk(label, promise) {
  const response = await promise;
  if (!response.ok) fail(`${label}: HTTP ${response.status} ${describe(response) ?? ''}`);
  return response.data;
}

async function provisionAuthUser(config, email, password) {
  const data = await requireOk('crear fixture Auth', httpJson({
    url: `${config.apiUrl}/auth/v1/admin/users`, method: 'POST',
    apiKey: config.serviceRoleKey, token: config.serviceRoleKey,
    body: { email, password, email_confirm: true },
  }));
  ensure(data?.id, 'GoTrue no devolvió id del fixture.');
}

async function signIn(config, email, password) {
  const data = await requireOk('login fixture', httpJson({
    url: `${config.apiUrl}/auth/v1/token?grant_type=password`, method: 'POST',
    apiKey: config.anonKey, body: { email, password },
  }));
  ensure(data?.access_token, 'GoTrue no devolvió access_token.');
  return data.access_token;
}

async function rpc(config, token, name, body = {}) {
  return requireOk(`RPC ${name}`, httpJson({
    url: `${config.apiUrl}/rest/v1/rpc/${name}`, method: 'POST',
    apiKey: config.anonKey, token, body,
  }));
}

async function table(config, token, route, { method = 'GET', body, prefer } = {}) {
  return httpJson({
    url: `${config.apiUrl}/rest/v1/${route}`, method,
    apiKey: config.anonKey, token, body, prefer,
  });
}

async function createTenant(config, label, runId) {
  const email = `stomni.load.${label.toLowerCase()}.${runId}@example.test`;
  const password = `Load-${crypto.randomUUID()}-Aa1!`;
  await provisionAuthUser(config, email, password);
  const token = await signIn(config, email, password);
  const signup = await rpc(config, token, 'create_my_organization_v1', {
    p_display_name: `StOmni Load ${label} ${runId}`,
    p_country_code: 'PE', p_currency_code: 'PEN', p_timezone: 'America/Lima',
    p_legal_name: `StOmni Load ${label} Legal ${runId}`,
  });
  ensure(signup?.organization_id, `${label}: alta sin organization_id.`);
  ensure(signup?.subscription?.plan_code === 'starter', `${label}: alta no quedó Starter.`);

  let progress = await rpc(config, token, 'get_my_onboarding_progress_v1');
  for (const step of ['business_profile', 'modules', 'operations', 'review']) {
    ensure(progress?.next_step === step, `${label}: onboarding esperaba ${step}.`);
    progress = await rpc(config, token, 'complete_my_onboarding_step_v1', {
      p_expected_revision: progress.revision, p_step: step,
    });
  }
  ensure(progress?.status === 'completed', `${label}: onboarding incompleto.`);
  return { label, token, organizationId: signup.organization_id };
}

async function createWarehouse(config, tenant, runId) {
  const response = await table(config, tenant.token, 'almacenes?select=id,organization_id,nombre,activo', {
    method: 'POST', prefer: 'return=representation',
    body: {
      nombre: `Load Warehouse ${tenant.label} ${runId}`,
      direccion: 'Fixture local F9.2', ubigeo: '150101',
      departamento: 'LIMA', provincia: 'LIMA', distrito: 'LIMA',
      cod_local: '0000', referencia: 'F9.2', activo: true,
    },
  });
  ensure(response.ok, `${tenant.label}: almacén HTTP ${response.status} ${describe(response)}`);
  ensure(Array.isArray(response.data) && response.data.length === 1, `${tenant.label}: almacén sin fila.`);
  ensure(response.data[0].organization_id === tenant.organizationId, `${tenant.label}: almacén con tenant incorrecto.`);
  tenant.warehouseId = response.data[0].id;
}

async function createProductWithSharedRequest(config, tenant, runId, sharedRequestId) {
  const suffix = runId.replace(/[^0-9A-Za-z]/g, '').slice(-12).toUpperCase();
  const params = {
    p_request_id: sharedRequestId,
    p_datos_producto: {
      codigo: `LOAD${tenant.label.slice(-1)}${suffix}`,
      nombre: `Producto Load ${tenant.label} ${runId}`,
      tipo_venta: 'CAJA_UNIDADES', cantidad_por_caja: 1,
      precio_unidad: 1, precio_caja: 1, precio_compra: 0.5,
      permitir_sin_stock: false, stock_minimo: 0,
    },
    p_stocks: [{ almacen_id: tenant.warehouseId, delta: 100, motivo: 'F9.2 seed' }],
  };
  const first = await rpc(config, tenant.token, 'crear_producto_con_stock', params);
  const retry = await rpc(config, tenant.token, 'crear_producto_con_stock', params);
  ensure(first?.producto_id && retry?.producto_id === first.producto_id,
    `${tenant.label}: retry crear_producto_con_stock no fue idempotente.`);
  tenant.productId = first.producto_id;
}

async function getStock(config, tenant) {
  const response = await table(
    config, tenant.token,
    `inventario_almacen?select=cantidad&producto_id=eq.${tenant.productId}&almacen_id=eq.${tenant.warehouseId}`,
  );
  ensure(response.ok, `${tenant.label}: stock HTTP ${response.status} ${describe(response)}`);
  ensure(Array.isArray(response.data) && response.data.length === 1, `${tenant.label}: stock no localizado.`);
  const value = Number(response.data[0].cantidad);
  ensure(Number.isFinite(value), `${tenant.label}: stock no numérico.`);
  return value;
}

function inventoryReceiptParams(tenant, requestId, marker) {
  return {
    p_request_id: requestId,
    p_producto_id: tenant.productId,
    p_fecha: new Date().toISOString(),
    p_tipo_ingreso: 'F9.2 carga', p_documento: marker,
    p_proveedor_id: null, p_observaciones: 'probe local concurrencia',
    p_almacenes: [{ almacen_id: tenant.warehouseId, cantidad_base: 1 }],
    p_ingreso_costo: 0.5, p_ingreso_p_unit: 1,
    p_ingreso_p_caja: 1, p_ingreso_p_c_comp: 1,
  };
}

async function runPool(items, concurrency, worker) {
  const results = new Array(items.length);
  let cursor = 0;
  async function consume() {
    while (true) {
      const index = cursor++;
      if (index >= items.length) return;
      results[index] = await worker(items[index], index);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, items.length) }, consume));
  return results;
}

async function timed(fn) {
  const start = performance.now();
  const value = await fn();
  return { value, ms: performance.now() - start };
}

function percentile(values, q) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil(q * sorted.length) - 1));
  return sorted[index];
}

function stats(values) {
  const sum = values.reduce((acc, value) => acc + value, 0);
  return {
    count: values.length,
    min_ms: Math.min(...values),
    mean_ms: sum / values.length,
    p50_ms: percentile(values, 0.50),
    p95_ms: percentile(values, 0.95),
    p99_ms: percentile(values, 0.99),
    max_ms: Math.max(...values),
  };
}

function loadCustomerDocument(tenant, index) {
  const tenantPrefix = tenant.label === 'ORG_A' ? '10' : '20';
  return `${tenantPrefix}${String(index).padStart(6, '0')}`;
}

async function customerBurst(config, tenant, runId) {
  const indices = Array.from({ length: limits.customersPerTenant }, (_, i) => i);
  return runPool(indices, limits.concurrency, async (i) => {
    const document = loadCustomerDocument(tenant, i);
    return timed(async () => {
      const response = await table(config, tenant.token, 'clientes?select=id,organization_id,dni_ruc', {
        method: 'POST', prefer: 'return=representation',
        body: {
          nombre: `Load ${tenant.label} ${i}`, dni_ruc: document,
          direccion: 'F9.2 local', tipo_doc: '1', telefono: '900000000',
        },
      });
      ensure(response.ok, `${tenant.label}: INSERT cliente ${i} HTTP ${response.status} ${describe(response)}`);
      ensure(response.data?.[0]?.organization_id === tenant.organizationId,
        `${tenant.label}: INSERT cliente ${i} cruzó tenant.`);
      return response.data[0].id;
    });
  });
}

async function readBurst(config, tenant) {
  const indices = Array.from({ length: limits.readsPerTenant }, (_, i) => i);
  return runPool(indices, limits.concurrency, async (i) => timed(async () => {
    const response = await table(
      config, tenant.token,
      `clientes?select=id,organization_id&order=id.desc&limit=50&offset=${(i % 4) * 5}`,
    );
    ensure(response.ok, `${tenant.label}: SELECT carga HTTP ${response.status} ${describe(response)}`);
    ensure(Array.isArray(response.data) && response.data.every((row) => row.organization_id === tenant.organizationId),
      `${tenant.label}: SELECT carga expuso otro tenant.`);
    return response.data.length;
  }));
}

async function sameTenantRetryRace(config, tenant) {
  const before = await getStock(config, tenant);
  const requestId = crypto.randomUUID();
  const params = inventoryReceiptParams(tenant, requestId, 'same-tenant-retry');
  const pair = await Promise.all([
    timed(() => rpc(config, tenant.token, 'registrar_ingreso_mercaderia_scaled_v2', params)),
    timed(() => rpc(config, tenant.token, 'registrar_ingreso_mercaderia_scaled_v2', params)),
  ]);
  const after = await getStock(config, tenant);
  ensure(Math.abs((after - before) - 1) < 0.000001,
    `${tenant.label}: retry concurrente cambió stock ${after - before}; esperaba 1.`);
  ensure(JSON.stringify(pair[0].value) === JSON.stringify(pair[1].value),
    `${tenant.label}: retry concurrente devolvió resultados diferentes.`);
  return pair.map((item) => item.ms);
}

async function crossTenantSameRequest(config, a, b) {
  const beforeA = await getStock(config, a);
  const beforeB = await getStock(config, b);
  const shared = crypto.randomUUID();
  const [ra, rb] = await Promise.all([
    timed(() => rpc(config, a.token, 'registrar_ingreso_mercaderia_scaled_v2',
      inventoryReceiptParams(a, shared, 'shared-a-b'))),
    timed(() => rpc(config, b.token, 'registrar_ingreso_mercaderia_scaled_v2',
      inventoryReceiptParams(b, shared, 'shared-a-b'))),
  ]);
  const [afterA, afterB] = await Promise.all([getStock(config, a), getStock(config, b)]);
  ensure(Math.abs((afterA - beforeA) - 1) < 0.000001, 'ORG_A no aceptó su request compartido exactamente una vez.');
  ensure(Math.abs((afterB - beforeB) - 1) < 0.000001, 'ORG_B no aceptó el mismo UUID en su namespace.');
  return [ra.ms, rb.ms];
}

async function inventoryBurst(config, tenant) {
  const before = await getStock(config, tenant);
  const items = Array.from({ length: limits.inventoryWritesPerTenant }, (_, i) => ({
    i, requestId: crypto.randomUUID(),
  }));
  const results = await runPool(items, limits.concurrency, ({ i, requestId }) => timed(() =>
    rpc(config, tenant.token, 'registrar_ingreso_mercaderia_scaled_v2',
      inventoryReceiptParams(tenant, requestId, `burst-${i}`))));
  const after = await getStock(config, tenant);
  ensure(Math.abs((after - before) - limits.inventoryWritesPerTenant) < 0.000001,
    `${tenant.label}: burst inventario dejó delta ${after - before}; esperaba ${limits.inventoryWritesPerTenant}.`);
  return results;
}

async function verifyCustomerIsolation(config, a, b) {
  const [rowsA, rowsB] = await Promise.all([
    requireOk('clientes A', table(config, a.token, 'clientes?select=id,organization_id&limit=1000')),
    requireOk('clientes B', table(config, b.token, 'clientes?select=id,organization_id&limit=1000')),
  ]);
  ensure(rowsA.every((row) => row.organization_id === a.organizationId), 'ORG_A contiene clientes de otro tenant.');
  ensure(rowsB.every((row) => row.organization_id === b.organizationId), 'ORG_B contiene clientes de otro tenant.');
  ensure(rowsA.length >= limits.customersPerTenant && rowsB.length >= limits.customersPerTenant,
    'Conteo de clientes menor al burst esperado.');
}

async function main() {
  const config = loadConfig();
  const runId = `${Date.now()}-${crypto.randomBytes(3).toString('hex')}`;
  console.log(`F9.2 local load probe: ${config.apiUrl}`);
  console.log(`Carga: customers=${limits.customersPerTenant}/tenant inventory=${limits.inventoryWritesPerTenant}/tenant reads=${limits.readsPerTenant}/tenant concurrency=${limits.concurrency}`);

  const setupStart = performance.now();
  const [a, b] = await Promise.all([
    createTenant(config, 'ORG_A', runId), createTenant(config, 'ORG_B', runId),
  ]);
  await Promise.all([createWarehouse(config, a, runId), createWarehouse(config, b, runId)]);

  const sharedCreateRequest = crypto.randomUUID();
  await Promise.all([
    createProductWithSharedRequest(config, a, runId, sharedCreateRequest),
    createProductWithSharedRequest(config, b, runId, sharedCreateRequest),
  ]);
  ensure(a.productId !== b.productId, 'ORG_A/ORG_B recibieron el mismo product_id inesperadamente.');
  const setupMs = performance.now() - setupStart;

  const [customersA, customersB] = await Promise.all([
    customerBurst(config, a, runId), customerBurst(config, b, runId),
  ]);
  await verifyCustomerIsolation(config, a, b);

  const [readsA, readsB] = await Promise.all([readBurst(config, a), readBurst(config, b)]);
  const [retryA, retryB] = await Promise.all([
    sameTenantRetryRace(config, a), sameTenantRetryRace(config, b),
  ]);
  const crossTenantRequest = await crossTenantSameRequest(config, a, b);
  const [inventoryA, inventoryB] = await Promise.all([
    inventoryBurst(config, a), inventoryBurst(config, b),
  ]);

  const report = {
    phase: 'F9.2',
    dynamic_certification: 'T17_PENDING_REVIEW',
    generated_at: new Date().toISOString(),
    run_id: runId,
    local_origin: config.apiUrl,
    limits,
    setup_ms: setupMs,
    organizations: { A: a.organizationId, B: b.organizationId },
    metrics: {
      customer_write: stats([...customersA, ...customersB].map((x) => x.ms)),
      customer_read: stats([...readsA, ...readsB].map((x) => x.ms)),
      same_tenant_retry_race: stats([...retryA, ...retryB]),
      cross_tenant_same_request: stats(crossTenantRequest),
      inventory_write: stats([...inventoryA, ...inventoryB].map((x) => x.ms)),
    },
    assertions: {
      customer_isolation: true,
      same_tenant_retry_exactly_once: true,
      cross_tenant_same_request_allowed: true,
      concurrent_inventory_delta_exact: true,
    },
    note: 'Este archivo registra evidencia; F9.2 no define SLO comercial ni umbral de GO hasta revisar T17 sobre hardware declarado.',
  };

  fs.mkdirSync(path.dirname(REPORT_PATH), { recursive: true });
  fs.writeFileSync(REPORT_PATH, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  console.log(JSON.stringify(report.metrics, null, 2));
  console.log(`F9.2 probe OK. Evidencia: ${REPORT_PATH}`);
}

main().catch((error) => {
  console.error(`F9.2 load/concurrency probe FAILED: ${error.message}`);
  process.exit(1);
});
