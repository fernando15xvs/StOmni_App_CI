import crypto from 'node:crypto';
import process from 'node:process';
import { execFileSync } from 'node:child_process';

const SCENARIOS = Object.freeze([
  'E2E-01-local-only',
  'E2E-02-auth-a-b-parallel',
  'E2E-03-self-service-signup-a-b',
  'E2E-04-onboarding-a-b-parallel',
  'E2E-05-customer-crud-a-b',
  'E2E-06-cross-tenant-read-blocked',
  'E2E-07-cross-tenant-update-blocked',
  'E2E-08-cross-tenant-delete-blocked',
  'E2E-09-organization-id-spoof-blocked',
  'E2E-10-onboarding-cross-tenant-filter-blocked',
]);

const JWT_CLOCK_SKEW_MAX_RETRIES = 5;
const JWT_CLOCK_SKEW_RETRY_DELAY_MS = 1000;

const step = (id, message) => console.log(`[${id}] ${message}`);
const fail = (message) => {
  throw new Error(message);
};
const ensure = (condition, message) => {
  if (!condition) fail(message);
};
const delay = (milliseconds) =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));

function customerDocument(runId, prefix) {
  const digest = crypto.createHash('sha256').update(runId).digest();
  const suffix = (digest.readUInt32BE(0) % 1_000_000)
    .toString()
    .padStart(6, '0');
  return `${prefix}${suffix}`;
}

function isJwtIssuedInFuture(response) {
  return (
    response.status === 401 &&
    response.data?.code === 'PGRST303' &&
    response.data?.message === 'JWT issued at future'
  );
}

function parseEnvOutput(raw) {
  const values = {};
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const match = trimmed.match(/^([A-Z0-9_]+)=(?:"([^"]*)"|'([^']*)'|(.*))$/);
    if (!match) continue;
    values[match[1]] = match[2] ?? match[3] ?? match[4] ?? '';
  }
  return values;
}

function assertLocalSupabase(rawUrl) {
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    fail('SUPABASE_URL/API_URL no es una URL válida.');
  }
  const loopback = new Set(['127.0.0.1', 'localhost', '[::1]', '::1']);
  if (url.protocol !== 'http:' || !loopback.has(url.hostname)) {
    fail(
      `F9.1 sólo puede ejecutarse contra Supabase local por HTTP loopback; recibido ${url.origin}`,
    );
  }
  return url.origin;
}

function loadConfig() {
  const direct = {
    API_URL: process.env.SUPABASE_URL ?? process.env.API_URL,
    ANON_KEY: process.env.SUPABASE_ANON_KEY ?? process.env.ANON_KEY,
    SERVICE_ROLE_KEY:
      process.env.SUPABASE_SERVICE_ROLE_KEY ?? process.env.SERVICE_ROLE_KEY,
  };

  let status = {};
  if (!direct.API_URL || !direct.ANON_KEY || !direct.SERVICE_ROLE_KEY) {
    try {
      status = parseEnvOutput(
        execFileSync('supabase', ['status', '-o', 'env'], {
          encoding: 'utf8',
          stdio: ['ignore', 'pipe', 'pipe'],
        }),
      );
    } catch (error) {
      fail(
        `No se pudo leer Supabase local. Ejecuta "supabase start" antes de F9.1. ${error.message}`,
      );
    }
  }

  const apiUrl = assertLocalSupabase(direct.API_URL ?? status.API_URL ?? '');
  const anonKey = direct.ANON_KEY ?? status.ANON_KEY;
  const serviceRoleKey = direct.SERVICE_ROLE_KEY ?? status.SERVICE_ROLE_KEY;
  ensure(anonKey, 'Falta ANON_KEY de Supabase local.');
  ensure(serviceRoleKey, 'Falta SERVICE_ROLE_KEY de Supabase local.');
  return { apiUrl, anonKey, serviceRoleKey };
}

