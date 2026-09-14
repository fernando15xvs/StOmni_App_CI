import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const files = {
  uuidCompat: 'supabase/migrations/20260908022900_saas_uuid_min_compat.sql',
  schema: 'supabase/migrations/20260908023000_saas_fiscal_tenant_schema.sql',
  uuidCleanup: 'supabase/migrations/20260908023010_saas_uuid_min_compat_cleanup.sql',
  rpc: 'supabase/migrations/20260908024000_saas_fiscal_rpc_guards.sql',
  internal: 'supabase/migrations/20260908024500_saas_fiscal_internal_rpc_scope.sql',
  identity: 'supabase/migrations/20260908024550_saas_fiscal_app_user_identity.sql',
  storage: 'supabase/migrations/20260908024600_saas_fiscal_storage_paths.sql',
  defaults: 'supabase/migrations/20260908024700_saas_new_tenant_fiscal_default.sql',
  authGuard: 'supabase/functions/_shared/auth_guard.ts',
  emitirComp: 'supabase/functions/emitir-comprobante/index.ts',
  consultarComp: 'supabase/functions/consultar-comprobante/index.ts',
  reintentarComp: 'supabase/functions/reintentar-comprobante/index.ts',
  batchComp: 'supabase/functions/reintentar-comprobantes-pendientes/index.ts',
  emitirNc: 'supabase/functions/emitir-nota-credito/index.ts',
  consultarNc: 'supabase/functions/consultar-nota-credito/index.ts',
  reintentarNc: 'supabase/functions/reintentar-nota-credito/index.ts',
  batchNc: 'supabase/functions/reintentar-notas-credito-pendientes/index.ts',
  emitirGre: 'supabase/functions/emitir-guia-remision/index.ts',
  consultarGre: 'supabase/functions/consultar-guia-remision/index.ts',
  reintentarGre: 'supabase/functions/reintentar-guia-remision/index.ts',
  batchGre: 'supabase/functions/reintentar-guias-pendientes/index.ts',
  consultarProceso: 'supabase/functions/consultar-proceso-tributario/index.ts',
  reintentarProceso: 'supabase/functions/reintentar-proceso-tributario/index.ts',
};

const currentRuntimeRpcs = [
  'eliminar_borrador_guia_v1',
  'guardar_guia_remision_v4',
  'obtener_disponibilidad_nota_credito_v2',
  'crear_nota_credito_with_units_v3',
  'solicitar_baja_tributaria_v1',
];
const closedLegacyFallbackRpcs = [
  'obtener_disponibilidad_nota_credito',
  'crear_nota_credito_v1',
];

const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8');
const sources = () => Object.fromEntries(
  Object.entries(files).map(([key, value]) => [key, read(value)]),
);

function need(errors, source, regex, label) {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
}

function forbid(errors, source, regex, label) {
  if (regex.test(source)) errors.push(`Prohibido: ${label}`);
}

function dollarBlock(source, tag) {
  const escaped = tag.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return source.match(new RegExp(`DO \\$${escaped}\\$[\\s\\S]*?\\$${escaped}\\$;`, 'i'))?.[0] ?? '';
}

function hasTenantResourcePrecheck(source, table) {
  const helper = new RegExp(
    `assertTenantResource\\([\\s\\S]{0,320}?['"]${table}['"]`,
    'i',
  );
  if (helper.test(source)) return true;
  return new RegExp(
    `\\.from\\(['"]${table}['"]\\)[\\s\\S]{0,460}?` +
      `\\.eq\\(['"]organization_id['"],\\s*organizationId\\)[\\s\\S]{0,240}?` +
      `\\.eq\\(['"]id['"],\\s*[a-zA-Z0-9_]+\\)`,
    'i',
  ).test(source);
}

