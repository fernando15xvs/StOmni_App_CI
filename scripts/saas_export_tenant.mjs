import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { execFileSync } from 'node:child_process';

import {
  currentGitSha,
  downloadStorageObjects,
  ensure,
  fileSize,
  fingerprintTenantTable,
  listStorageObjects,
  listTenantOwnedTables,
  loadLocalSupabaseConfig,
  psql,
  sha256File,
  sqlIdentifier,
  sqlLiteral,
  timestampId,
  writeJson,
} from './saas_backup_common.mjs';

function argumentValue(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : null;
}

function resolveOrganizationId() {
  const value = argumentValue('--organization-id') ?? process.env.STOMNI_EXPORT_ORGANIZATION_ID;
  ensure(value, 'Falta --organization-id <uuid> o STOMNI_EXPORT_ORGANIZATION_ID.');
  ensure(
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value),
    'organization_id no es un UUID válido.',
  );
  return value.toLowerCase();
}

function resolveOutputDir(organizationId) {
  const configured = argumentValue('--output') ?? process.env.STOMNI_TENANT_EXPORT_DIR;
  if (configured) return path.resolve(configured);
  return path.resolve('.dart_tool', 'saas', 'tenant-exports', organizationId, timestampId());
}

function writeQueryToJsonl(dbUrl, sql, filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const fd = fs.openSync(filePath, 'w');
  try {
    execFileSync('psql', [
      '--dbname', dbUrl,
      '-X',
      '-v', 'ON_ERROR_STOP=1',
      '-A',
      '-t',
      '-c', sql,
    ], {
      stdio: ['ignore', fd, 'inherit'],
    });
  } finally {
    fs.closeSync(fd);
  }
}

function exportOrganizationRoot(dbUrl, organizationId, dataDir) {
  const file = path.join(dataDir, 'organizations.jsonl');
  writeQueryToJsonl(
    dbUrl,
    `SELECT to_jsonb(o)::text FROM public.organizations o WHERE o.id=${sqlLiteral(organizationId)}::uuid;`,
    file,
  );
  return {
    table: 'organizations',
    filter: 'id = organization_id',
    rows: 1,
    file: path.relative(path.dirname(dataDir), file).replaceAll('\\', '/'),
    size: fileSize(file),
    sha256: sha256File(file),
  };
}

function exportTenantTable(dbUrl, table, organizationId, dataDir) {
  const tableIdent = sqlIdentifier(table);
  const file = path.join(dataDir, `${table}.jsonl`);
  writeQueryToJsonl(
    dbUrl,
    `
      SELECT to_jsonb(t)::text
      FROM public.${tableIdent} t
      WHERE t.organization_id=${sqlLiteral(organizationId)}::uuid
      ORDER BY md5(to_jsonb(t)::text);
    `,
    file,
  );
  const fingerprint = fingerprintTenantTable(dbUrl, table, organizationId);
  return {
    table,
    filter: 'organization_id = requested tenant',
    rows: fingerprint.count,
    fingerprint: fingerprint.hash,
    file: path.relative(path.dirname(dataDir), file).replaceAll('\\', '/'),
    size: fileSize(file),
    sha256: sha256File(file),
  };
}

async function main() {
  const config = loadLocalSupabaseConfig();
  const organizationId = resolveOrganizationId();
  const exists = psql(
    config.dbUrl,
    `SELECT EXISTS(SELECT 1 FROM public.organizations WHERE id=${sqlLiteral(organizationId)}::uuid)::text;`,
  );
  ensure(exists === 't', `La organización ${organizationId} no existe en Supabase local.`);

  const outputDir = resolveOutputDir(organizationId);
  ensure(!fs.existsSync(outputDir), `El directorio de exportación ya existe: ${outputDir}`);
  const dataDir = path.join(outputDir, 'data');
  const storageDir = path.join(outputDir, 'storage');
  fs.mkdirSync(dataDir, { recursive: true });

  const tables = listTenantOwnedTables(config.dbUrl);
  const exported = [exportOrganizationRoot(config.dbUrl, organizationId, dataDir)];
  for (const table of tables) {
    exported.push(exportTenantTable(config.dbUrl, table, organizationId, dataDir));
  }

  const objects = listStorageObjects(config.dbUrl, { organizationId });
  const storage = await downloadStorageObjects(config, objects, storageDir);

  const manifest = {
    format: 'stomni-tenant-export',
    format_version: 1,
    created_at: new Date().toISOString(),
    source_git_sha: currentGitSha(),
    source_database: config.safeDatabaseLabel,
    organization_id: organizationId,
    scope: {
      organization_root: true,
      public_tables_with_organization_id: true,
      storage_prefix: `${organizationId}/...`,
      auth_password_hashes_or_sessions: false,
      global_reference_catalogs: false,
      schema: false,
    },
    tables: exported,
    storage: {
      object_count: storage.length,
      total_bytes: storage.reduce((sum, item) => sum + item.size, 0),
      objects: storage,
    },
  };
  writeJson(path.join(outputDir, 'manifest.json'), manifest);

  const totalRows = exported.reduce((sum, item) => sum + item.rows, 0);
  console.log('F9.3 tenant export OK.');
  console.log(`  - organization_id: ${organizationId}`);
  console.log(`  - tablas exportadas: ${exported.length}`);
  console.log(`  - filas: ${totalRows}`);
  console.log(`  - objetos Storage tenant-prefixed: ${storage.length}`);
  console.log(`  - salida: ${outputDir}`);
}

main().catch((error) => {
  console.error(`F9.3 tenant export FAILED: ${error.message}`);
  process.exit(1);
});
