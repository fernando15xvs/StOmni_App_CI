import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const files = {
  dashboard: 'supabase/migrations/20260908024900_saas_dashboard_summary_tenant.sql',
  permissions: 'supabase/migrations/20260908025000_saas_employee_permissions_tenant.sql',
  deferred: 'supabase/migrations/20260908025100_saas_deferred_operational_rpc_fail_closed.sql',
};

const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
function need(errors, src, re, label) {
  if (!re.test(src)) errors.push(`Falta: ${label}`);
}

function verify() {
  const errors = [];
  for (const file of Object.values(files)) {
    if (!fs.existsSync(path.join(root, file))) errors.push(`Falta archivo: ${file}`);
  }
  if (errors.length) return errors;

  const dashboard = read(files.dashboard);
  const permissions = read(files.permissions);
  const deferred = read(files.deferred);

  need(errors, dashboard, /CREATE OR REPLACE FUNCTION public\.get_dashboard_summary/i, 'dashboard redefinido');
  need(errors, dashboard, /private\.require_current_organization_id\(\)/i, 'dashboard deriva tenant server-side');
  need(errors, dashboard, /organization_id\s*=\s*v_org/i, 'dashboard filtra por tenant');
  if (/FROM\s+public\.movimientos\b/i.test(dashboard)) {
    errors.push('dashboard no debe depender de movimientos antes de F4.3');
  }

  need(errors, permissions, /ADD COLUMN organization_id uuid/i, 'overrides con organization_id');
  need(errors, permissions, /FOREIGN KEY \(organization_id, employee_id\)/i, 'FK compuesta override->empleado');
  need(errors, permissions, /PRIMARY KEY \(organization_id, employee_id, permission_code\)/i, 'PK tenant de overrides');
  need(errors, permissions, /private\.require_current_organization_id\(\)/i, 'RPC permisos derivan tenant');
  need(errors, permissions, /FROM public\.app_users au/i, 'identidad de permisos usa app_users');
  need(errors, permissions, /WHERE e\.organization_id = v_org[\s\S]{0,80}?AND e\.id = p_employee_id/i, 'empleado objetivo scopeado');
  need(errors, permissions, /ON CONFLICT \(organization_id, employee_id, permission_code\)/i, 'upsert tenant de overrides');
  need(errors, permissions, /'purchases\.manage'/i, 'catálogo de permisos conserva purchases.manage');

  need(errors, deferred, /CREATE OR REPLACE FUNCTION public\.get_estado_caja_chica\(\)/i, 'Caja placeholder explícito');
  need(errors, deferred, /private\.require_current_organization_id\(\)/i, 'Caja placeholder exige tenant válido');
  need(errors, deferred, /'abierta', false/i, 'Caja permanece fail-closed');
  if (/FROM\s+public\.(?:sesiones_caja|movimientos)\b/i.test(deferred)) {
    errors.push('placeholder de Caja no debe leer tablas aún no tenantificadas');
  }
  need(errors, deferred, /REVOKE ALL ON FUNCTION public\.registrar_pago_empleado_mixto[\s\S]{0,160}?FROM PUBLIC, anon, authenticated/i, 'pago de empleado revocado hasta F4.3/F4.4');

  return errors;
}

function selfTest() {
  const errors = verify();
  if (errors.length) {
    console.error('SaaS transversal RPC self-test FAILED:');
    errors.forEach((e) => console.error(`  - ${e}`));
    process.exit(1);
  }
  const valid = read(files.deferred);
  if (!/'abierta', false/i.test(valid)) {
    console.error('SaaS transversal RPC self-test FAILED: Caja no fail-closed');
    process.exit(1);
  }
  console.log('SaaS transversal RPC self-test OK.');
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify();
if (errors.length) {
  console.error('SaaS transversal RPC gate FAILED:');
  errors.forEach((e) => console.error(`  - ${e}`));
  process.exit(1);
}
console.log('SaaS transversal RPC gate OK.');