function verify(s) {
  const errors = [];
  const tenantTables = [
    'series_comprobantes',
    'comprobantes_electronicos',
    'facturacion_intentos',
    'notas_credito',
    'notas_credito_detalles',
    'notas_credito_intentos',
    'gre_transportistas',
    'gre_transportistas_agencias',
    'gre_conductores',
    'gre_vehiculos',
    'guias_remision',
    'guias_remision_detalles',
    'guias_remision_intentos',
    'solicitudes_baja_tributaria',
    'procesos_tributarios',
    'procesos_tributarios_detalles',
    'procesos_tributarios_intentos',
    'correlativos_procesos_tributarios',
    'documentos_tributarios_reconciliaciones',
  ];

  const rlsBlock = dollarBlock(s.schema, 'rls');
  const triggerBlock = dollarBlock(s.schema, 'triggers');
  need(errors, rlsBlock, /ENABLE ROW LEVEL SECURITY/i, 'bloque RLS fiscal');
  need(errors, triggerBlock, /private\.enforce_row_organization_id\(\)/i, 'bloque triggers tenant');

  for (const table of tenantTables) {
    need(errors, s.schema, new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ADD COLUMN\\s+organization_id\\s+uuid`, 'i'), `${table}.organization_id`);
    need(errors, s.schema, new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ALTER COLUMN\\s+organization_id\\s+SET NOT NULL`, 'i'), `${table}.organization_id NOT NULL`);
    need(errors, rlsBlock, new RegExp(`['"]${table}['"]`, 'i'), `${table} incluido en RLS dinámico`);
    need(errors, triggerBlock, new RegExp(`['"]${table}['"]`, 'i'), `${table} incluido en enforcement dinámico`);
  }

  need(errors, s.schema, /series_comprobantes_unique[\s\S]{0,180}?UNIQUE\s*\(\s*organization_id\s*,\s*tipo_documento_sunat\s*,\s*serie\s*\)/i, 'series únicas por tenant');
  need(errors, s.schema, /comprobantes_electronicos_request_unique[\s\S]{0,180}?UNIQUE\s*\(\s*organization_id\s*,\s*request_id\s*\)/i, 'request comprobante por tenant');
  need(errors, s.schema, /comprobantes_electronicos_unique[\s\S]{0,220}?UNIQUE\s*\(\s*organization_id\s*,\s*tipo_documento_sunat\s*,\s*serie\s*,\s*correlativo\s*\)/i, 'numeración comprobante por tenant');
  need(errors, s.schema, /notas_credito_request_id_key[\s\S]{0,180}?UNIQUE\s*\(\s*organization_id\s*,\s*request_id\s*\)/i, 'request NC por tenant');
  need(errors, s.schema, /guias_remision_request_id_key[\s\S]{0,180}?UNIQUE\s*\(\s*organization_id\s*,\s*request_id\s*\)/i, 'request GRE por tenant');
  need(errors, s.schema, /procesos_tributarios_request_id_key[\s\S]{0,180}?UNIQUE\s*\(\s*organization_id\s*,\s*request_id\s*\)/i, 'request proceso por tenant');
  need(errors, s.schema, /PRIMARY KEY\s*\(\s*organization_id\s*,\s*tipo_proceso\s*,\s*fecha_referencia\s*\)/i, 'correlativos tributarios por tenant');

  const compositeFks = [
    ['comprobantes_electronicos_venta_id_fkey', 'ventas', 'venta_id'],
    ['facturacion_intentos_comprobante_id_fkey', 'comprobantes_electronicos', 'comprobante_id'],
    ['notas_credito_comprobante_id_fkey', 'comprobantes_electronicos', 'comprobante_id'],
    ['notas_credito_venta_id_fkey', 'ventas', 'venta_id'],
    ['notas_credito_detalles_nota_credito_id_fkey', 'notas_credito', 'nota_credito_id'],
    ['guias_remision_venta_id_fkey', 'ventas', 'venta_id'],
    ['guias_remision_transferencia_id_fkey', 'transferencias_stock', 'transferencia_id'],
    ['guias_remision_detalles_guia_id_fkey', 'guias_remision', 'guia_id'],
    ['procesos_tributarios_detalles_proceso_id_fkey', 'procesos_tributarios', 'proceso_id'],
  ];
  for (const [constraint, parent, column] of compositeFks) {
    need(errors, s.schema, new RegExp(`${constraint}[\\s\\S]{0,280}?FOREIGN KEY\\s*\\(\\s*organization_id\\s*,\\s*${column}\\s*\\)[\\s\\S]{0,220}?REFERENCES\\s+public\\.${parent}\\s*\\(\\s*organization_id\\s*,\\s*id\\s*\\)`, 'i'), `${constraint} tenant-qualified`);
  }

  need(errors, s.uuidCompat, /CREATE AGGREGATE\s+public\.min\s*\(\s*uuid\s*\)/i, 'compatibilidad temporal min(uuid)');
  need(errors, s.uuidCleanup, /DROP AGGREGATE IF EXISTS\s+public\.min\s*\(\s*uuid\s*\)/i, 'limpieza min(uuid)');
  need(errors, s.uuidCleanup, /DROP FUNCTION IF EXISTS\s+private\._uuid_min_compat\s*\(\s*uuid\s*,\s*uuid\s*\)/i, 'limpieza helper UUID');

  for (const helper of [
    'private.assert_fiscal_comprobante_in_current_organization',
    'private.assert_fiscal_nota_in_current_organization',
    'private.assert_fiscal_guia_in_current_organization',
    'private.assert_credit_note_payload_in_current_organization',
    'private.assert_gre_payload_in_current_organization',
  ]) {
    need(errors, s.rpc, new RegExp(`CREATE OR REPLACE FUNCTION\\s+${helper.replaceAll('.', '\\.')}`, 'i'), helper);
  }

  need(errors, s.rpc, /CREATE OR REPLACE FUNCTION\s+public\.listar_documentos_electronicos_v1[\s\S]*?WHERE ce\.organization_id=v_org/i, 'listado fiscal tenant-aware');
  need(errors, s.rpc, /WHERE nc\.organization_id=v_org/i, 'listado NC tenant-aware');
  need(errors, s.rpc, /WHERE g\.organization_id=v_org/i, 'listado GRE tenant-aware');

  const saleReopen = dollarBlock(s.rpc, 'reopen_sales_entrypoints');
  need(errors, saleReopen, /Electronic invoicing is temporarily disabled until fiscal tenant rollout F3\.7/i, 'reopen reconoce bloqueo legacy exacto');
  need(errors, saleReopen, /v_new\s+text:=E'[\s\S]{0,260}?v_tipo NOT IN \(''ticket_interno'',''boleta'',''factura''\)/i, 'venta v4 permite tipos fiscales');
  need(errors, saleReopen, /EXECUTE replace\(v_def,v_old,v_new\)/i, 'reopen reemplaza bloqueo temporal');
  need(errors, s.rpc, /F3\.7 sale fiscal patch mismatch: series select/i, 'process_sale_v3 scopea serie fiscal');
  need(errors, s.rpc, /F3\.7 sale fiscal patch mismatch: replay document/i, 'process_sale_v3 scopea replay fiscal');

  need(errors, s.internal, /CREATE OR REPLACE FUNCTION\s+private\.service_request_organization_id\(\)/i, 'tenant service desde request.headers');
  need(errors, s.internal, /x-stomni-organization-id/i, 'header interno tenant');
  need(errors, s.internal, /CREATE OR REPLACE FUNCTION\s+private\.require_service_organization_id\(\)/i, 'tenant service validado');
  need(errors, s.internal, /organization_id,(?:\s|\\n)*comprobante_id,(?:\s|\\n)*numero_intento/i, 'intento facturación hereda tenant');
  need(errors, s.internal, /organization_id,(?:\s|\\n)*nota_credito_id,(?:\s|\\n)*numero_intento/i, 'intento NC hereda tenant');
  need(errors, s.internal, /organization_id,(?:\s|\\n)*guia_id,(?:\s|\\n)*numero_intento/i, 'intento GRE hereda tenant');
  need(errors, s.internal, /organization_id,(?:\s|\\n)*proceso_id,(?:\s|\\n)*numero_intento/i, 'intento tributario hereda tenant');
  need(errors, s.internal, /ON CONFLICT\s*\(organization_id,tipo_proceso,fecha_referencia\)/i, 'correlativo proceso tenant');
  need(errors, s.internal, /REVOKE ALL ON FUNCTION public\.tributario_preparar_procesos[\s\S]{0,240}?FROM PUBLIC,anon,authenticated/i, 'preparador revocado a clientes');
  need(errors, s.internal, /GRANT EXECUTE ON FUNCTION public\.tributario_preparar_procesos[\s\S]{0,220}?TO service_role/i, 'preparador service_role');
  forbid(errors, s.internal, /%n/, 'format() PostgreSQL con %n inválido');

  need(errors, s.identity, /CREATE OR REPLACE FUNCTION\s+public\._gre_empleado_activo\(\)/i, 'GRE usa identidad app_users');
  need(errors, s.identity, /FROM public\.app_users au[\s\S]{0,220}?JOIN public\.empleados e[\s\S]{0,180}?e\.organization_id=au\.organization_id/i, 'identidad fiscal enlaza empleado dentro del tenant');
  need(errors, s.identity, /au\.base_role IN \('admin','operador'\)/i, 'rol fiscal sale de app_users');
  need(errors, s.identity, /private\.has_permission\(''+tenant\.write''+\)/i, 'NC usa permiso canónico');
  need(errors, s.identity, /private\.has_permission\(''+tenant\.admin''+\)/i, 'baja usa permiso admin canónico');
  need(errors, s.identity, /\(e\.app_user_id = auth\.uid\(\) OR e\.auth_id = auth\.uid\(\)\)/i, 'motores cliente usan app_user_id con fallback legacy');
  need(errors, s.identity, /\(e\.app_user_id = p_usuario_id OR e\.auth_id = p_usuario_id\)/i, 'claims service_role usan app_user_id con fallback legacy');
  need(errors, s.identity, /F3\.7 identity patch mismatch: credit note actor/i, 'patch identidad NC determinista');
  need(errors, s.identity, /F3\.7 identity patch mismatch: tax cancellation actor/i, 'patch identidad baja determinista');
  need(errors, s.identity, /F3\.7 identity patch mismatch: %/i, 'patch identidad claims determinista');

  need(errors, s.defaults, /ALTER TABLE\s+public\.business_capabilities[\s\S]{0,120}?ALTER COLUMN\s+electronic_invoicing\s+SET DEFAULT\s+false/i, 'nuevos tenants inician facturación electrónica deshabilitada');
  forbid(errors, s.defaults, /UPDATE\s+public\.business_capabilities/i, 'default fiscal no debe reescribir tenants existentes');

  need(errors, s.authGuard, /\.from\('app_users'\)[\s\S]{0,300}?organizations!inner\(status\)/i, 'Edge deriva tenant desde app_users');
  need(errors, s.authGuard, /url\.searchParams\.set\('organization_id', `eq\.\$\{organizationId\}`\)/i, 'service_role REST inyecta tenant');
  need(errors, s.authGuard, /headers\.set\(TENANT_HEADER, organizationId\)/i, 'Edge propaga tenant interno');
  need(errors, s.authGuard, /resource === 'configuracion_negocio'[\s\S]{0,180}?url\.searchParams\.get\('id'\) === 'eq\.1'[\s\S]{0,140}?url\.searchParams\.delete\('id'\)/i, 'compatibilidad id=1 no es autoridad');
  need(errors, s.authGuard, /scopeFiscalStorageWriteUrl\(url, organizationId, method\)/i, 'Storage fiscal nuevo scopeado');
  need(errors, s.authGuard, /parts\.splice\(1, 0, encodeURIComponent\(organizationId\)\)/i, 'Storage antepone tenant');
  need(errors, s.authGuard, /\['sign', 'public', 'list', 'copy', 'move'\]\.includes\(first\)/i, 'lecturas Storage legacy preservadas');

  need(errors, s.storage, /CREATE OR REPLACE FUNCTION\s+private\.normalize_fiscal_storage_paths\(\)/i, 'normalizador paths fiscales');
  for (const trigger of [
    'zz_comprobantes_fiscal_storage_paths',
    'zz_notas_credito_fiscal_storage_paths',
    'zz_guias_remision_fiscal_storage_paths',
    'zz_procesos_tributarios_fiscal_storage_paths',
  ]) {
    need(errors, s.storage, new RegExp(`CREATE TRIGGER\\s+${trigger}`, 'i'), trigger);
  }
  need(errors, s.storage, /v_prefix := NEW\.organization_id::text \|\| '\/'/i, 'paths persistidos con prefijo tenant');

  const individual = [
    ['emitirComp', 'comprobantes_electronicos'],
    ['consultarComp', 'comprobantes_electronicos'],
    ['reintentarComp', 'comprobantes_electronicos'],
    ['emitirNc', 'notas_credito'],
    ['consultarNc', 'notas_credito'],
    ['reintentarNc', 'notas_credito'],
    ['emitirGre', 'guias_remision'],
    ['consultarGre', 'guias_remision'],
    ['reintentarGre', 'guias_remision'],
    ['consultarProceso', 'procesos_tributarios'],
    ['reintentarProceso', 'procesos_tributarios'],
  ];
  for (const [key, table] of individual) {
    if (!hasTenantResourcePrecheck(s[key], table)) {
      errors.push(`Falta: ${files[key]} precheck tenant`);
    }
  }

  for (const [key, table] of [
    ['batchComp', 'comprobantes_electronicos'],
    ['batchNc', 'notas_credito'],
    ['batchGre', 'guias_remision'],
  ]) {
    need(errors, s[key], new RegExp(`from\\(['"]${table}['"]\\)[\\s\\S]{0,620}?\\.eq\\(['"]organization_id['"],\\s*organizationId\\)`, 'i'), `${files[key]} filtra candidatos por tenant`);
  }

  for (const rpc of currentRuntimeRpcs) {
    need(
      errors,
      s.rpc,
      new RegExp(`GRANT EXECUTE ON FUNCTION\\s+public\\.${rpc}\\(`, 'i'),
      `${rpc} allowlist SaaS`,
    );
  }
  for (const rpc of closedLegacyFallbackRpcs) {
    need(
      errors,
      s.rpc,
      new RegExp(`REVOKE ALL ON FUNCTION\\s+public\\.${rpc}\\([\\s\\S]{0,220}?FROM PUBLIC,anon,authenticated`, 'i'),
      `${rpc} fallback legacy cerrado`,
    );
  }

  return errors;
}

