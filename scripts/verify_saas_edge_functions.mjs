import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const configPath = 'supabase/config.toml';
const authGuardPath = 'supabase/functions/_shared/auth_guard.ts';

const edgeFunctions = [
  'consultar-comprobante',
  'consultar-guia-remision',
  'consultar-nota-credito',
  'consultar-proceso-tributario',
  'create_employee',
  'delete_employee',
  'ejecutar-resumen-diario',
  'emitir-comprobante',
  'emitir-guia-remision',
  'emitir-nota-credito',
  'get-persona',
  'procesar-bajas-tributarias',
  'reintentar-comprobante',
  'reintentar-comprobantes-pendientes',
  'reintentar-guia-remision',
  'reintentar-guias-pendientes',
  'reintentar-nota-credito',
  'reintentar-notas-credito-pendientes',
  'reintentar-proceso-tributario',
  'reintentar-procesos-tributarios-pendientes',
  'resolver-resultado-incierto',
];

const read = (relativePath) =>
  fs.readFileSync(path.join(root, relativePath), 'utf8');

function need(errors, source, regex, label) {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
}

function forbid(errors, source, regex, label) {
  if (regex.test(source)) errors.push(`Prohibido: ${label}`);
}

function configBlock(config, slug) {
  const escaped = slug.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return config.match(
    new RegExp(`\\[functions\\.${escaped}\\][\\s\\S]*?(?=\\r?\\n\\[functions\\.|$)`),
  )?.[0] ?? '';
}

function edgePath(slug) {
  return `supabase/functions/${slug}/index.ts`;
}

function loadSources() {
  return {
    config: read(configPath),
    authGuard: read(authGuardPath),
    edges: Object.fromEntries(
      edgeFunctions.map((slug) => [slug, read(edgePath(slug))]),
    ),
  };
}

function hasTenantResourcePrecheck(source, table) {
  const helper = new RegExp(
    `assertTenantResource\\([\\s\\S]{0,320}?['"]${table}['"]`,
    'i',
  );
  if (helper.test(source)) return true;

  // Algunos endpoints tributarios anteriores al helper compartido hacen el
  // precheck de forma explícita sobre el cliente admin ya tenant-scoped.
  const direct = new RegExp(
    `\\.from\\(['"]${table}['"]\\)[\\s\\S]{0,420}?` +
      `\\.eq\\(['"]organization_id['"],\\s*organizationId\\)[\\s\\S]{0,220}?` +
      `\\.eq\\(['"]id['"],\\s*[a-zA-Z0-9_]+\\)`,
    'i',
  );
  return direct.test(source);
}