async function httpJson({
  url,
  method = 'GET',
  apiKey,
  token,
  body,
  prefer,
}) {
  const headers = {
    apikey: apiKey,
    Authorization: `Bearer ${token ?? apiKey}`,
  };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  if (prefer) headers.Prefer = prefer;

  const serializedBody = body === undefined ? undefined : JSON.stringify(body);
  for (let attempt = 0; ; attempt += 1) {
    const response = await fetch(url, {
      method,
      headers,
      body: serializedBody,
    });
    const text = await response.text();
    let data = null;
    if (text.trim()) {
      try {
        data = JSON.parse(text);
      } catch {
        data = text;
      }
    }

    const result = { ok: response.ok, status: response.status, data };
    if (
      !isJwtIssuedInFuture(result) ||
      attempt >= JWT_CLOCK_SKEW_MAX_RETRIES
    ) {
      return result;
    }

    // PostgREST rejects the JWT before executing the request, so retrying only
    // this exact transient validation error cannot duplicate a mutation.
    console.warn(
      `[JWT-CLOCK-SKEW] token aún no aceptado; reintento ${attempt + 1}/${JWT_CLOCK_SKEW_MAX_RETRIES}.`,
    );
    await delay(JWT_CLOCK_SKEW_RETRY_DELAY_MS);
  }
}

function responseError(label, response) {
  const detail =
    typeof response.data === 'string'
      ? response.data.slice(0, 400)
      : JSON.stringify(response.data)?.slice(0, 400);
  return `${label} falló HTTP ${response.status}: ${detail ?? '<sin cuerpo>'}`;
}

async function requireOk(label, request) {
  const response = await request;
  if (!response.ok) fail(responseError(label, response));
  return response.data;
}

async function provisionAuthUser(config, { email, password }) {
  const data = await requireOk(
    'crear fixture Auth',
    httpJson({
      url: `${config.apiUrl}/auth/v1/admin/users`,
      method: 'POST',
      apiKey: config.serviceRoleKey,
      token: config.serviceRoleKey,
      body: { email, password, email_confirm: true },
    }),
  );
  ensure(data?.id, 'GoTrue no devolvió id para el usuario fixture.');
  return data.id;
}

async function signIn(config, { email, password }) {
  const data = await requireOk(
    'login fixture',
    httpJson({
      url: `${config.apiUrl}/auth/v1/token?grant_type=password`,
      method: 'POST',
      apiKey: config.anonKey,
      body: { email, password },
    }),
  );
  ensure(data?.access_token, 'GoTrue no devolvió access_token.');
  return { accessToken: data.access_token, userId: data.user?.id };
}

async function rpc(config, accessToken, name, body = {}) {
  return requireOk(
    `RPC ${name}`,
    httpJson({
      url: `${config.apiUrl}/rest/v1/rpc/${name}`,
      method: 'POST',
      apiKey: config.anonKey,
      token: accessToken,
      body,
    }),
  );
}

async function tableRequest(
  config,
  accessToken,
  path,
  { method = 'GET', body, prefer } = {},
) {
  return httpJson({
    url: `${config.apiUrl}/rest/v1/${path}`,
    method,
    apiKey: config.anonKey,
    token: accessToken,
    body,
    prefer,
  });
}

async function createTenant(config, label, runId) {
  const normalized = label.toLowerCase();
  const email = `stomni.e2e.${normalized}.${runId}@example.test`;
  const password = `E2e-${crypto.randomUUID()}-Aa1!`;
  await provisionAuthUser(config, { email, password });
  const auth = await signIn(config, { email, password });

  const signupState = await rpc(
    config,
    auth.accessToken,
    'get_organization_signup_state_v1',
  );
  ensure(
    signupState?.state === 'eligible' && signupState?.eligible === true,
    `${label}: identidad nueva no quedó eligible para alta.`,
  );

  const signup = await rpc(
    config,
    auth.accessToken,
    'create_my_organization_v1',
    {
      p_display_name: `StOmni E2E ${label} ${runId}`,
      p_country_code: 'PE',
      p_currency_code: 'PEN',
      p_timezone: 'America/Lima',
      p_legal_name: `StOmni E2E ${label} Legal ${runId}`,
    },
  );
  ensure(signup?.organization_id, `${label}: alta no devolvió organization_id.`);
  ensure(
    signup?.subscription?.plan_code === 'starter',
    `${label}: alta autoservicio no asignó Starter server-side.`,
  );

  const progress = await rpc(
    config,
    auth.accessToken,
    'get_my_onboarding_progress_v1',
  );
  ensure(
    progress?.status === 'in_progress' && progress?.next_step === 'business_profile',
    `${label}: tenant nuevo no inició onboarding en business_profile.`,
  );

  return {
    label,
    accessToken: auth.accessToken,
    userId: auth.userId,
    organizationId: signup.organization_id,
    progress,
  };
}

