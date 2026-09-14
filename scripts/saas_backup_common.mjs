import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { execFileSync } from 'node:child_process';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const LOOPBACK_HOSTS = new Set(['127.0.0.1', 'localhost', '[::1]', '::1']);

export function fail(message) {
  throw new Error(message);
}

export function ensure(condition, message) {
  if (!condition) fail(message);
}

export function parseEnvOutput(raw) {
  const values = {};
  for (const line of raw.split(/\r?\n/)) {
    const match = line.trim().match(/^([A-Z0-9_]+)=(?:"([^"]*)"|'([^']*)'|(.*))$/);
    if (match) values[match[1]] = match[2] ?? match[3] ?? match[4] ?? '';
  }
  return values;
}

function assertLoopbackUrl(raw, { protocols, label }) {
  let url;
  try {
    url = new URL(raw);
  } catch {
    fail(`${label} no es una URL válida.`);
  }
  ensure(protocols.has(url.protocol), `${label} usa protocolo no permitido: ${url.protocol}`);
  ensure(LOOPBACK_HOSTS.has(url.hostname), `${label} debe apuntar sólo a loopback local; recibido ${url.hostname}`);
  return url;
}

export function loadLocalSupabaseConfig({ requireServiceRole = true } = {}) {
  const direct = {
    DB_URL: process.env.SUPABASE_DB_URL ?? process.env.DB_URL,
    API_URL: process.env.SUPABASE_URL ?? process.env.API_URL,
    SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY ?? process.env.SERVICE_ROLE_KEY,
  };
  let status = {};
  if (!direct.DB_URL || !direct.API_URL || (requireServiceRole && !direct.SERVICE_ROLE_KEY)) {
    try {
      status = parseEnvOutput(execFileSync('supabase', ['status', '-o', 'env'], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      }));
    } catch (error) {
      fail(`No se pudo leer Supabase local. Ejecuta "supabase start". ${error.message}`);
    }
  }

  const dbUrlRaw = direct.DB_URL ?? status.DB_URL;
  const apiUrlRaw = direct.API_URL ?? status.API_URL;
  const serviceRoleKey = direct.SERVICE_ROLE_KEY ?? status.SERVICE_ROLE_KEY;
  ensure(dbUrlRaw, 'Falta DB_URL de Supabase local.');
  ensure(apiUrlRaw, 'Falta API_URL de Supabase local.');
  if (requireServiceRole) ensure(serviceRoleKey, 'Falta SERVICE_ROLE_KEY de Supabase local.');

  const dbUrl = assertLoopbackUrl(dbUrlRaw, {
    protocols: new Set(['postgres:', 'postgresql:']),
    label: 'DB_URL',
  });
  const apiUrl = assertLoopbackUrl(apiUrlRaw, {
    protocols: new Set(['http:']),
    label: 'API_URL',
  });

  return {
    dbUrl: dbUrl.toString(),
    apiUrl: apiUrl.origin,
    serviceRoleKey,
    safeDatabaseLabel: `${dbUrl.protocol}//${dbUrl.hostname}:${dbUrl.port || '5432'}/${dbUrl.pathname.replace(/^\//, '')}`,
  };
}

export function commandText(command, args, options = {}) {
  return execFileSync(command, args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    maxBuffer: 64 * 1024 * 1024,
    ...options,
  }).trim();
}

export function runCommand(command, args, options = {}) {
  execFileSync(command, args, {
    stdio: 'inherit',
    ...options,
  });
}

export function toolVersion(command) {
  try {
    return commandText(command, ['--version']);
  } catch (error) {
    fail(`${command} no está disponible en PATH. ${error.message}`);
  }
}

export function psql(dbUrl, sql) {
  try {
    return commandText('psql', [
      '--dbname', dbUrl,
      '-X',
      '-v', 'ON_ERROR_STOP=1',
      '-A',
      '-t',
      '-c', sql,
    ]);
  } catch (error) {
    fail(`psql falló: ${error.stderr?.toString?.() ?? error.message}`);
  }
}