function verify(s) {
  const errors = [];

  for (const slug of edgeFunctions) {
    const block = configBlock(s.config, slug);
    need(errors, block, /verify_jwt\s*=\s*true/i, `${slug}: verify_jwt=true`);

    const source = s.edges[slug] ?? '';
    need(
      errors,
      source,
      /await\s+(?:requireEmployee|createUserContext)\s*\(\s*req\b/i,
      `${slug}: sesión/tenant resuelto server-side`,
    );
    forbid(
      errors,
      source,
      /SUPABASE_SERVICE_ROLE_KEY|createAdminClient\s*\(/i,
      `${slug}: service_role crudo fuera de auth_guard`,
    );
    forbid(
      errors,
      source,
      /(?:body|payload|params|query)\s*(?:\?\.)?\.?(?:organization_id|organizationId)\b/i,
      `${slug}: tenant tomado del payload/query cliente`,
    );
    forbid(
      errors,
      source,
      /headers\.get\(\s*['"]x-stomni-organization-id['"]\s*\)/i,
      `${slug}: header interno aceptado desde cliente`,
    );
  }

  // El único lugar autorizado para resolver y propagar el tenant de service_role
  // es el guard compartido. Nunca se toma de metadata editable del usuario.
  need(errors, s.authGuard, /\.from\('app_users'\)[\s\S]{0,420}?\.eq\('user_id',\s*authData\.user\.id\)/i, 'auth_guard resuelve app_users por Auth user');
  need(errors, s.authGuard, /organizations!inner\(status\)/i, 'auth_guard valida estado de organización');
  need(errors, s.authGuard, /membership\?\.status\s*!==\s*'active'/i, 'auth_guard exige membership activo');
  need(errors, s.authGuard, /organization\?\.status\s*!==\s*'active'/i, 'auth_guard exige organización activa');
  need(errors, s.authGuard, /\.eq\('organization_id',\s*organizationId\)[\s\S]{0,220}?\.eq\('app_user_id',\s*authData\.user\.id\)/i, 'empleado canónico validado dentro del tenant');
  need(errors, s.authGuard, /createTenantAdminClient\(organizationId\)/i, 'cliente service_role tenant-scoped');
  need(errors, s.authGuard, /url\.searchParams\.set\('organization_id',\s*`eq\.\$\{organizationId\}`\)/i, 'REST service_role inyecta organization_id');
  need(errors, s.authGuard, /headers\.set\(TENANT_HEADER,\s*organizationId\)/i, 'RPC service_role recibe header tenant interno');
  need(errors, s.authGuard, /scopeFiscalStorageWriteUrl\(url,\s*organizationId,\s*method\)/i, 'Storage fiscal se namespacea por tenant');
  forbid(errors, s.authGuard, /raw_user_meta_data|user_metadata[\s\S]{0,120}?organization/i, 'metadata de usuario usada como autoridad tenant');

  // Administración de empleados: app_users es la autoridad de tenant/rol.
  const createEmployee = s.edges.create_employee;
  need(errors, createEmployee, /requireEmployee\(req,\s*\['admin'\]\)/i, 'create_employee exige admin tenant');
  need(errors, createEmployee, /\.from\('app_users'\)[\s\S]{0,260}?\.insert\(\{[\s\S]{0,260}?organization_id:\s*context\.organizationId[\s\S]{0,180}?base_role:\s*accessRole/i, 'create_employee crea app_users del tenant');
  need(errors, createEmployee, /organization_id:\s*context\.organizationId/i, 'create_employee escribe employee tenant explícito');
  need(errors, createEmployee, /app_user_id:\s*newAuthId[\s\S]{0,100}?auth_id:\s*newAuthId/i, 'create_employee enlaza identidad canónica y fallback legacy');
  need(errors, createEmployee, /\.update\(\{\s*status:\s*'disabled'\s*\}\)[\s\S]{0,180}?\.eq\('organization_id',\s*organizationId\)/i, 'create_employee compensación fail-closed');

  const deleteEmployee = s.edges.delete_employee;
  need(errors, deleteEmployee, /requireEmployee\(req,\s*\['admin'\]\)/i, 'delete_employee exige admin tenant');
  need(errors, deleteEmployee, /target\.app_user_id\s*\?\?\s*target\.auth_id/i, 'delete_employee usa app_user_id canónico');
  need(errors, deleteEmployee, /\.from\('app_users'\)[\s\S]{0,240}?\.eq\('organization_id',\s*context\.organizationId\)[\s\S]{0,120}?\.eq\('user_id',\s*targetAccessId\)/i, 'delete_employee membership tenant explícita');
  need(errors, deleteEmployee, /\.eq\('base_role',\s*'admin'\)[\s\S]{0,120}?\.eq\('status',\s*'active'\)/i, 'delete_employee protege último admin desde app_users');
  need(errors, deleteEmployee, /\.update\(\{\s*status:\s*'disabled'\s*\}\)[\s\S]{0,200}?\.eq\('organization_id',\s*context\.organizationId\)/i, 'delete_employee corta acceso antes de borrar');

  // personas_cache es una excepción global explícita del contrato SaaS: sigue
  // requiriendo sesión tenant válida, pero no se convierte en dato empresarial.
  const persona = s.edges['get-persona'];
  need(errors, persona, /await\s+requireEmployee\(req\)/i, 'get-persona exige empleado tenant activo');
  need(errors, persona, /\.from\('personas_cache'\)/i, 'get-persona usa cache global declarada');

  const individualFiscal = [
    ['emitir-comprobante', 'comprobantes_electronicos'],
    ['consultar-comprobante', 'comprobantes_electronicos'],
    ['reintentar-comprobante', 'comprobantes_electronicos'],
    ['emitir-nota-credito', 'notas_credito'],
    ['consultar-nota-credito', 'notas_credito'],
    ['reintentar-nota-credito', 'notas_credito'],
    ['emitir-guia-remision', 'guias_remision'],
    ['consultar-guia-remision', 'guias_remision'],
    ['reintentar-guia-remision', 'guias_remision'],
    ['consultar-proceso-tributario', 'procesos_tributarios'],
    ['reintentar-proceso-tributario', 'procesos_tributarios'],
  ];
  for (const [slug, table] of individualFiscal) {
    if (!hasTenantResourcePrecheck(s.edges[slug], table)) {
      errors.push(`Falta: ${slug}: precheck recurso tenant`);
    }
  }

  const batchFiscal = [
    ['reintentar-comprobantes-pendientes', 'comprobantes_electronicos'],
    ['reintentar-notas-credito-pendientes', 'notas_credito'],
    ['reintentar-guias-pendientes', 'guias_remision'],
  ];
  for (const [slug, table] of batchFiscal) {
    need(
      errors,
      s.edges[slug],
      new RegExp(`from\\(['"]${table}['"]\\)[\\s\\S]{0,620}?\\.eq\\(['"]organization_id['"],\\s*organizationId\\)`, 'i'),
      `${slug}: candidatos filtrados por tenant`,
    );
  }

  for (const slug of [
    'ejecutar-resumen-diario',
    'procesar-bajas-tributarias',
    'reintentar-procesos-tributarios-pendientes',
  ]) {
    need(errors, s.edges[slug], /await\s+createUserContext\(req,\s*\['admin'\]\)/i, `${slug}: operación manual admin tenant`);
  }

  const reconciliation = s.edges['resolver-resultado-incierto'];
  need(errors, reconciliation, /await\s+requireEmployee\(req,\s*\['admin'\]\)/i, 'resolver-resultado-incierto exige admin tenant');
  need(errors, reconciliation, /fiscalTableByType[\s\S]{0,260}?comprobante:\s*'comprobantes_electronicos'[\s\S]{0,220}?proceso:\s*'procesos_tributarios'/i, 'resolver-resultado-incierto mapea tipos a tablas tenant');
  need(errors, reconciliation, /await\s+assertTenantResource\([\s\S]{0,220}?context\.organizationId[\s\S]{0,160}?documentoId/i, 'resolver-resultado-incierto precheck tenant');
  need(errors, reconciliation, /\.rpc\(\s*['"]resolver_resultado_incierto_v1['"]/i, 'resolver-resultado-incierto usa RPC endurecido');

  return errors;
}

function selfTest() {
  const errors = [];
  const goodConfig = '[functions.demo]\r\nverify_jwt = true\r\n';
  need(errors, configBlock(goodConfig, 'demo'), /verify_jwt\s*=\s*true/i, 'config válida');
  if (errors.length) {
    console.error('SaaS Edge self-test FAILED: contrato válido rechazado');
    process.exit(1);
  }

  const badConfig = '[functions.demo]\nverify_jwt = false\n';
  const badErrors = [];
  need(badErrors, configBlock(badConfig, 'demo'), /verify_jwt\s*=\s*true/i, 'JWT');
  forbid(badErrors, "const organizationId = body.organization_id", /(?:body|payload|params|query)\s*(?:\?\.)?\.?(?:organization_id|organizationId)\b/i, 'tenant cliente');
  forbid(badErrors, "Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')", /SUPABASE_SERVICE_ROLE_KEY/i, 'service role crudo');
  if (badErrors.length !== 3) {
    console.error('SaaS Edge self-test FAILED: no detectó contratos inseguros');
    process.exit(1);
  }

  const internalHeaderErrors = [];
  forbid(internalHeaderErrors, "req.headers.get('x-stomni-organization-id')", /headers\.get\(\s*['"]x-stomni-organization-id['"]\s*\)/i, 'header tenant cliente');
  if (internalHeaderErrors.length !== 1) {
    console.error('SaaS Edge self-test FAILED: no detectó header tenant falsificable');
    process.exit(1);
  }

  const directPrecheck = `context.admin.from('procesos_tributarios').select('id').eq('organization_id', organizationId).eq('id', procesoId)`;
  if (!hasTenantResourcePrecheck(directPrecheck, 'procesos_tributarios')) {
    console.error('SaaS Edge self-test FAILED: no reconoce precheck tenant explícito seguro');
    process.exit(1);
  }

  console.log('SaaS Edge self-test OK (6 casos).');
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify(loadSources());
if (errors.length) {
  console.error('SaaS Edge gate FAILED:');
  errors.forEach((error) => console.error(`  - ${error}`));
  process.exit(1);
}

console.log('SaaS Edge gate OK.');
console.log(`  - ${edgeFunctions.length} Edge Functions con verify_jwt=true`);
console.log('  - tenant derivado desde app_users/organizations');
console.log('  - service_role encapsulado por cliente tenant-scoped');
console.log('  - administración de empleados crea/elimina app_users por tenant');
console.log('  - fiscal individual/batch/reconciliación y Storage tenant-aware');
console.log('  - personas_cache conservada como excepción global autenticada');
