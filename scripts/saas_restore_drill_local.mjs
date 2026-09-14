import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import {
  collectRecoveryFingerprints,
  currentGitSha,
  ensure,
  fileSize,
  listStorageBuckets,
  listStorageObjects,
  loadLocalSupabaseConfig,
  psql,
  readJson,
  remoteStorageHash,
  runCommand,
  sha256File,
  uploadStorageArtifacts,
  verifyLocalStorageArtifacts,
  writeJson,
} from './saas_backup_common.mjs';

const FORMAT = 'stomni-saas-backup';
const FORMAT_VERSION = 1;
const DESTRUCTIVE_OPT_IN = 'STOMNI_ALLOW_DESTRUCTIVE_RESTORE';

function resolveBackupDir() {
  const positional = process.argv.slice(2).find((arg) => !arg.startsWith('--'));
  const configured = process.env.STOMNI_SAAS_BACKUP_DIR?.trim();
  const raw = positional ?? configured;
  ensure(raw, 'Uso: node scripts/saas_restore_drill_local.mjs <backup-dir>');
  return path.resolve(raw);
}

function verifyManifest(backupDir, manifest) {
  ensure(manifest?.format === FORMAT, 'Formato de manifest de backup no reconocido.');
  ensure(manifest?.format_version === FORMAT_VERSION, 'Versión de manifest de backup no soportada.');
  ensure(Array.isArray(manifest.dumps) && manifest.dumps.length === 2, 'El backup debe contener exactamente los dumps public/auth.');
  ensure(Array.isArray(manifest.storage?.objects), 'Manifest sin inventario Storage.');

  for (const dump of manifest.dumps) {
    const absolute = path.join(backupDir, dump.file);
    ensure(fs.existsSync(absolute), `Falta dump ${dump.file}.`);
    ensure(fileSize(absolute) === dump.size, `Tamaño inválido para ${dump.file}.`);
    ensure(sha256File(absolute) === dump.sha256, `SHA-256 inválido para ${dump.file}.`);
  }
  verifyLocalStorageArtifacts(manifest.storage.objects, path.join(backupDir, 'storage'));
}

function requireSameSchemaCommit(manifest) {
  const backupSha = manifest.source?.git_sha;
  const currentSha = currentGitSha();
  if (!backupSha || !currentSha || backupSha === currentSha) return;
  ensure(
    process.env.STOMNI_ALLOW_SCHEMA_MISMATCH === 'YES',
    `El backup fue creado en ${backupSha} y el checkout actual es ${currentSha}. ` +
      'Usa el mismo commit o define STOMNI_ALLOW_SCHEMA_MISMATCH=YES sólo para un drill deliberado.',
  );
}

function clearRestoreTargets(dbUrl) {
  psql(dbUrl, `
    DO $purge$
    DECLARE r record;
    BEGIN
      FOR r IN
        SELECT c.relname AS table_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='public'
          AND c.relkind IN ('r','p')
          AND NOT EXISTS (
            SELECT 1
            FROM pg_depend d
            JOIN pg_extension e ON e.oid=d.refobjid
            WHERE d.classid='pg_class'::regclass
              AND d.objid=c.oid
              AND d.deptype='e'
          )
        ORDER BY c.relname
      LOOP
        EXECUTE format('TRUNCATE TABLE public.%I CASCADE',r.table_name);
      END LOOP;
    END;
    $purge$;
    TRUNCATE TABLE auth.identities,auth.users CASCADE;
    TRUNCATE TABLE storage.objects CASCADE;
  `);
}

function restoreLogicalData(dbUrl, backupDir, manifest) {
  const ordered = [...manifest.dumps].sort((a, b) => a.restore_order - b.restore_order);
  for (const dump of ordered) {
    runCommand('pg_restore', [
      '--dbname', dbUrl,
      '--data-only',
      '--disable-triggers',
      '--no-owner',
      '--no-privileges',
      '--exit-on-error',
      path.join(backupDir, dump.file),
    ]);
  }
}