export function sqlLiteral(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

export function sqlIdentifier(value) {
  ensure(/^[A-Za-z_][A-Za-z0-9_]*$/.test(value), `Identificador SQL inesperado: ${value}`);
  return `"${value.replaceAll('"', '""')}"`;
}

export function sha256File(filePath) {
  const hash = crypto.createHash('sha256');
  const data = fs.readFileSync(filePath);
  hash.update(data);
  return hash.digest('hex');
}

export function sha256Text(text) {
  return crypto.createHash('sha256').update(text).digest('hex');
}

export function fileSize(filePath) {
  return fs.statSync(filePath).size;
}

export function timestampId() {
  return new Date().toISOString().replace(/[:.]/g, '-');
}

export function currentGitSha() {
  try {
    return commandText('git', ['rev-parse', 'HEAD']);
  } catch {
    return null;
  }
}

export function gitWorkingTreeDirty() {
  try {
    return commandText('git', ['status', '--porcelain']).length > 0;
  } catch {
    return null;
  }
}

export function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

export function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

export function listBaseTables(dbUrl, schema) {
  const raw = psql(dbUrl, `
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema=${sqlLiteral(schema)}
      AND table_type='BASE TABLE'
    ORDER BY table_name;
  `);
  return raw ? raw.split(/\r?\n/).map((x) => x.trim()).filter(Boolean) : [];
}

export function listPublicTables(dbUrl) {
  return listBaseTables(dbUrl, 'public');
}

export function listTenantOwnedTables(dbUrl) {
  const raw = psql(dbUrl, `
    SELECT DISTINCT table_name
    FROM information_schema.columns
    WHERE table_schema='public'
      AND column_name='organization_id'
    ORDER BY table_name;
  `);
  return raw ? raw.split(/\r?\n/).map((x) => x.trim()).filter(Boolean) : [];
}

export function fingerprintTable(dbUrl, schema, table, whereSql = '') {
  const schemaIdent = sqlIdentifier(schema);
  const tableIdent = sqlIdentifier(table);
  const where = whereSql ? `WHERE ${whereSql}` : '';
  const raw = psql(dbUrl, `
    SELECT count(*)::text || E'\\t' ||
      COALESCE(md5(string_agg(row_hash,'' ORDER BY row_hash)),md5(''))
    FROM (
      SELECT md5(to_jsonb(t)::text) AS row_hash
      FROM ${schemaIdent}.${tableIdent} AS t
      ${where}
    ) AS q;
  `);
  const [countRaw, hash] = raw.split('\t');
  return { count: Number(countRaw), hash };
}

export function fingerprintTenantTable(dbUrl, table, organizationId) {
  return fingerprintTable(
    dbUrl,
    'public',
    table,
    `organization_id=${sqlLiteral(organizationId)}::uuid`,
  );
}

export function collectRecoveryFingerprints(dbUrl) {
  const publicTables = listPublicTables(dbUrl);
  const publicFingerprints = {};
  for (const table of publicTables) {
    publicFingerprints[table] = fingerprintTable(dbUrl, 'public', table);
  }
  return {
    public: publicFingerprints,
    auth_users: fingerprintTable(dbUrl, 'auth', 'users'),
    auth_identities: fingerprintTable(dbUrl, 'auth', 'identities'),
  };
}

export function listStorageObjects(dbUrl, { organizationId = null } = {}) {
  const where = organizationId
    ? `WHERE name=${sqlLiteral(organizationId)} OR name LIKE ${sqlLiteral(`${organizationId}/%`)}`
    : '';
  const raw = psql(dbUrl, `
    SELECT json_build_object(
      'bucket_id',bucket_id,
      'name',name,
      'mimetype',COALESCE(metadata->>'mimetype','application/octet-stream')
    )::text
    FROM storage.objects
    ${where}
    ORDER BY bucket_id,name;
  `);
  if (!raw) return [];
  return raw.split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line));
}

export function listStorageBuckets(dbUrl) {
  const raw = psql(dbUrl, `
    SELECT json_build_object('id',id,'public',public)::text
    FROM storage.buckets
    ORDER BY id;
  `);
  return raw ? raw.split(/\r?\n/).filter(Boolean).map((line) => JSON.parse(line)) : [];
}

function encodeStoragePath(name) {
  return name.split('/').map((part) => encodeURIComponent(part)).join('/');
}

function storageObjectUrl(config, object) {
  return `${config.apiUrl}/storage/v1/object/${encodeURIComponent(object.bucket_id)}/${encodeStoragePath(object.name)}`;
}

function storageArtifactName(object) {
  return `${sha256Text(`${object.bucket_id}\0${object.name}`)}.bin`;
}

export async function downloadStorageObjects(config, objects, storageDir) {
  fs.mkdirSync(storageDir, { recursive: true });
  const artifacts = [];
  for (const object of objects) {
    const response = await fetch(storageObjectUrl(config, object), {
      headers: {
        apikey: config.serviceRoleKey,
        Authorization: `Bearer ${config.serviceRoleKey}`,
      },
    });
    ensure(response.ok, `Storage GET ${object.bucket_id}/${object.name} falló HTTP ${response.status}.`);
    ensure(response.body, `Storage GET ${object.bucket_id}/${object.name} no devolvió body.`);
    const artifact = storageArtifactName(object);
    const absolute = path.join(storageDir, artifact);
    await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(absolute));
    artifacts.push({
      ...object,
      artifact,
      size: fileSize(absolute),
      sha256: sha256File(absolute),
    });
  }
  return artifacts;
}

export function verifyLocalStorageArtifacts(artifacts, storageDir) {
  for (const object of artifacts) {
    const absolute = path.join(storageDir, object.artifact);
    ensure(fs.existsSync(absolute), `Falta artefacto Storage ${object.artifact}.`);
    ensure(fileSize(absolute) === object.size, `Tamaño inválido en ${object.artifact}.`);
    ensure(sha256File(absolute) === object.sha256, `SHA-256 inválido en ${object.artifact}.`);
  }
}

export async function uploadStorageArtifacts(config, artifacts, storageDir) {
  verifyLocalStorageArtifacts(artifacts, storageDir);
  for (const object of artifacts) {
    const absolute = path.join(storageDir, object.artifact);
    const response = await fetch(storageObjectUrl(config, object), {
      method: 'POST',
      headers: {
        apikey: config.serviceRoleKey,
        Authorization: `Bearer ${config.serviceRoleKey}`,
        'Content-Type': object.mimetype || 'application/octet-stream',
        'x-upsert': 'true',
        'Content-Length': String(fileSize(absolute)),
      },
      body: fs.createReadStream(absolute),
      duplex: 'half',
    });
    const body = await response.text();
    ensure(response.ok, `Storage restore ${object.bucket_id}/${object.name} falló HTTP ${response.status}: ${body.slice(0, 300)}`);
  }
}

export async function remoteStorageHash(config, object) {
  const response = await fetch(storageObjectUrl(config, object), {
    headers: {
      apikey: config.serviceRoleKey,
      Authorization: `Bearer ${config.serviceRoleKey}`,
    },
  });
  ensure(response.ok && response.body, `No se pudo verificar Storage ${object.bucket_id}/${object.name}.`);
  const hash = crypto.createHash('sha256');
  let size = 0;
  for await (const chunk of Readable.fromWeb(response.body)) {
    hash.update(chunk);
    size += chunk.length;
  }
  return { sha256: hash.digest('hex'), size };
}
