import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

import {
  collectRecoveryFingerprints,
  currentGitSha,
  downloadStorageObjects,
  ensure,
  fileSize,
  gitWorkingTreeDirty,
  listStorageBuckets,
  listStorageObjects,
  loadLocalSupabaseConfig,
  runCommand,
  sha256File,
  timestampId,
  toolVersion,
  writeJson,
} from './saas_backup_common.mjs';

const FORMAT_VERSION = 1;

function resolveOutputDir() {
  const configured = process.env.STOMNI_SAAS_BACKUP_DIR?.trim();
  if (configured) return path.resolve(configured);
  return path.resolve('.dart_tool', 'saas', 'backups', timestampId());
}

function dumpData(dbUrl, outputDir) {
  const publicDump = path.join(outputDir, 'public-data.dump');
  const authDump = path.join(outputDir, 'auth-identity-data.dump');

  runCommand('pg_dump', [
    '--dbname', dbUrl,
    '--format=custom',
    '--data-only',
    '--no-owner',
    '--no-privileges',
    '--schema=public',
    '--file', publicDump,
  ]);

  runCommand('pg_dump', [
    '--dbname', dbUrl,
    '--format=custom',
    '--data-only',
    '--no-owner',
    '--no-privileges',
    '--table=auth.users',
    '--table=auth.identities',
    '--file', authDump,
  ]);

  return [
    {
      kind: 'public-data',
      file: path.basename(publicDump),
      size: fileSize(publicDump),
      sha256: sha256File(publicDump),
      restore_order: 2,
    },
    {
      kind: 'auth-identity-data',
      file: path.basename(authDump),
      size: fileSize(authDump),
      sha256: sha256File(authDump),
      restore_order: 1,
    },
  ];
}

async function main() {
  const config = loadLocalSupabaseConfig();
  const outputDir = resolveOutputDir();
  ensure(!fs.existsSync(outputDir), `El directorio de backup ya existe: ${outputDir}`);
  fs.mkdirSync(outputDir, { recursive: true });

  const tools = {
    supabase: toolVersion('supabase'),
    psql: toolVersion('psql'),
    pg_dump: toolVersion('pg_dump'),
    pg_restore: toolVersion('pg_restore'),
  };

  console.log(`F9.3 backup local -> ${outputDir}`);
  console.log(`DB local verificada: ${config.safeDatabaseLabel}`);

  const before = collectRecoveryFingerprints(config.dbUrl);
  const dumps = dumpData(config.dbUrl, outputDir);

  const storageObjects = listStorageObjects(config.dbUrl);
  const storageDir = path.join(outputDir, 'storage');
  const storageArtifacts = await downloadStorageObjects(config, storageObjects, storageDir);
  const storageBytes = storageArtifacts.reduce((sum, item) => sum + item.size, 0);

  const after = collectRecoveryFingerprints(config.dbUrl);
  ensure(
    JSON.stringify(before) === JSON.stringify(after),
    'La base cambió mientras se generaba el backup; snapshot rechazado para evitar una evidencia inconsistente.',
  );

  const manifest = {
    format: 'stomni-saas-backup',
    format_version: FORMAT_VERSION,
    created_at: new Date().toISOString(),
    source: {
      git_sha: currentGitSha(),
      working_tree_dirty: gitWorkingTreeDirty(),
      database: config.safeDatabaseLabel,
    },
    tools,
    recovery_contract: {
      schema_source: 'versioned_supabase_migrations',
      logical_data: ['public.*', 'auth.users', 'auth.identities'],
      storage_metadata_source: 'versioned migrations + Storage API recreation',
      storage_bytes_backed_up_separately: true,
      destructive_restore_requires_explicit_opt_in: true,
    },
    dumps,
    fingerprints: before,
    storage: {
      buckets: listStorageBuckets(config.dbUrl),
      object_count: storageArtifacts.length,
      total_bytes: storageBytes,
      objects: storageArtifacts,
    },
  };

  writeJson(path.join(outputDir, 'manifest.json'), manifest);

  console.log('F9.3 backup local OK.');
  console.log(`  - public/auth dumps: ${dumps.length}`);
  console.log(`  - Storage objects: ${storageArtifacts.length}`);
  console.log(`  - Storage bytes: ${storageBytes}`);
  console.log(`  - manifest: ${path.join(outputDir, 'manifest.json')}`);
  console.log('Este snapshot NO certifica recuperación: debe ejecutarse saas_restore_drill_local.mjs en T18.');
}

main().catch((error) => {
  console.error(`F9.3 backup FAILED: ${error.message}`);
  process.exit(1);
});