function selfTest() {
  const errors = [];
  need(errors, 'organization_id uuid', /organization_id\s+uuid/i, 'regex positiva');
  forbid(errors, "format('%n')", /%n/, 'regex prohibida');
  if (errors.length !== 1 || !errors[0].startsWith('Prohibido:')) {
    console.error('SaaS fiscal self-test FAILED: helpers de validación inconsistentes');
    process.exit(1);
  }

  const sample = "DO $rls$ BEGIN FOREACH t IN ARRAY ARRAY['a','b'] LOOP EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t); END LOOP; END; $rls$;";
  if (!dollarBlock(sample, 'rls').includes("'a'")) {
    console.error('SaaS fiscal self-test FAILED: no reconoce bloque dinámico');
    process.exit(1);
  }

  const defaultErrors = [];
  need(defaultErrors, 'ALTER TABLE public.business_capabilities ALTER COLUMN electronic_invoicing SET DEFAULT false;', /electronic_invoicing\s+SET DEFAULT\s+false/i, 'default fiscal seguro');
  forbid(defaultErrors, 'ALTER TABLE public.business_capabilities ALTER COLUMN electronic_invoicing SET DEFAULT false;', /UPDATE\s+public\.business_capabilities/i, 'no reescribir tenants existentes');
  if (defaultErrors.length) {
    console.error('SaaS fiscal self-test FAILED: default fiscal seguro rechazado');
    process.exit(1);
  }

  const directPrecheck = "context.admin.from('procesos_tributarios').select('id').eq('organization_id', organizationId).eq('id', procesoId)";
  if (!hasTenantResourcePrecheck(directPrecheck, 'procesos_tributarios')) {
    console.error('SaaS fiscal self-test FAILED: precheck tenant explícito no reconocido');
    process.exit(1);
  }

  console.log('SaaS fiscal self-test OK (5 casos).');
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify(sources());
if (errors.length) {
  console.error('SaaS fiscal gate FAILED:');
  errors.forEach((error) => console.error(`  - ${error}`));
  process.exit(1);
}

console.log('SaaS fiscal gate OK.');
console.log('  - 19 tablas fiscales/GRE tenant-owned');
console.log('  - RPC cliente y service_role tenant-aware');
console.log('  - identidad app_users canónica con fallback auth_id legacy');
console.log('  - boleta/factura reabiertas tras scope fiscal');
console.log('  - fallback RPC legacy de NC clasificado y revocado');
console.log('  - nuevos tenants con electronic_invoicing=false');
console.log('  - Storage fiscal nuevo bajo organization_id');