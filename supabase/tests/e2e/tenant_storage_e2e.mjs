import crypto from 'node:crypto';

const PIXEL_PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/dKsAAAAASUVORK5CYII=',
  'base64',
);
const FISCAL_PDF = Buffer.from('%PDF-1.4\n% StOmni local test fixture only\n%%EOF\n', 'utf8');
const DENIED_IMAGE = Buffer.from('cross-tenant-overwrite-must-never-persist', 'utf8');

export const STORAGE_SCENARIOS = Object.freeze([
  'T11-01-tenant-owned-product-uploads',
  'T11-02-owned-product-listing-and-authenticated-read',
  'T11-03-foreign-product-listing-blocked-public-read-documented',
  'T11-04-foreign-product-insert-update-delete-blocked',
  'T11-05-tenant-logo-writes-and-foreign-overwrite-blocked',
  'T11-06-private-fiscal-artifact-access-blocked',
  'T11-07-private-fiscal-signing-and-spoofing-blocked',
  'T11-08-public-assets-remain-public-by-design',
  'T11-09-private-signed-url-expiry-enforced',
]);

function ensure(condition, message) {
  if (!condition) throw new Error(`T11 Storage: ${message}`);
}

function logScenario(id, summary) {
  console.log(`[${id}] ${summary}`);
}

function storageUrl(config, route, bucket, path = '') {
  // apiUrl is guaranteed to be HTTP loopback by the parent E2E runner.
  const encodedPath = path.split('/').map(encodeURIComponent).join('/');
  return `${config.apiUrl}/storage/v1/${route}/${encodeURIComponent(bucket)}${path ? `/${encodedPath}` : ''}`;
}

async function request(config, token, method, url, { body, contentType, headers = {} } = {}) {
  const reqHeaders = {
    apikey: config.anonKey,
    Authorization: `Bearer ${token}`,
    ...headers,
  };
  if (contentType) reqHeaders['Content-Type'] = contentType;
  const res = await fetch(url, { method, headers: reqHeaders, body });
  const bytes = Buffer.from(await res.arrayBuffer());
  let data = null;
  if (res.headers.get('content-type')?.includes('json')) {
    try { data = JSON.parse(bytes.toString('utf8')); } catch { /* malformed response fails checks */ }
  }
  return { ok: res.ok, status: res.status, bytes, data };
}

async function upload(config, token, bucket, path, bytes, { upsert = false, method = 'POST' } = {}) {
  return request(config, token, method, storageUrl(config, 'object', bucket, path), {
    body: bytes,
    contentType: 'image/png',
    headers: upsert ? { 'x-upsert': 'true' } : {},
  });
}

async function list(config, token, bucket, prefix) {
  return request(config, token, 'POST', storageUrl(config, 'object/list', bucket), {
    body: JSON.stringify({ prefix, limit: 100, offset: 0, sortBy: { column: 'name', order: 'asc' } }),
    contentType: 'application/json',
  });
}

async function download(config, token, bucket, path, publicAccess = false) {
  return request(
    config,
    token,
    'GET',
    storageUrl(config, publicAccess ? 'object/public' : 'object/authenticated', bucket, path),
  );
}

async function deleteObjects(config, token, bucket, paths) {
  return request(config, token, 'DELETE', storageUrl(config, 'object', bucket), {
    body: JSON.stringify({ prefixes: paths }),
    contentType: 'application/json',
  });
}

async function assertByteExact(config, token, bucket, path, expected, { publicAccess = false } = {}) {
  const res = await download(config, token, bucket, path, publicAccess);
  ensure(res.ok, `falló descarga de fixture en bucket ${bucket} (${res.status}).`);
  ensure(res.bytes.equals(expected), `el contenido del fixture fue alterado: ${bucket}.`);
}

function containsFile(response, filename) {
  return response.ok && Array.isArray(response.data) &&
    response.data.some((entry) => entry?.name === filename);
}

