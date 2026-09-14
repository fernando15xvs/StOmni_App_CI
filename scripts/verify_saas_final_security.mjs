import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const selfPath = 'scripts/verify_saas_final_security.mjs';

function fail(errors, condition, message) {
  if (!condition) errors.push(message);
}

function trackedFiles() {
  const output = execFileSync('git', ['ls-files', '-z'], {
    cwd: root,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return output.split('\0').filter(Boolean);
}

function isClientPath(file) {
  return [
    'packages/core_logic/',
    'packages/mobile_app/',
    'packages/desktop_app/',
    'apps/',
  ].some((prefix) => file.startsWith(prefix));
}

function isClientRuntimePath(file) {
  if (!isClientPath(file)) return false;
  const normalized = `/${file.replaceAll('\\', '/')}/`;
  return !normalized.includes('/test/')
    && !normalized.includes('/integration_test/');
}

function isTextSource(file) {
  return /\.(?:dart|ts|tsx|js|jsx|mjs|cjs|java|kt|kts|swift|m|mm|h|hpp|cpp|cs|json|ya?ml|toml|sql|md|txt|properties|gradle|xml|plist)$/i.test(file)
    || path.basename(file).startsWith('.env');
}

function read(file) {
  return fs.readFileSync(path.join(root, file), 'utf8');
}

export function validateSensitivePaths(files) {
  const errors = [];
  const forbidden = [
    /(^|\/)\.env$/i,
    /(^|\/)\.env\.(?!example$)[^/]+$/i,
    /\.(?:pem|p12|pfx|key|jks|keystore)$/i,
    /(^|\/)(?:id_rsa|id_ed25519)$/i,
  ];
  for (const file of files) {
    if (forbidden.some((expression) => expression.test(file))) {
      errors.push(`archivo sensible versionado: ${file}`);
    }
  }
  return errors;
}

export function validateClientSource(file, source) {
  const errors = [];
  const checks = [
    ['SUPABASE_SERVICE_ROLE_KEY', /SUPABASE_SERVICE_ROLE_KEY/],
    ['service-role Supabase secret', /\bsb_secret_[A-Za-z0-9._-]+/],
    ['cron secret', /FACTURACION_CRON_SECRET|x-cron-secret/i],
    ['APIsPeru secret', /APIS_PERU_(?:DNIRUC_)?TOKEN/i],
    ['Auth admin API', /\.auth\.admin\b|auth\.admin\b/],
    ['observability writer interno', /record_observability_event_v1/],
    ['private key', /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/],
  ];
  for (const [label, expression] of checks) {
    fail(errors, !expression.test(source), `${file}: cliente contiene ${label}`);
  }
  return errors;
}

export function validateGeneralSource(file, source) {
  const errors = [];
  if (/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(source)) {
    errors.push(`${file}: contiene una clave privada embebida`);
  }
  if (/\bsb_secret_[A-Za-z0-9._-]{12,}/.test(source)) {
    errors.push(`${file}: contiene una clave Supabase secreta embebida`);
  }
  return errors;
}

function validateRequiredSecurityArtifacts(errors, files) {
  const required = [
    'scripts/verify_no_new_singletons.mjs',
    'scripts/verify_saas_authorization.mjs',
    'scripts/verify_saas_rls.mjs',
    'scripts/verify_saas_rpc_surface.mjs',
    'scripts/verify_saas_observability.mjs',
    selfPath,
    'supabase/tests/database/final_security_contract_test.sql',
    'docs/saas/44_FASE9_5_SEGURIDAD_FINAL.md',
    'docs/saas/99_MAPA_MAESTRO_PRUEBAS_SAAS.md',
    'docs/ROADMAP_SAAS_MULTI_TENANT_CHECKLIST.md',
  ];
  for (const file of required) {
    fail(errors, files.includes(file), `falta artefacto de seguridad: ${file}`);
  }
}

function validateMapAndChecklist(errors) {
  const map = read('docs/saas/99_MAPA_MAESTRO_PRUEBAS_SAAS.md');
  const checklist = read('docs/ROADMAP_SAAS_MULTI_TENANT_CHECKLIST.md');
  const audit = read('docs/saas/44_FASE9_5_SEGURIDAD_FINAL.md');

  fail(errors,
    /node scripts\/verify_saas_final_security\.mjs --self-test[\s\S]*?node scripts\/verify_saas_final_security\.mjs/.test(map),
    'T02 no incluye gate final de seguridad');
  fail(errors,
    /# T16 — Hardening de seguridad[\s\S]*?verify_saas_final_security\.mjs/i.test(map),
    'T16 no referencia el gate final de seguridad');
  fail(errors,
    /final_security_contract_test\.sql/.test(map),
    'T04/T16 no incorpora contrato DB de seguridad final');
  fail(errors,
    /\[x\] Fase 9\.5 — Seguridad final\./.test(checklist),
    'checklist no marca F9.5 implementada');
  fail(errors,
    /\[ \] \*\*GATE BLOQUE 9 VERDE\*\*/.test(checklist),
    'Gate Bloque 9 se cerró antes de T00–T19/F9.6');
  fail(errors,
    /IMPLEMENTADA \/ VALIDACIÓN DINÁMICA LOCAL PENDIENTE/.test(audit),
    'auditoría F9.5 no separa implementación de validación dinámica');
}

function verify() {
  const errors = [];
  const files = trackedFiles();
  errors.push(...validateSensitivePaths(files));
  validateRequiredSecurityArtifacts(errors, files);

  for (const file of files) {
    if (!isTextSource(file)) continue;
    let source;
    try {
      source = read(file);
    } catch {
      continue;
    }
    // El gate contiene deliberadamente patrones/literales inseguros como fixtures
    // de su self-test. No debe marcar su propio código de prueba como un secreto
    // real versionado; el resto del repositorio sí se inspecciona completo.
    if (file !== selfPath) {
      errors.push(...validateGeneralSource(file, source));
    }
    // Los tests de arquitectura pueden contener los nombres de secretos/APIs
    // precisamente dentro de assertions `isNot(contains(...))`. Esos nombres
    // simbólicos no son credenciales. La prohibición contextual se aplica sólo
    // al runtime cliente; el escaneo general de secretos reales sí cubre tests.
    if (isClientRuntimePath(file)) {
      errors.push(...validateClientSource(file, source));
    }
  }

  if (errors.length === 0) validateMapAndChecklist(errors);
  return errors;
}

function selfTest() {
  const cleanFiles = [
    '.env.example',
    'packages/mobile_app/lib/main.dart',
  ];
  const cleanPathErrors = validateSensitivePaths(cleanFiles);
  if (cleanPathErrors.length) {
    console.error('Final security gate self-test positivo FAILED:', cleanPathErrors);
    process.exit(1);
  }

  const badPaths = ['.env', 'android/upload.keystore', 'certs/prod.p12'];
  const badPathErrors = validateSensitivePaths(badPaths);
  if (badPathErrors.length !== 3) {
    console.error('Final security gate self-test paths FAILED:', badPathErrors);
    process.exit(1);
  }

  const badClient = `
    const secret = 'SUPABASE_SERVICE_ROLE_KEY';
    final h = {'x-cron-secret': 'abc'};
    client.auth.admin.deleteUser('x');
    client.rpc('record_observability_event_v1');
  `;
  const badClientErrors = validateClientSource('packages/mobile_app/lib/bad.dart', badClient);
  if (badClientErrors.length < 4) {
    console.error('Final security gate self-test client FAILED:', badClientErrors);
    process.exit(1);
  }

  const privateKey = '-----BEGIN PRIVATE KEY-----\\nabc';
  if (validateGeneralSource('bad.txt', privateKey).length !== 1) {
    console.error('Final security gate self-test private-key FAILED');
    process.exit(1);
  }

  if (isClientRuntimePath('packages/mobile_app/test/architecture/client_env_safety_test.dart')) {
    console.error('Final security gate self-test test-fixture scope FAILED');
    process.exit(1);
  }
  if (!isClientRuntimePath('packages/mobile_app/lib/main.dart')) {
    console.error('Final security gate self-test runtime scope FAILED');
    process.exit(1);
  }

  console.log('SaaS final security gate self-test OK.');
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

let errors;
try {
  errors = verify();
} catch (error) {
  console.error('SaaS final security gate FAILED al inspeccionar archivos versionados.');
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}

if (errors.length) {
  console.error('SaaS final security gate FAILED:');
  errors.forEach((error) => console.error(`  - ${error}`));
  process.exit(1);
}

console.log('SaaS final security gate OK.');
console.log('  - sin archivos de secretos/certificados privados versionados');
console.log('  - sin credenciales/backend admin APIs en runtime Flutter');
console.log('  - artefactos de aislamiento/RLS/RPC/observabilidad presentes');
console.log('  - validación adversarial runtime permanece reservada para T07/T10/T11/T16/T19');
