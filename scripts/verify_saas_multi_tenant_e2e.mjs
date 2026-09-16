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

function verifyRunnerBoundaries(errors, source) {
  need(
    errors,
    source,
    /function assertLocalSupabase\([\s\S]*?127\.0\.0\.1[\s\S]*?localhost[\s\S]*?url\.protocol !== 'http:'/,
    'runner E2E no falla cerrado fuera de Supabase local loopback',
  );
  forbid(
    errors,
    source,
    /https:\/\/[^'"`\s]*supabase\.co/i,
    'runner E2E contiene una URL Supabase remota',
  );
  const provisionStart = source.indexOf('async function provisionAuthUser');
  const provisionEnd = source.indexOf('async function signIn', provisionStart);
  const provisioner =
    provisionStart >= 0
      ? source.slice(provisionStart, provisionEnd > provisionStart ? provisionEnd : undefined)
      : '';
  need(
    errors,
    provisioner,
    /\/auth\/v1\/admin\/users/,
    'provisioning Auth no usa el endpoint admin local',
  );
  need(
    errors,
    provisioner,
    /serviceRoleKey/,
    'service_role no está confinado al provisioning Auth de fixtures',
  );
  const tableRequestStart = source.indexOf('async function tableRequest');
  const tableRequestEnd = source.indexOf('async function createTenant', tableRequestStart);
  const businessClient =
    tableRequestStart >= 0
      ? source.slice(tableRequestStart, tableRequestEnd > tableRequestStart ? tableRequestEnd : undefined)
      : '';
  need(
    errors,
    businessClient,
    /apiKey: config\.anonKey[\s\S]*?token: accessToken/,
    'operaciones de negocio E2E no usan anon key + token authenticated',
  );
  forbid(
    errors,
    businessClient,
    /serviceRoleKey/,
    'operaciones de negocio E2E usan service_role y no prueban RLS real',
  );

  need(
    errors,
    source,
    /'create_my_organization_v1'/,
    'runner no usa la puerta autoservicio de alta F8.1',
  );
  forbid(
    errors,
    source,
    /bootstrap_organization_v1/,
    'runner E2E accede al bootstrap técnico prohibido al cliente',
  );
  need(
    errors,
    source,
    /\['business_profile', 'modules', 'operations', 'review'\]/,
    'runner no recorre el onboarding completo y ordenado',
  );
  need(
    errors,
    source,
    /Promise\.all\(\[\s*createTenant\(config, 'ORG_A'[\s\S]*?createTenant\(config, 'ORG_B'/,
    'ORG_A y ORG_B no se crean en paralelo',
  );
  need(
    errors,
    source,
    /Promise\.all\(\[completeOnboarding\(config, a\), completeOnboarding\(config, b\)\]\)/,
    'onboarding A/B no se ejerce en paralelo',
  );

  for (const scenario of [
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
  ]) {
    need(errors, source, new RegExp(scenario), `falta escenario obligatorio ${scenario}`);
  }

  need(
    errors,
    source,
    /clientes\?select=\*[\s\S]{0,500}?method: 'POST'[\s\S]{0,500}?nombre:[\s\S]*?dni_ruc:/,
    'runner no crea datos de negocio representativos por Data API',
  );
  need(
    errors,
    source,
    /function customerDocument\([\s\S]*?createHash\('sha256'\)[\s\S]*?padStart\(6, '0'\)/,
    'runner no genera documentos numéricos y reproducibles para clientes',
  );
  need(
    errors,
    source,
    /tipo_doc: '1'/,
    'runner no usa el código SQL canónico para DNI',
  );
  forbid(
    errors,
    source,
    /dni_ruc:\s*`[^`]*runId\.slice/,
    'runner usa un sufijo hexadecimal como documento de cliente',
  );
  need(
    errors,
    source,
    /id=eq\.\$\{encodeURIComponent\(b\.customer\.id\)\}/,
    'runner no ataca una PK conocida de ORG_B desde ORG_A',
  );
  need(
    errors,
    source,
    /method: 'PATCH'[\s\S]*?CROSS UPDATE/,
    'runner no intenta UPDATE cross-tenant',
  );
  need(
    errors,
    source,
    /const crossDelete[\s\S]{0,500}?method: 'DELETE'/,
    'runner no intenta DELETE cross-tenant',
  );
  need(
    errors,
    source,
    /organization_id: b\.organizationId/,
    'runner no intenta suplantar organization_id de ORG_B',
  );
  need(
    errors,
    source,
    /organization_onboarding_progress\?select=organization_id,status&organization_id=eq\./,
    'runner no prueba aislamiento del progreso de onboarding',
  );
  need(
    errors,
    source,
    /subscription\?\.plan_code === 'starter'/,
    'runner no confirma Starter server-side para alta autoservicio',
  );
}

function verify() {
  const errors = [];
  const runner = read('supabase/tests/e2e/multi_tenant_e2e.mjs');
  const map = read('docs/saas/99_MAPA_MAESTRO_PRUEBAS_SAAS.md');
  const audit = read('docs/saas/40_FASE9_1_E2E_MULTIEMPRESA.md');
  const checklist = read('docs/ROADMAP_SAAS_MULTI_TENANT_CHECKLIST.md');

  verifyRunnerBoundaries(errors, runner);

  need(
    errors,
    map,
    /node scripts\/verify_saas_multi_tenant_e2e\.mjs --self-test[\s\S]*?node scripts\/verify_saas_multi_tenant_e2e\.mjs/,
    'T02 no incluye el gate estático de F9.1',
  );
  need(
    errors,
    map,
    /# T14[\s\S]*?node supabase\/tests\/e2e\/multi_tenant_e2e\.mjs/,
    'T14 no incluye la ejecución E2E multiempresa de F9.1',
  );
  need(
    errors,
    audit,
    /VALIDACIÓN DINÁMICA LOCAL PENDIENTE/,
    'auditoría F9.1 no deja explícita la certificación dinámica pendiente',
  );
  need(
    errors,
    audit,
    /service_role[\s\S]*?fixtures[\s\S]*?authenticated/i,
    'auditoría F9.1 no documenta la separación service_role/cliente normal',
  );
  need(
    errors,
    checklist,
    /\[x\] Fase 9\.1 — E2E multiempresa/,
    'checklist no registra F9.1 como suite implementada',
  );
  need(
    errors,
    checklist,
    /\[ \] \*\*GATE BLOQUE 9 VERDE\*\*/,
    'Gate Bloque 9 fue marcado antes de ejecutar pruebas dinámicas',
  );
  return errors;
}

function selfTest() {
  const safe = `
    function assertLocalSupabase(rawUrl) {
      const url = new URL(rawUrl);
      const hosts = ['127.0.0.1', 'localhost'];
      if (url.protocol !== 'http:' || !hosts.includes(url.hostname)) throw Error();
    }
    async function provisionAuthUser(config) {
      return serviceRoleKey && config.serviceRoleKey && '/auth/v1/admin/users';
    }
    async function tableRequest(config, accessToken) {
      return { apiKey: config.anonKey, token: accessToken };
    }
    async function createTenant() {}
    'create_my_organization_v1';
    ['business_profile', 'modules', 'operations', 'review'];
    Promise.all([createTenant(config, 'ORG_A'), createTenant(config, 'ORG_B')]);
    Promise.all([completeOnboarding(config, a), completeOnboarding(config, b)]);
    E2E-01-local-only E2E-02-auth-a-b-parallel E2E-03-self-service-signup-a-b
    E2E-04-onboarding-a-b-parallel E2E-05-customer-crud-a-b
    E2E-06-cross-tenant-read-blocked E2E-07-cross-tenant-update-blocked
    E2E-08-cross-tenant-delete-blocked E2E-09-organization-id-spoof-blocked
    E2E-10-onboarding-cross-tenant-filter-blocked
    clientes?select=* method: 'POST' nombre: x dni_ruc: y
    function customerDocument() { createHash('sha256'); padStart(6, '0'); }
    tipo_doc: '1'
    id=eq.\${encodeURIComponent(b.customer.id)}
    method: 'PATCH' CROSS UPDATE
    const crossDelete = { method: 'DELETE' }
    organization_id: b.organizationId
    organization_onboarding_progress?select=organization_id,status&organization_id=eq.
    subscription?.plan_code === 'starter'
  `;
  const safeErrors = [];
  verifyRunnerBoundaries(safeErrors, safe);
  if (safeErrors.length) {
    console.error('F9.1 gate self-test seguro falló:', safeErrors);
    process.exit(1);
  }

  const unsafeErrors = [];
  verifyRunnerBoundaries(
    unsafeErrors,
    safe
      .replace("url.protocol !== 'http:'", "url.protocol !== 'https:'")
      .replace("apiKey: config.anonKey, token: accessToken", 'serviceRoleKey')
      .replace('create_my_organization_v1', 'bootstrap_organization_v1')
      .replace('organization_id: b.organizationId', 'organization_id: a.organizationId'),
  );
  if (unsafeErrors.length < 4) {
    console.error('F9.1 gate self-test negativo falló:', unsafeErrors);
    process.exit(1);
  }
  console.log('SaaS multi-tenant E2E gate self-test OK (4 fronteras negativas).');
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify();
if (errors.length) {
  console.error('SaaS multi-tenant E2E gate FAILED:');
  errors.forEach((error) => console.error(`  - ${error}`));
  process.exit(1);
}
console.log('SaaS multi-tenant E2E gate OK (F9.1).');
console.log('  - ejecución bloqueada fuera de Supabase local');
console.log('  - ORG_A/ORG_B usan Auth + tokens authenticated reales');
console.log('  - alta/onboarding y CRUD representativo cubiertos');
console.log('  - ataques SELECT/UPDATE/DELETE/organization_id cross-tenant cubiertos');