function verifyBuckets(dbUrl, manifest) {
  const target = new Set(listStorageBuckets(dbUrl).map((bucket) => bucket.id));
  const required = new Set(manifest.storage.objects.map((object) => object.bucket_id));
  for (const bucket of required) {
    ensure(
      target.has(bucket),
      `El bucket ${bucket} no existe después de db reset. La infraestructura Storage debe provenir de migraciones versionadas.`,
    );
  }
}

async function verifyRestoredStorage(config, manifest) {
  const currentObjects = listStorageObjects(config.dbUrl);
  const expectedKeys = manifest.storage.objects
    .map((object) => `${object.bucket_id}\0${object.name}`)
    .sort();
  const actualKeys = currentObjects
    .map((object) => `${object.bucket_id}\0${object.name}`)
    .sort();
  ensure(
    JSON.stringify(actualKeys) === JSON.stringify(expectedKeys),
    'El inventario de objetos Storage restaurado no coincide exactamente con el backup.',
  );

  for (const object of manifest.storage.objects) {
    const remote = await remoteStorageHash(config, object);
    ensure(remote.size === object.size, `Tamaño Storage distinto para ${object.bucket_id}/${object.name}.`);
    ensure(remote.sha256 === object.sha256, `SHA-256 Storage distinto para ${object.bucket_id}/${object.name}.`);
  }
}

async function main() {
  ensure(
    process.env[DESTRUCTIVE_OPT_IN] === 'YES',
    `Restore bloqueado. Define ${DESTRUCTIVE_OPT_IN}=YES sólo en el laboratorio local que aceptas destruir.`,
  );

  const backupDir = resolveBackupDir();
  const manifestPath = path.join(backupDir, 'manifest.json');
  ensure(fs.existsSync(manifestPath), `No existe ${manifestPath}.`);
  const manifest = readJson(manifestPath);
  verifyManifest(backupDir, manifest);
  requireSameSchemaCommit(manifest);

  const beforeReset = loadLocalSupabaseConfig();
  console.log(`F9.3 restore drill LOCAL destructivo sobre ${beforeReset.safeDatabaseLabel}`);
  console.log('Ejecutando supabase db reset...');
  runCommand('supabase', ['db', 'reset']);

  const config = loadLocalSupabaseConfig();
  clearRestoreTargets(config.dbUrl);
  restoreLogicalData(config.dbUrl, backupDir, manifest);
  verifyBuckets(config.dbUrl, manifest);
  await uploadStorageArtifacts(config, manifest.storage.objects, path.join(backupDir, 'storage'));

  const restoredFingerprints = collectRecoveryFingerprints(config.dbUrl);
  ensure(
    JSON.stringify(restoredFingerprints) === JSON.stringify(manifest.fingerprints),
    'Los fingerprints DB posteriores al restore no coinciden exactamente con el snapshot.',
  );
  await verifyRestoredStorage(config, manifest);

  const reportPath = path.resolve('.dart_tool', 'saas', 'f9_3_restore_report.json');
  writeJson(reportPath, {
    status: 'RESTORE_DRILL_GREEN',
    completed_at: new Date().toISOString(),
    backup_dir: backupDir,
    backup_created_at: manifest.created_at,
    backup_git_sha: manifest.source?.git_sha ?? null,
    restore_git_sha: currentGitSha(),
    database: config.safeDatabaseLabel,
    database_fingerprints_exact: true,
    storage_object_count: manifest.storage.objects.length,
    storage_hashes_exact: true,
  });

  console.log('F9.3 restore drill GREEN.');
  console.log(`  - DB fingerprints exactos: sí`);
  console.log(`  - Storage hashes exactos: ${manifest.storage.objects.length}`);
  console.log(`  - evidencia: ${reportPath}`);
}

main().catch((error) => {
  console.error(`F9.3 restore drill FAILED: ${error.message}`);
  process.exit(1);
});