async function completeOnboarding(config, tenant) {
  let progress = tenant.progress;
  for (const expectedStep of ['business_profile', 'modules', 'operations', 'review']) {
    ensure(
      progress?.next_step === expectedStep,
      `${tenant.label}: esperaba onboarding ${expectedStep}, recibió ${progress?.next_step}.`,
    );
    progress = await rpc(
      config,
      tenant.accessToken,
      'complete_my_onboarding_step_v1',
      {
        p_expected_revision: progress.revision,
        p_step: expectedStep,
      },
    );
  }
  ensure(
    progress?.status === 'completed' && progress?.next_step == null,
    `${tenant.label}: onboarding no terminó en completed.`,
  );
  tenant.progress = progress;
}

async function insertCustomer(config, tenant, runId) {
  const document = customerDocument(
    runId,
    tenant.label === 'ORG_A' ? '10' : '20',
  );
  const response = await tableRequest(config, tenant.accessToken, 'clientes?select=*', {
    method: 'POST',
    prefer: 'return=representation',
    body: {
      nombre: `Cliente ${tenant.label} ${runId}`,
      dni_ruc: document,
      direccion: `E2E ${tenant.label}`,
      tipo_doc: '1',
      telefono: '900000000',
    },
  });
  if (!response.ok) fail(responseError(`${tenant.label}: crear cliente`, response));
  ensure(
    Array.isArray(response.data) && response.data.length === 1,
    `${tenant.label}: INSERT cliente no devolvió exactamente una fila.`,
  );
  const customer = response.data[0];
  ensure(customer?.id, `${tenant.label}: cliente sin id.`);
  ensure(
    customer?.organization_id === tenant.organizationId,
    `${tenant.label}: backend no derivó organization_id correcto en cliente.`,
  );
  tenant.customer = customer;
}

async function listCustomers(config, tenant, query = '') {
  const suffix = query ? `&${query}` : '';
  const response = await tableRequest(
    config,
    tenant.accessToken,
    `clientes?select=id,organization_id,nombre,dni_ruc&order=id.asc${suffix}`,
  );
  if (!response.ok) fail(responseError(`${tenant.label}: listar clientes`, response));
  ensure(Array.isArray(response.data), `${tenant.label}: SELECT clientes no devolvió array.`);
  return response.data;
}

function assertOwnRowsOnly(rows, tenant, forbiddenId) {
  ensure(
    rows.every((row) => row.organization_id === tenant.organizationId),
    `${tenant.label}: SELECT devolvió una fila de otro tenant.`,
  );
  ensure(
    !rows.some((row) => row.id === forbiddenId),
    `${tenant.label}: SELECT expuso PK conocida de otro tenant.`,
  );
}

async function verifyCrossTenantAttacks(config, a, b, runId) {
  const [rowsA, rowsB] = await Promise.all([
    listCustomers(config, a),
    listCustomers(config, b),
  ]);
  assertOwnRowsOnly(rowsA, a, b.customer.id);
  assertOwnRowsOnly(rowsB, b, a.customer.id);

  const crossRead = await listCustomers(
    config,
    a,
    `id=eq.${encodeURIComponent(b.customer.id)}`,
  );
  ensure(crossRead.length === 0, 'ORG_A pudo leer cliente ORG_B por PK conocida.');

  const originalBName = b.customer.nombre;
  const crossUpdate = await tableRequest(
    config,
    a.accessToken,
    `clientes?id=eq.${encodeURIComponent(b.customer.id)}&select=id,nombre,organization_id`,
    {
      method: 'PATCH',
      prefer: 'return=representation',
      body: { nombre: `CROSS UPDATE ${runId}` },
    },
  );
  ensure(crossUpdate.ok, responseError('UPDATE cross-tenant A->B', crossUpdate));
  ensure(
    Array.isArray(crossUpdate.data) && crossUpdate.data.length === 0,
    'ORG_A pudo actualizar cliente ORG_B.',
  );
  const afterUpdate = await listCustomers(
    config,
    b,
    `id=eq.${encodeURIComponent(b.customer.id)}`,
  );
  ensure(
    afterUpdate.length === 1 && afterUpdate[0].nombre === originalBName,
    'Cliente ORG_B cambió tras UPDATE cross-tenant.',
  );

  const crossDelete = await tableRequest(
    config,
    a.accessToken,
    `clientes?id=eq.${encodeURIComponent(b.customer.id)}&select=id`,
    { method: 'DELETE', prefer: 'return=representation' },
  );
  ensure(crossDelete.ok, responseError('DELETE cross-tenant A->B', crossDelete));
  ensure(
    Array.isArray(crossDelete.data) && crossDelete.data.length === 0,
    'ORG_A pudo eliminar cliente ORG_B.',
  );
  const afterDelete = await listCustomers(
    config,
    b,
    `id=eq.${encodeURIComponent(b.customer.id)}`,
  );
  ensure(afterDelete.length === 1, 'Cliente ORG_B desapareció tras DELETE cross-tenant.');

  const spoof = await tableRequest(config, a.accessToken, 'clientes?select=id', {
    method: 'POST',
    prefer: 'return=representation',
    body: {
      organization_id: b.organizationId,
      nombre: `Spoof ${runId}`,
      dni_ruc: customerDocument(runId, '90'),
      direccion: 'E2E spoof',
      tipo_doc: '1',
    },
  });
  ensure(!spoof.ok, 'ORG_A pudo insertar cliente declarando organization_id de ORG_B.');

  const onboardingCross = await tableRequest(
    config,
    a.accessToken,
    `organization_onboarding_progress?select=organization_id,status&organization_id=eq.${encodeURIComponent(b.organizationId)}`,
  );
  ensure(
    onboardingCross.ok && Array.isArray(onboardingCross.data) && onboardingCross.data.length === 0,
    'ORG_A pudo observar onboarding de ORG_B.',
  );
}