export async function verifyTenantStorage(config, a, b, runId) {
  ensure(a.organizationId !== b.organizationId, 'fixtures A/B no son independientes.');
  const filename = `t11-${crypto.createHash('sha256').update(runId).digest('hex').slice(0, 16)}.png`;
  const aProductPath = `${a.organizationId}/products/${filename}`;
  const bProductPath = `${b.organizationId}/products/${filename}`;

  const [uploadA, uploadB] = await Promise.all([
    upload(config, a.accessToken, 'imagenes_productos', aProductPath, PIXEL_PNG),
    upload(config, b.accessToken, 'imagenes_productos', bProductPath, PIXEL_PNG),
  ]);
  ensure(uploadA.ok && uploadB.ok, `uploads legítimos fallaron (A=${uploadA.status}, B=${uploadB.status}).`);
  logScenario(STORAGE_SCENARIOS[0], 'cargas de productos con JWT propios y namespace UUID');

  const [ownA, ownB, ownReadA] = await Promise.all([
    list(config, a.accessToken, 'imagenes_productos', `${a.organizationId}/products`),
    list(config, b.accessToken, 'imagenes_productos', `${b.organizationId}/products`),
    download(config, a.accessToken, 'imagenes_productos', aProductPath),
  ]);
  ensure(containsFile(ownA, filename) && containsFile(ownB, filename), 'el listado propio no mostró el fixture.');
  ensure(ownReadA.ok && ownReadA.bytes.equals(PIXEL_PNG), 'lectura autenticada propia falló.');
  logScenario(STORAGE_SCENARIOS[1], 'listado y lectura autenticada de assets propios');

  const [foreignList, foreignRead] = await Promise.all([
    list(config, a.accessToken, 'imagenes_productos', `${b.organizationId}/products`),
    download(config, a.accessToken, 'imagenes_productos', bProductPath),
  ]);
  ensure(!containsFile(foreignList, filename), 'ORG_A enumeró una imagen ORG_B.');
  // imagenes_productos is deliberately public. Supabase can serve public
  // bytes even via /object/authenticated; SELECT RLS protects listing, not
  // the confidentiality of a URL-known object in a public bucket.
  if (foreignRead.ok) {
    ensure(foreignRead.bytes.equals(PIXEL_PNG),
      'un asset público conocido devolvió contenido distinto al fixture.');
  }
  logScenario(STORAGE_SCENARIOS[2], 'listado B bloqueado; descarga de asset público tratada como pública');

  const [foreignInsert, foreignOverwrite] = await Promise.all([
    upload(config, a.accessToken, 'imagenes_productos', `${b.organizationId}/products/foreign-${filename}`, DENIED_IMAGE),
    upload(config, a.accessToken, 'imagenes_productos', bProductPath, DENIED_IMAGE, { method: 'PUT' }),
  ]);
  ensure(!foreignInsert.ok && !foreignOverwrite.ok, 'ORG_A pudo escribir en el namespace ORG_B.');
  await deleteObjects(config, a.accessToken, 'imagenes_productos', [bProductPath]);
  // Deletion may be 200 with [] when RLS silently filters out foreign objects.
  await assertByteExact(config, b.accessToken, 'imagenes_productos', bProductPath, PIXEL_PNG, { publicAccess: true });
  logScenario(STORAGE_SCENARIOS[3], 'INSERT, UPDATE y DELETE A->B no modifican el objeto B');

  const aLogoPath = `${a.organizationId}/logos/${filename}`;
  const bLogoPath = `${b.organizationId}/logos/${filename}`;
  const [logoA, logoB] = await Promise.all([
    upload(config, a.accessToken, 'logos', aLogoPath, PIXEL_PNG),
    upload(config, b.accessToken, 'logos', bLogoPath, PIXEL_PNG),
  ]);
  ensure(logoA.ok && logoB.ok, `logos propios fallaron (A=${logoA.status}, B=${logoB.status}).`);
  const [logoSpoof, logoOverwrite] = await Promise.all([
    upload(config, a.accessToken, 'logos', `${b.organizationId}/logos/foreign-${filename}`, DENIED_IMAGE),
    upload(config, a.accessToken, 'logos', bLogoPath, DENIED_IMAGE, { method: 'PUT' }),
  ]);
  ensure(!logoSpoof.ok && !logoOverwrite.ok, 'ORG_A pudo modificar logos de ORG_B.');
  await deleteObjects(config, a.accessToken, 'logos', [bLogoPath]);
  await assertByteExact(config, b.accessToken, 'logos', bLogoPath, PIXEL_PNG, { publicAccess: true });
  logScenario(STORAGE_SCENARIOS[4], 'logos propios válidos; namespace ajeno no modificable');

  const fiscalPath = `${b.organizationId}/t11/${filename}.pdf`;
  const seedFiscal = await request(config, config.serviceRoleKey, 'POST',
    storageUrl(config, 'object', 'comprobantes-electronicos', fiscalPath),
    { body: FISCAL_PDF, contentType: 'application/pdf' });
  ensure(seedFiscal.ok, `no se pudo sembrar fixture fiscal local con service-role (${seedFiscal.status}).`);
  await assertByteExact(config, config.serviceRoleKey, 'comprobantes-electronicos', fiscalPath, FISCAL_PDF);
  const [privateRead, publicRead, privateList] = await Promise.all([
    download(config, a.accessToken, 'comprobantes-electronicos', fiscalPath),
    download(config, config.anonKey, 'comprobantes-electronicos', fiscalPath, true),
    list(config, a.accessToken, 'comprobantes-electronicos', `${b.organizationId}/t11`),
  ]);
  ensure(!privateRead.ok && !publicRead.ok && !containsFile(privateList, `${filename}.pdf`),
    'un artefacto fiscal privado quedó visible a ORG_A o público.');
  logScenario(STORAGE_SCENARIOS[5], 'bucket fiscal privado incluso con ruta B conocida');

  const [rogueFiscalUpload, signedUrl] = await Promise.all([
    request(config, a.accessToken, 'POST', storageUrl(config, 'object', 'comprobantes-electronicos',
      `${b.organizationId}/t11/foreign-${filename}.pdf`), { body: FISCAL_PDF, contentType: 'application/pdf' }),
    request(config, a.accessToken, 'POST', storageUrl(config, 'object/sign',
      'comprobantes-electronicos', fiscalPath),
      { body: JSON.stringify({ expiresIn: 60 }), contentType: 'application/json' }),
  ]);
  ensure(!rogueFiscalUpload.ok && !signedUrl.ok,
    'ORG_A pudo crear un artefacto fiscal B o firmar acceso a su contenido.');
  logScenario(STORAGE_SCENARIOS[6], 'escritura fiscal falsa y generación de URL firmada B denegadas');

  await assertByteExact(config, a.accessToken, 'imagenes_productos', bProductPath,
    PIXEL_PNG, { publicAccess: true });
  await assertByteExact(config, a.accessToken, 'logos', bLogoPath,
    PIXEL_PNG, { publicAccess: true });
  logScenario(STORAGE_SCENARIOS[7], 'lectura URL pública permitida intencionalmente; no implica acceso privado');

  // Only the local test runner's service-role key may generate a signed URL
  // for a private fiscal object. Never store the URL or token in CI evidence.
  const privilegedSignature = await request(
    config, config.serviceRoleKey, 'POST',
    storageUrl(config, 'object/sign', 'comprobantes-electronicos', fiscalPath),
    { body: JSON.stringify({ expiresIn: 2 }), contentType: 'application/json' },
  );
  ensure(privilegedSignature.ok, `la firma fiscal local legítima falló HTTP ${privilegedSignature.status}.`);
  const signedRelative = privilegedSignature.data?.signedURL ?? privilegedSignature.data?.signedUrl;
  ensure(typeof signedRelative === 'string' && signedRelative.length > 0,
    'firma Storage no devolvió URL');
  const signedPath = signedRelative.startsWith('/object/')
    ? `/storage/v1${signedRelative}`
    : signedRelative;
  const signedTarget = new URL(signedPath, `${config.apiUrl}/storage/v1/`);
  ensure(signedTarget.origin === new URL(config.apiUrl).origin &&
      signedTarget.pathname.startsWith('/storage/v1/object/sign/comprobantes-electronicos/'),
    'URL firmada contiene host o ruta inesperados');
  const validSignedGet = await request(config, config.anonKey, 'GET', signedTarget.toString());
  ensure(validSignedGet.ok && validSignedGet.bytes.equals(FISCAL_PDF),
    `URL firmada fiscal no sirvió bytes correctos antes de vencer (HTTP ${validSignedGet.status}).`);
  await new Promise((resolve) => setTimeout(resolve, 5500));
  const expiredSignedGet = await request(config, config.anonKey, 'GET', signedTarget.toString());
  ensure(!expiredSignedGet.ok,
    'URL firmada fiscal sigue autorizando la descarga después de expiración');
  logScenario(STORAGE_SCENARIOS[8], 'URL temporal fiscal válida inicialmente y rechazada tras vencimiento');

  return { count: STORAGE_SCENARIOS.length, bucketCount: 3, containsSecrets: false };
}
