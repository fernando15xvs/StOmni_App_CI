import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrationName = '20260907024638_saas_authorization_helpers.sql';

function requireMatch(errors, source, regex, description) {
  if (!regex.test(source)) errors.push(`Falta: ${description}`);
}

function verifyAuthorizationHelpers(source) {
  const errors = [];
  const executable = source.replace(/--.*$/gm, '');

  requireMatch(errors, source, /CREATE SCHEMA IF NOT EXISTS\s+private/i, 'schema private');
  requireMatch(errors, source, /REVOKE ALL ON SCHEMA\s+private\s+FROM\s+PUBLIC,\s*anon,\s*authenticated/i, 'private cerrado por defecto');
  requireMatch(errors, source, /GRANT USAGE ON SCHEMA\s+private\s+TO\s+authenticated/i, 'authenticated puede resolver helpers privados');
  requireMatch(errors, source, /ALTER DEFAULT PRIVILEGES IN SCHEMA\s+private[\s\S]{0,100}?REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC/i, 'default EXECUTE revocado en private');

  requireMatch(errors, source, /FUNCTION\s+private\.current_organization_id\(\)[\s\S]{0,180}?SECURITY DEFINER[\s\S]{0,80}?SET search_path\s*=\s*''/i, 'current_organization_id SECURITY DEFINER con search_path vacio');
  requireMatch(errors, source, /FROM\s+public\.app_users\s+AS\s+au[\s\S]{0,160}?JOIN\s+public\.organizations\s+AS\s+o/i, 'tenant resuelto desde app_users + organizations');
  requireMatch(errors, source, /au\.user_id\s*=\s*\(SELECT\s+auth\.uid\(\)\)/i, 'tenant derivado de auth.uid()');
  requireMatch(errors, source, /au\.status\s*=\s*'active'[\s\S]{0,80}?o\.status\s*=\s*'active'/i, 'membership y organizacion deben estar activas');

  requireMatch(errors, source, /FUNCTION\s+private\.is_active_user\(\)[\s\S]{0,180}?SECURITY INVOKER[\s\S]{0,100}?private\.current_organization_id\(\)[\s\S]{0,40}?IS NOT NULL/i, 'is_active_user reutiliza tenant canonico');
  requireMatch(errors, source, /FUNCTION\s+private\.current_base_role\(\)[\s\S]{0,180}?SECURITY DEFINER[\s\S]{0,260}?SELECT\s+au\.base_role/i, 'current_base_role canonico');
  requireMatch(errors, source, /FUNCTION\s+private\.has_permission\(p_permission text\)[\s\S]{0,220}?SECURITY INVOKER/i, 'has_permission SECURITY INVOKER');
  requireMatch(errors, source, /WHEN\s+'tenant\.admin'\s+THEN[\s\S]{0,100}?=\s*'admin'/i, 'permiso tenant.admin solo admin');
  requireMatch(errors, source, /ELSE\s+false\s+END/i, 'permisos desconocidos deny-by-default');
  requireMatch(errors, source, /FUNCTION\s+private\.row_belongs_to_current_organization\([\s\S]{0,80}?p_organization_id uuid[\s\S]{0,240}?p_organization_id\s*=\s*\(SELECT\s+private\.current_organization_id\(\)\)/i, 'helper de pertenencia compara organization_id con tenant actual');
  requireMatch(errors, source, /FUNCTION\s+private\.require_current_organization_id\(\)[\s\S]{0,320}?ERRCODE\s*=\s*'42501'/i, 'require_current_organization_id falla con insufficient_privilege');

  const functions = [
    'current_organization_id\\(\\)',
    'is_active_user\\(\\)',
    'current_base_role\\(\\)',
    'has_permission\\(text\\)',
    'row_belongs_to_current_organization\\(uuid\\)',
    'require_current_organization_id\\(\\)',
  ];
  for (const signature of functions) {
    requireMatch(errors, source, new RegExp(`REVOKE ALL ON FUNCTION\\s+private\\.${signature}\\s+FROM\\s+PUBLIC,\\s*anon,\\s*authenticated`, 'i'), `REVOKE explícito ${signature}`);
    requireMatch(errors, source, new RegExp(`GRANT EXECUTE ON FUNCTION\\s+private\\.${signature}\\s+TO\\s+authenticated`, 'i'), `GRANT mínimo authenticated ${signature}`);
  }

  if (/CREATE\s+(?:OR REPLACE\s+)?FUNCTION\s+public\.[\s\S]{0,240}?SECURITY DEFINER/i.test(executable)) {
    errors.push('Fase 2.1 no debe crear SECURITY DEFINER en schema public expuesto');
  }
  if (/\buser_metadata\b|raw_user_meta_data|auth\.jwt\(\)[\s\S]{0,120}?(?:role|organization|tenant)/i.test(executable)) {
    errors.push('Autorización no puede depender de metadata/JWT editable por usuario');
  }
  if (/current_organization_id\s*\(\s*[a-z_]/i.test(executable)) {
    errors.push('current_organization_id no debe aceptar tenant desde el cliente');
  }
  if (/GRANT\s+EXECUTE[\s\S]{0,140}?TO\s+(?:PUBLIC|anon)\b/i.test(executable)) {
    errors.push('Helpers privados no deben ser ejecutables por PUBLIC/anon');
  }

  return errors;
}

function loadMigration() {
  return fs.readFileSync(path.join(root, 'supabase', 'migrations', migrationName), 'utf8');
}

function selfTest() {
  const valid = loadMigration();
  const cases = [
    ['contrato válido', valid, false],
    ['search_path inseguro', valid.replace("SET search_path = ''", 'SET search_path = public'), true],
    ['organización suspendida aceptada', valid.replaceAll("AND o.status = 'active'", "AND o.status IN ('active','suspended')"), true],
    ['permiso desconocido allow-by-default', valid.replace('ELSE false', 'ELSE true'), true],
    ['metadata editable usada en auth', `${valid}\nSELECT raw_user_meta_data FROM auth.users;`, true],
  ];
  const failed = [];
  for (const [name, source, shouldFail] of cases) {
    const didFail = verifyAuthorizationHelpers(source).length > 0;
    if (didFail !== shouldFail) failed.push(name);
  }
  if (failed.length) {
    console.error('SaaS authorization self-test FAILED:');
    for (const name of failed) console.error(`  - ${name}`);
    process.exit(1);
  }
  console.log(`SaaS authorization self-test OK (${cases.length} contratos/casos).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const file = path.join(root, 'supabase', 'migrations', migrationName);
if (!fs.existsSync(file)) {
  console.error(`SaaS authorization gate FAILED: falta ${migrationName}`);
  process.exit(1);
}
const errors = verifyAuthorizationHelpers(loadMigration());
if (errors.length) {
  console.error('SaaS authorization gate FAILED:');
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}
console.log('SaaS authorization gate OK (Fase 2.1).');