async function verifyOwnCrud(config, tenant, runId) {
  const renamed = `Cliente ${tenant.label} actualizado ${runId}`;
  const update = await tableRequest(
    config,
    tenant.accessToken,
    `clientes?id=eq.${encodeURIComponent(tenant.customer.id)}&select=id,nombre,organization_id`,
    {
      method: 'PATCH',
      prefer: 'return=representation',
      body: { nombre: renamed },
    },
  );
  if (!update.ok) fail(responseError(`${tenant.label}: UPDATE propio`, update));
  ensure(
    Array.isArray(update.data) && update.data.length === 1 && update.data[0].nombre === renamed,
    `${tenant.label}: UPDATE propio no persistió.`,
  );
  tenant.customer.nombre = renamed;
}

async function main() {
  const config = loadConfig();
  const runId = `${Date.now()}-${crypto.randomBytes(3).toString('hex')}`;
  step('E2E-01-local-only', `Supabase local confirmado en ${config.apiUrl}`);

  const [a, b] = await Promise.all([
    createTenant(config, 'ORG_A', runId),
    createTenant(config, 'ORG_B', runId),
  ]);
  step('E2E-02-auth-a-b-parallel', 'dos identidades Auth normales creadas y autenticadas');
  ensure(a.organizationId !== b.organizationId, 'ORG_A y ORG_B recibieron el mismo tenant UUID.');
  step('E2E-03-self-service-signup-a-b', 'dos tenants distintos creados por create_my_organization_v1');

  await Promise.all([completeOnboarding(config, a), completeOnboarding(config, b)]);
  step('E2E-04-onboarding-a-b-parallel', 'onboarding secuencial completado de forma independiente');

  await Promise.all([
    insertCustomer(config, a, runId),
    insertCustomer(config, b, runId),
  ]);
  await Promise.all([verifyOwnCrud(config, a, runId), verifyOwnCrud(config, b, runId)]);
  step('E2E-05-customer-crud-a-b', 'CRUD representativo ejecutado con tokens authenticated');

  await verifyCrossTenantAttacks(config, a, b, runId);
  step('E2E-06-cross-tenant-read-blocked', 'lectura por PK de otro tenant devuelve cero filas');
  step('E2E-07-cross-tenant-update-blocked', 'UPDATE cross-tenant no muta ORG_B');
  step('E2E-08-cross-tenant-delete-blocked', 'DELETE cross-tenant no elimina ORG_B');
  step('E2E-09-organization-id-spoof-blocked', 'organization_id falsificado fue rechazado');
  step('E2E-10-onboarding-cross-tenant-filter-blocked', 'progreso de onboarding de ORG_B no es visible desde ORG_A');

  console.log(`F9.1 E2E multiempresa OK (${SCENARIOS.length} escenarios).`);
  console.log('Los fixtures se conservan para evidencia; T14/T18 ejecutan sobre db reset limpio.');
}

main().catch((error) => {
  console.error(`F9.1 E2E multiempresa FAILED: ${error.message}`);
  process.exit(1);
});
