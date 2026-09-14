import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrations = {
  organizations: '20260907020334_saas_organizations.sql',
  appUsers: '20260907020815_saas_app_users.sql',
  employees: '20260907022207_saas_employees_identity_separation.sql',
};

function requireMatch(errors, source, regex, description) {
  if (!regex.test(source)) errors.push(`Falta: ${description}`);
}

function rejectClientGrant(errors, source, table) {
  const pattern = new RegExp(
    `GRANT\\s+.+\\s+ON\\s+(?:TABLE\\s+)?public\\.${table}\\s+TO\\s+(?:anon|authenticated)`,
    'i',
  );
  if (pattern.test(source)) {
    errors.push(`${table} no debe otorgar acceso cliente directo en Bloque 1`);
  }
}

function rejectLegacySingleton(errors, source, label) {
  const executableSql = source.replace(/--.*$/gm, '');
  if (/\bbusiness_id\b|\bconfiguracion_negocio\b|\bid\s*=\s*1\b/i.test(executableSql)) {
    errors.push(`${label} no debe depender del modelo singleton legacy`);
  }
}

function verifyOrganizations(source) {
  const errors = [];
  requireMatch(errors, source, /CREATE TABLE\s+public\.organizations\s*\(/i, 'tabla public.organizations');
  requireMatch(errors, source, /\bid\s+uuid\s+PRIMARY KEY\s+DEFAULT\s+gen_random_uuid\(\)/i, 'organizations PK UUID generada');
  requireMatch(errors, source, /\blegal_name\s+text\b/i, 'organizations.legal_name');
  requireMatch(errors, source, /\bdisplay_name\s+text\s+NOT NULL\b/i, 'organizations.display_name obligatorio');
  requireMatch(errors, source, /\bcountry_code\s+text\s+NOT NULL\b/i, 'organizations.country_code obligatorio');
  requireMatch(errors, source, /\bcurrency_code\s+text\s+NOT NULL\b/i, 'organizations.currency_code obligatorio');
  requireMatch(errors, source, /\btimezone\s+text\s+NOT NULL\b/i, 'organizations.timezone obligatorio');
  requireMatch(errors, source, /\bstatus\s+text\s+NOT NULL\s+DEFAULT\s+'active'/i, 'organizations.status default active');
  requireMatch(errors, source, /CHECK\s*\(status\s+IN\s*\('active',\s*'suspended',\s*'closed'\)\)/i, 'organizations estados validos');
  requireMatch(errors, source, /\bcreated_at\s+timestamptz\s+NOT NULL\s+DEFAULT\s+now\(\)/i, 'organizations.created_at');
  requireMatch(errors, source, /\bupdated_at\s+timestamptz\s+NOT NULL\s+DEFAULT\s+now\(\)/i, 'organizations.updated_at');
  requireMatch(errors, source, /ALTER TABLE\s+public\.organizations\s+ENABLE ROW LEVEL SECURITY/i, 'organizations RLS habilitado');
  requireMatch(errors, source, /REVOKE ALL ON TABLE\s+public\.organizations\s+FROM\s+PUBLIC,\s*anon,\s*authenticated/i, 'organizations cerrada a roles cliente');
  requireMatch(errors, source, /IF\s+TG_OP\s*=\s*'UPDATE'\s+AND\s+NEW\.id\s+IS DISTINCT FROM\s+OLD\.id/i, 'organizations UUID inmutable');
  requireMatch(errors, source, /NEW\.updated_at\s*:=\s*clock_timestamp\(\)/i, 'organizations updated_at automatico');
  requireMatch(errors, source, /SECURITY INVOKER/i, 'organizations trigger SECURITY INVOKER');
  requireMatch(errors, source, /FROM\s+pg_catalog\.pg_timezone_names/i, 'organizations validacion IANA de timezone');
  requireMatch(errors, source, /SET search_path\s*=\s*pg_catalog/i, 'organizations search_path fijo');
  rejectClientGrant(errors, source, 'organizations');
  rejectLegacySingleton(errors, source, 'organizations');
  return errors;
}

function verifyAppUsers(source) {
  const errors = [];
  requireMatch(errors, source, /CREATE TABLE\s+public\.app_users\s*\(/i, 'tabla public.app_users');
  requireMatch(errors, source, /\buser_id\s+uuid\s+PRIMARY KEY[\s\S]{0,120}?REFERENCES\s+auth\.users\s*\(\s*id\s*\)\s+ON DELETE CASCADE/i, 'app_users.user_id PK -> auth.users');
  requireMatch(errors, source, /\borganization_id\s+uuid\s+NOT NULL[\s\S]{0,120}?REFERENCES\s+public\.organizations\s*\(\s*id\s*\)\s+ON DELETE RESTRICT/i, 'app_users.organization_id -> organizations');
  requireMatch(errors, source, /UNIQUE\s*\(\s*organization_id\s*,\s*user_id\s*\)/i, 'app_users FK composite key disponible');
  requireMatch(errors, source, /\bstatus\s+text\s+NOT NULL\s+DEFAULT\s+'active'/i, 'app_users.status default active');
  requireMatch(errors, source, /CHECK\s*\(status\s+IN\s*\('active',\s*'disabled'\)\)/i, 'app_users estados validos');
  requireMatch(errors, source, /\bbase_role\s+text\s+NOT NULL\s+DEFAULT\s+'operador'/i, 'app_users.base_role default operador');
  requireMatch(errors, source, /CHECK\s*\(base_role\s+IN\s*\('admin',\s*'operador'\)\)/i, 'app_users roles base validos');
  requireMatch(errors, source, /\bcreated_at\s+timestamptz\s+NOT NULL\s+DEFAULT\s+now\(\)/i, 'app_users.created_at');
  requireMatch(errors, source, /\bupdated_at\s+timestamptz\s+NOT NULL\s+DEFAULT\s+now\(\)/i, 'app_users.updated_at');
  requireMatch(errors, source, /ALTER TABLE\s+public\.app_users\s+ENABLE ROW LEVEL SECURITY/i, 'app_users RLS habilitado');
  requireMatch(errors, source, /REVOKE ALL ON TABLE\s+public\.app_users\s+FROM\s+PUBLIC,\s*anon,\s*authenticated/i, 'app_users cerrada a roles cliente');
  requireMatch(errors, source, /NEW\.user_id\s+IS DISTINCT FROM\s+OLD\.user_id/i, 'app_users.user_id inmutable');
  requireMatch(errors, source, /NEW\.organization_id\s+IS DISTINCT FROM\s+OLD\.organization_id/i, 'app_users.organization_id inmutable V1');
  requireMatch(errors, source, /NEW\.updated_at\s*:=\s*clock_timestamp\(\)/i, 'app_users updated_at automatico');
  requireMatch(errors, source, /SECURITY INVOKER/i, 'app_users trigger SECURITY INVOKER');
  requireMatch(errors, source, /SET search_path\s*=\s*pg_catalog/i, 'app_users search_path fijo');
  rejectClientGrant(errors, source, 'app_users');
  rejectLegacySingleton(errors, source, 'app_users');
  return errors;
}

function verifyEmployees(source) {
  const errors = [];
  requireMatch(errors, source, /ALTER TABLE\s+public\.empleados[\s\S]*?ADD COLUMN\s+organization_id\s+uuid/i, 'empleados.organization_id');
  requireMatch(errors, source, /ADD COLUMN\s+app_user_id\s+uuid/i, 'empleados.app_user_id opcional');
  requireMatch(errors, source, /FOREIGN KEY\s*\(\s*organization_id\s*\)[\s\S]{0,120}?REFERENCES\s+public\.organizations\s*\(\s*id\s*\)\s+ON DELETE RESTRICT/i, 'empleados.organization_id -> organizations');
  requireMatch(errors, source, /UNIQUE\s*\(\s*app_user_id\s*\)/i, 'un app_user no puede enlazar dos empleados');
  requireMatch(errors, source, /FOREIGN KEY\s*\(\s*organization_id\s*,\s*app_user_id\s*\)[\s\S]{0,160}?REFERENCES\s+public\.app_users\s*\(\s*organization_id\s*,\s*user_id\s*\)/i, 'vinculo empleado/app_user dentro del mismo tenant');
  requireMatch(errors, source, /CHECK\s*\(\s*organization_id\s+IS NOT NULL\s*\)\s+NOT VALID/i, 'organization_id exigido a nuevas filas sin romper legacy');
  requireMatch(errors, source, /CHECK\s*\([\s\S]{0,160}?auth_id\s+IS NULL[\s\S]{0,80}?app_user_id\s+IS NULL[\s\S]{0,80}?auth_id\s*=\s*app_user_id[\s\S]{0,80}?\)\s+NOT VALID/i, 'consistencia auth_id/app_user_id durante transicion');
  requireMatch(errors, source, /DROP CONSTRAINT IF EXISTS\s+empleados_email_key/i, 'retiro de unicidad global de email');
  requireMatch(errors, source, /CREATE UNIQUE INDEX\s+empleados_organization_email_key[\s\S]{0,180}?ON\s+public\.empleados\s*\(\s*organization_id\s*,\s*email\s*\)\s+NULLS NOT DISTINCT/i, 'email unico por empresa, no global');
  requireMatch(errors, source, /CREATE INDEX\s+empleados_organization_id_idx[\s\S]{0,80}?ON\s+public\.empleados\s*\(\s*organization_id\s*\)/i, 'indice tenant de empleados');
  requireMatch(errors, source, /COMMENT ON COLUMN\s+public\.empleados\.auth_id[\s\S]{0,140}?LEGACY/i, 'auth_id preservado como compatibilidad legacy');
  requireMatch(errors, source, /CREATE OR REPLACE FUNCTION\s+public\.handle_new_user\(\)[\s\S]{0,500}?SET search_path\s*=\s*pg_catalog[\s\S]{0,220}?BEGIN\s+RETURN NEW;\s+END;/i, 'handle_new_user legacy neutralizado');
  requireMatch(errors, source, /CREATE OR REPLACE FUNCTION\s+public\.vincular_usuario_empleado\(\)[\s\S]{0,500}?SET search_path\s*=\s*pg_catalog[\s\S]{0,220}?BEGIN\s+RETURN NEW;\s+END;/i, 'vincular_usuario_empleado legacy neutralizado');
  requireMatch(errors, source, /REVOKE ALL ON FUNCTION\s+public\.handle_new_user\(\)\s+FROM\s+PUBLIC,\s*anon,\s*authenticated/i, 'handle_new_user no ejecutable por cliente');
  requireMatch(errors, source, /REVOKE ALL ON FUNCTION\s+public\.vincular_usuario_empleado\(\)\s+FROM\s+PUBLIC,\s*anon,\s*authenticated/i, 'vincular_usuario_empleado no ejecutable por cliente');
  if (/DROP COLUMN\s+(?:IF EXISTS\s+)?auth_id/i.test(source)) {
    errors.push('Fase 1.3 no debe eliminar empleados.auth_id todavia');
  }
  if (/ADD COLUMN\s+app_user_id\s+uuid\s+NOT NULL/i.test(source) || /ALTER COLUMN\s+app_user_id\s+SET NOT NULL/i.test(source)) {
    errors.push('empleados.app_user_id debe seguir siendo opcional');
  }
  if (/UPDATE\s+(?:public\.)?empleados[\s\S]{0,220}?SET\s+auth_id\s*=[\s\S]{0,220}?WHERE[\s\S]{0,220}?email\s*=/i.test(source)) {
    errors.push('Fase 1.3 no debe conservar auto-vinculacion Auth/empleado por email global');
  }
  rejectClientGrant(errors, source, 'empleados');
  rejectLegacySingleton(errors, source, 'empleados');
  return errors;
}

function selfTest() {
  const organizations = fs.readFileSync(path.join(root, 'supabase', 'migrations', migrations.organizations), 'utf8');
  const appUsers = fs.readFileSync(path.join(root, 'supabase', 'migrations', migrations.appUsers), 'utf8');
  const employees = fs.readFileSync(path.join(root, 'supabase', 'migrations', migrations.employees), 'utf8');

  if (verifyOrganizations(organizations).length || verifyAppUsers(appUsers).length || verifyEmployees(employees).length) {
    console.error('SaaS foundation self-test FAILED (contrato valido rechazado).');
    console.error([
      ...verifyOrganizations(organizations),
      ...verifyAppUsers(appUsers),
      ...verifyEmployees(employees),
    ].join('\n'));
    process.exit(1);
  }

  const unsafeGrant = appUsers.replace(
    'REVOKE ALL ON TABLE public.app_users FROM PUBLIC, anon, authenticated;',
    'GRANT SELECT ON public.app_users TO authenticated;',
  );
  if (verifyAppUsers(unsafeGrant).length === 0) {
    console.error('SaaS foundation self-test FAILED (grant inseguro no detectado).');
    process.exit(1);
  }

  const unsafeEmployee = employees.replace(
    'ADD COLUMN app_user_id uuid;',
    'ADD COLUMN app_user_id uuid NOT NULL;',
  );
  if (verifyEmployees(unsafeEmployee).length === 0) {
    console.error('SaaS foundation self-test FAILED (empleado obligado a tener login no detectado).');
    process.exit(1);
  }

  const unsafeEmailLink = employees.replace(
    /BEGIN\s+RETURN NEW;\s+END;/,
    'BEGIN\n  UPDATE public.empleados SET auth_id = NEW.id WHERE email = NEW.email AND auth_id IS NULL;\n  RETURN NEW;\nEND;',
  );
  if (unsafeEmailLink === employees) {
    console.error('SaaS foundation self-test FAILED (fixture de auto-link global no pudo construirse).');
    process.exit(1);
  }
  if (verifyEmployees(unsafeEmailLink).length === 0) {
    console.error('SaaS foundation self-test FAILED (auto-link global por email no detectado).');
    process.exit(1);
  }

  console.log('SaaS foundation self-test OK (6 contratos/casos).');
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const checks = [
  ['organizations', migrations.organizations, verifyOrganizations],
  ['app_users', migrations.appUsers, verifyAppUsers],
  ['empleados', migrations.employees, verifyEmployees],
];
const errors = [];
for (const [label, fileName, verify] of checks) {
  const file = path.join(root, 'supabase', 'migrations', fileName);
  if (!fs.existsSync(file)) {
    errors.push(`${label}: falta ${fileName}`);
    continue;
  }
  for (const message of verify(fs.readFileSync(file, 'utf8'))) {
    errors.push(`${label}: ${message}`);
  }
}

if (errors.length) {
  console.error('SaaS foundation gate FAILED:');
  for (const message of errors) console.error(`  - ${message}`);
  process.exit(1);
}

console.log(`SaaS foundation gate OK (${checks.length} migraciones).`);
