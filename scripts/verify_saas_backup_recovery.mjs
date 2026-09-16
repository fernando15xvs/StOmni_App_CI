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

function verifyOperationalBoundaries(errors, { common, backup, restore, tenantExport }) {
  need(errors, common, /LOOPBACK_HOSTS[\s\S]*?127\.0\.0\.1[\s\S]*?localhost/,
    'helpers F9.3 no limitan endpoints a loopback');
  need(errors, common, /protocols: new Set\(\['postgres:', 'postgresql:'\]\)/,
    'DB de backup/restore no exige PostgreSQL local');
  need(errors, common, /protocols: new Set\(\['http:'\]\)/,
    'Storage API de backup/restore no exige HTTP local');
  forbid(errors, `${common}\n${backup}\n${restore}\n${tenantExport}`, /https:\/\/[^'"`\s]*supabase\.co/i,
    'tooling F9.3 contiene endpoint Supabase remoto');

  need(errors, backup, /pg_dump[\s\S]*?--schema=public/,
    'backup no captura datos public con pg_dump');
  need(errors, backup, /--table=auth\.users[\s\S]*?--table=auth\.identities/,
    'backup no captura identidad Auth mínima');
  need(errors, backup, /collectRecoveryFingerprints[\s\S]*?before[\s\S]*?after/,
    'backup no detecta cambios durante el snapshot');
  need(errors, backup, /downloadStorageObjects/,
    'backup no captura bytes reales de Storage');
  need(errors, backup, /storage_bytes_backed_up_separately: true/,
    'manifest no declara separación DB/bytes Storage');

  need(errors, restore, /STOMNI_ALLOW_DESTRUCTIVE_RESTORE[\s\S]*?=== 'YES'/,
    'restore destructivo no exige opt-in exacto');
  need(errors, restore, /runCommand\('supabase', \['db', 'reset'\]\)/,
    'restore drill no reconstruye schema desde migraciones');
  need(errors, restore, /STOMNI_ALLOW_SCHEMA_MISMATCH[\s\S]*?=== 'YES'/,
    'restore no falla cerrado ante commit/schema distinto');
  need(errors, restore, /pg_restore[\s\S]*?--data-only[\s\S]*?--disable-triggers/,
    'restore no repone dumps lógicos de forma controlada');
  need(errors, restore, /uploadStorageArtifacts/,
    'restore no repone bytes Storage');
  need(errors, restore, /database_fingerprints_exact: true[\s\S]*?storage_hashes_exact: true/,
    'restore no exige evidencia exacta DB + Storage');
  need(errors, restore, /status: 'RESTORE_DRILL_GREEN'/,
    'restore no emite estado explícito sólo después de validar');

  need(errors, tenantExport, /--organization-id[\s\S]*?UUID válido/,
    'export tenant no exige organization_id UUID');
  need(errors, tenantExport, /listTenantOwnedTables/,
    'export tenant no deriva tablas por organization_id');
  need(errors, tenantExport, /WHERE t\.organization_id=.*::uuid/,
    'export tenant no filtra cada tabla por organization_id');
  need(errors, tenantExport,
    /SELECT count\(\*\)::text FROM public\.organizations[\s\S]*?organizationCount === '1'/,
    'export tenant no valida inequívocamente la existencia de la organización');
  need(errors, tenantExport, /listStorageObjects\(config\.dbUrl, \{ organizationId \}\)/,
    'export tenant no limita Storage al prefijo de la organización');
  need(errors, tenantExport, /auth_password_hashes_or_sessions: false/,
    'export tenant no declara exclusión de credenciales/sesiones Auth');
  forbid(errors, tenantExport, /auth\.users|encrypted_password|refresh_tokens/i,
    'export tenant incluye superficie Auth sensible');
}

function verify() {
  const errors = [];
  const common = read('scripts/saas_backup_common.mjs');
  const backup = read('scripts/saas_backup_local.mjs');
  const restore = read('scripts/saas_restore_drill_local.mjs');
  const tenantExport = read('scripts/saas_export_tenant.mjs');
  const audit = read('docs/saas/42_FASE9_3_BACKUPS_RECUPERACION.md');
  const map = read('docs/saas/99_MAPA_MAESTRO_PRUEBAS_SAAS.md');
  const checklist = read('docs/ROADMAP_SAAS_MULTI_TENANT_CHECKLIST.md');

  verifyOperationalBoundaries(errors, { common, backup, restore, tenantExport });

  need(errors, audit, /IMPLEMENTADA COMO TOOLING Y POLÍTICA[\s\S]*?RESTORE DRILL LOCAL PENDIENTE/,
    'auditoría F9.3 no distingue implementación de recuperación probada');
  need(errors, audit, /RPO[\s\S]*?RTO[\s\S]*?no se inventan/i,
    'política F9.3 deja ambiguos RPO/RTO comerciales');
  need(errors, audit, /backups administrados por Supabase|backup administrado por Supabase/i,
    'política F9.3 no separa protección hosted de tooling local');
  need(errors, audit, /Storage[\s\S]*?SHA-256/i,
    'política F9.3 no cubre integridad de objetos Storage');
  need(errors, audit, /exportación por empresa|export tenant/i,
    'auditoría F9.3 no cubre exportación por tenant');

  need(errors, map,
    /node scripts\/verify_saas_backup_recovery\.mjs --self-test[\s\S]*?node scripts\/verify_saas_backup_recovery\.mjs/,
    'T02 no incorpora gate F9.3');
  need(errors, map, /pg_dump --version[\s\S]*?pg_restore --version/,
    'T00 no registra toolchain de backup/restore');
  need(errors, map, /saas_export_tenant\.mjs[\s\S]*?ORG_A/,
    'mapa no prueba exportación tenant');
  need(errors, map, /# T18[\s\S]*?saas_backup_local\.mjs[\s\S]*?saas_restore_drill_local\.mjs/,
    'T18 no ejecuta backup + restore drill');
  need(errors, map, /f9_3_restore_report\.json/,
    'mapa no exige evidencia de restore F9.3');

  need(errors, checklist, /\[x\] Fase 9\.3 — Backups y recuperación/,
    'checklist no registra F9.3 implementada');
  need(errors, checklist, /\[ \] \*\*GATE BLOQUE 9 VERDE\*\*/,
    'Gate Bloque 9 se cerró antes del restore drill/T19');

  return errors;
}

function selfTest() {
  const safe = {
    common: `LOOPBACK_HOSTS 127.0.0.1 localhost protocols: new Set(['postgres:', 'postgresql:']) protocols: new Set(['http:'])`,
    backup: `pg_dump --schema=public --table=auth.users --table=auth.identities collectRecoveryFingerprints before after downloadStorageObjects storage_bytes_backed_up_separately: true`,
    restore: `process.env[STOMNI_ALLOW_DESTRUCTIVE_RESTORE] === 'YES'; runCommand('supabase', ['db', 'reset']); process.env.STOMNI_ALLOW_SCHEMA_MISMATCH === 'YES'; pg_restore --data-only --disable-triggers uploadStorageArtifacts database_fingerprints_exact: true storage_hashes_exact: true status: 'RESTORE_DRILL_GREEN'`,
    tenantExport: `--organization-id UUID válido listTenantOwnedTables WHERE t.organization_id=x::uuid SELECT count(*)::text FROM public.organizations organizationCount === '1' listStorageObjects(config.dbUrl, { organizationId }) auth_password_hashes_or_sessions: false`,
  };
  const safeErrors = [];
  verifyOperationalBoundaries(safeErrors, safe);
  if (safeErrors.length) {
    console.error('F9.3 gate self-test seguro falló:', safeErrors);
    process.exit(1);
  }

  const unsafe = {
    ...safe,
    common: safe.common.replace('localhost', 'db.example.com'),
    backup: safe.backup.replace('downloadStorageObjects', 'skipStorage'),
    restore: safe.restore.replace("=== 'YES'", "!== 'NO'").replace('storage_hashes_exact: true', 'storage_hashes_exact: false'),
    tenantExport: `${safe.tenantExport} auth.users encrypted_password`,
  };
  const unsafeErrors = [];
  verifyOperationalBoundaries(unsafeErrors, unsafe);
  if (unsafeErrors.length < 4) {
    console.error('F9.3 gate self-test negativo falló:', unsafeErrors);
    process.exit(1);
  }
  console.log(`SaaS backup/recovery gate self-test OK (${unsafeErrors.length} fronteras inseguras detectadas).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify();
if (errors.length) {
  console.error('SaaS backup/recovery gate FAILED:');
  errors.forEach((error) => console.error(`  - ${error}`));
  process.exit(1);
}
console.log('SaaS backup/recovery gate OK (F9.3).');
console.log('  - backup/restore/export restringidos a Supabase local');
console.log('  - DB y Storage respaldados/verificados por canales separados');
console.log('  - restore destructivo requiere opt-in y commit compatible');
console.log('  - certificación dinámica permanece en T18/T19');
