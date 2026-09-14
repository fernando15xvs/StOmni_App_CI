import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrationName = '20260907025411_saas_foundation_rls.sql';

function requireMatch(errors, source, regex, description) {
  if (!regex.test(source)) errors.push(`Falta: ${description}`);
}

function policyBlock(source, name) {
  const match = source.match(new RegExp(`CREATE POLICY\\s+${name}([\\s\\S]*?);`, 'i'));
  return match?.[0] ?? '';
}

function verifyRls(source) {
  const errors = [];
  const executable = source.replace(/--.*$/gm, '');
  const tables = ['organizations', 'app_users', 'empleados', 'configuracion_negocio', 'business_capabilities'];

  for (const table of tables) {
    requireMatch(errors, source, new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ENABLE ROW LEVEL SECURITY`, 'i'), `${table}: RLS habilitado`);
    requireMatch(errors, source, new RegExp(`REVOKE ALL ON TABLE\\s+public\\.${table}\\s+FROM\\s+PUBLIC,\\s*anon,\\s*authenticated`, 'i'), `${table}: grants cerrados antes de reabrir mínimo`);
  }

  requireMatch(errors, source, /GRANT SELECT ON TABLE\s+public\.organizations\s+TO\s+authenticated/i, 'organizations solo SELECT cliente');
  requireMatch(errors, source, /GRANT SELECT ON TABLE\s+public\.app_users\s+TO\s+authenticated/i, 'app_users solo SELECT cliente');
  requireMatch(errors, source, /GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE\s+public\.empleados\s+TO\s+authenticated/i, 'empleados CRUD protegido por RLS');
  requireMatch(errors, source, /GRANT SELECT, UPDATE ON TABLE\s+public\.configuracion_negocio\s+TO\s+authenticated/i, 'configuracion solo SELECT/UPDATE');
  requireMatch(errors, source, /GRANT SELECT, UPDATE ON TABLE\s+public\.business_capabilities\s+TO\s+authenticated/i, 'capabilities solo SELECT/UPDATE');

  const orgSelect = policyBlock(source, 'organizations_select_current');
  requireMatch(errors, orgSelect, /FOR SELECT[\s\S]*?TO authenticated[\s\S]*?id\s*=\s*\(SELECT private\.current_organization_id\(\)\)/i, 'organizations aislada por tenant actual');

  const appUsers = policyBlock(source, 'app_users_select_current_tenant');
  requireMatch(errors, appUsers, /organization_id\s*=\s*\(SELECT private\.current_organization_id\(\)\)/i, 'app_users aislado por tenant');
  requireMatch(errors, appUsers, /user_id\s*=\s*\(SELECT auth\.uid\(\)\)[\s\S]*?private\.has_permission\('tenant\.admin'\)/i, 'app_users: self o admin del tenant');

  for (const name of ['empleados_tenant_select', 'empleados_tenant_insert', 'empleados_tenant_update', 'empleados_tenant_delete']) {
    const block = policyBlock(source, name);
    requireMatch(errors, block, /organization_id\s*=\s*\(SELECT private\.current_organization_id\(\)\)/i, `${name}: organization_id tenant-aware`);
  }
  requireMatch(errors, policyBlock(source, 'empleados_tenant_select'), /private\.has_permission\('tenant\.read'\)/i, 'empleados SELECT requiere tenant.read');
  for (const name of ['empleados_tenant_insert', 'empleados_tenant_update', 'empleados_tenant_delete']) {
    requireMatch(errors, policyBlock(source, name), /private\.has_permission\('tenant\.admin'\)/i, `${name}: escritura solo admin`);
  }
  requireMatch(errors, policyBlock(source, 'empleados_tenant_update'), /USING\s*\([\s\S]*?\)\s*WITH CHECK\s*\(/i, 'empleados UPDATE tiene USING y WITH CHECK');

  for (const prefix of ['configuracion', 'business_capabilities']) {
    const selectBlock = policyBlock(source, `${prefix}_tenant_select`);
    const updateBlock = policyBlock(source, `${prefix}_tenant_update`);
    requireMatch(errors, selectBlock, /organization_id\s*=\s*\(SELECT private\.current_organization_id\(\)\)[\s\S]*?private\.has_permission\('tenant\.read'\)/i, `${prefix} SELECT tenant-aware`);
    requireMatch(errors, updateBlock, /organization_id\s*=\s*\(SELECT private\.current_organization_id\(\)\)[\s\S]*?private\.has_permission\('tenant\.admin'\)/i, `${prefix} UPDATE admin tenant-aware`);
    requireMatch(errors, updateBlock, /USING\s*\([\s\S]*?\)\s*WITH CHECK\s*\(/i, `${prefix} UPDATE tiene USING y WITH CHECK`);
  }

  for (const legacy of ['empleados_admin_delete', 'empleados_admin_insert', 'empleados_admin_update', 'empleados_select_activos', 'configuracion_select', 'business_capabilities_read']) {
    requireMatch(errors, source, new RegExp(`DROP POLICY IF EXISTS\\s+${legacy}\\s+ON`, 'i'), `retira policy legacy ${legacy}`);
  }

  if (/\bapp_es_admin\s*\(|\bapp_empleado_activo\s*\(/i.test(executable)) {
    errors.push('Fase 2.2 no debe usar helpers legacy de empleados');
  }
  if (/\bFORCE ROW LEVEL SECURITY\b/i.test(executable)) {
    errors.push('No usar FORCE RLS en fundación: rompería helpers/bootstrap SECURITY DEFINER del owner');
  }
  if (/\borganization_id\s*=\s*['"]?[0-9]+|\bbusiness_id\s*=\s*1\b/i.test(executable)) {
    errors.push('RLS no puede usar tenant/business singleton fijo');
  }
  if (/GRANT\s+(?:ALL|INSERT|DELETE)[^;]*ON TABLE\s+public\.(?:organizations|app_users|configuracion_negocio|business_capabilities)\b/i.test(executable)) {
    errors.push('Fundación no debe abrir INSERT/DELETE directo en tablas sensibles');
  }

  return errors;
}

function load() {
  return fs.readFileSync(path.join(root, 'supabase', 'migrations', migrationName), 'utf8');
}

function selfTest() {
  const valid = load();
  const cases = [
    ['contrato válido', valid, false],
    ['policy sin tenant', valid.replace('organization_id = (SELECT private.current_organization_id())', 'true'), true],
    ['update sin with-check', valid.replace(/WITH CHECK \([\s\S]*?\);/, ';'), true],
    ['helper legacy reintroducido', `${valid}\nSELECT public.app_es_admin();`, true],
    ['FORCE RLS inseguro para bootstrap', `${valid}\nALTER TABLE public.organizations FORCE ROW LEVEL SECURITY;`, true],
  ];
  const failed = [];
  for (const [name, source, shouldFail] of cases) {
    const didFail = verifyRls(source).length > 0;
    if (didFail !== shouldFail) failed.push(name);
  }
  if (failed.length) {
    console.error('SaaS RLS self-test FAILED:');
    for (const name of failed) console.error(`  - ${name}`);
    process.exit(1);
  }
  console.log(`SaaS RLS self-test OK (${cases.length} contratos/casos).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}
const file = path.join(root, 'supabase', 'migrations', migrationName);
if (!fs.existsSync(file)) {
  console.error(`SaaS RLS gate FAILED: falta ${migrationName}`);
  process.exit(1);
}
const errors = verifyRls(load());
if (errors.length) {
  console.error('SaaS RLS gate FAILED:');
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}
console.log('SaaS RLS gate OK (Fase 2.2 fundación).');
