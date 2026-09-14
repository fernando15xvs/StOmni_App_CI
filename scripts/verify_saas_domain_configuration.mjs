import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrationName = '20260907030554_saas_domain_configuration_tenant.sql';
const paths = {
  migration: path.join(root, 'supabase', 'migrations', migrationName),
  configService: path.join(root, 'packages/core_logic/lib/services/configuracion_service.dart'),
  profileMapper: path.join(root, 'packages/core_logic/lib/business/data/business_profile_mapper.dart'),
  profileGateway: path.join(root, 'packages/core_logic/lib/business/data/supabase_business_profile_gateway.dart'),
  fiscalMapper: path.join(root, 'packages/core_logic/lib/features/facturacion/application/business_fiscal_profile_mapper.dart'),
};

function need(errors, source, regex, label) {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
}

function executableSql(source) {
  return source.replace(/--.*$/gm, '');
}

function functionBlock(source, signature) {
  const escaped = signature.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return source.match(
    new RegExp(`CREATE\\s+OR\\s+REPLACE\\s+FUNCTION\\s+${escaped}[\\s\\S]*?\\$\\$;`, 'i'),
  )?.[0] ?? '';
}

function policyBlock(source, name) {
  return source.match(
    new RegExp(`CREATE\\s+POLICY\\s+${name}[\\s\\S]*?;`, 'i'),
  )?.[0] ?? '';
}

function verifyMigration(source) {
  const errors = [];
  const sql = executableSql(source);

  need(errors, source, /FROM\s+public\.configuracion_negocio[\s\S]{0,120}?WHERE\s+organization_id\s+IS NULL/i, 'detecta configuración legacy sin tenant');
  need(errors, source, /INSERT INTO\s+public\.organizations[\s\S]{0,650}?'PE'[\s\S]{0,150}?'PEN'[\s\S]{0,150}?'America\/Lima'/i, 'tenant legacy creado server-side');
  need(errors, source, /UPDATE\s+public\.configuracion_negocio[\s\S]{0,180}?SET\s+organization_id\s*=\s*v_organization_id/i, 'backfill configuracion_negocio');
  need(errors, source, /UPDATE\s+public\.business_capabilities[\s\S]{0,200}?SET\s+organization_id\s*=\s*v_organization_id/i, 'backfill business_capabilities');
  need(errors, source, /INSERT INTO\s+public\.app_users[\s\S]{0,900}?FROM\s+public\.empleados/i, 'backfill app_users desde empleados Auth');
  need(errors, source, /UPDATE\s+public\.empleados[\s\S]{0,280}?organization_id\s*=\s*v_organization_id[\s\S]{0,160}?app_user_id\s*=\s*COALESCE\(e\.app_user_id,\s*e\.auth_id\)/i, 'backfill empleados');

  for (const table of ['empleados', 'configuracion_negocio', 'business_capabilities']) {
    need(
      errors,
      source,
      new RegExp(`ALTER TABLE\\s+public\\.${table}[\\s\\S]{0,260}?ALTER COLUMN\\s+organization_id\\s+SET NOT NULL`, 'i'),
      `${table}.organization_id NOT NULL`,
    );
  }
  need(errors, source, /VALIDATE CONSTRAINT\s+empleados_organization_required/i, 'valida constraint de tenant de empleados');
  need(errors, source, /REVOKE UPDATE ON TABLE\s+public\.configuracion_negocio\s+FROM\s+authenticated/i, 'cierra UPDATE directo de configuración');
  need(errors, source, /REVOKE UPDATE ON TABLE\s+public\.business_capabilities\s+FROM\s+authenticated/i, 'cierra UPDATE directo de capabilities');

  const readConfig = functionBlock(source, 'public.get_current_business_configuration_v1()');
  const updateConfig = functionBlock(source, 'public.actualizar_configuracion_negocio_v1(p_datos jsonb)');
  const readProfile = functionBlock(source, 'public.get_business_profile_v1()');
  const updateCaps = functionBlock(source, 'public.update_business_capabilities_v1(\n  p_expected_revision bigint,\n  p_capabilities jsonb\n)') ||
    source.match(/CREATE OR REPLACE FUNCTION public\.update_business_capabilities_v1\([\s\S]*?\n\$\$;/i)?.[0] || '';
  const services = functionBlock(source, 'public._business_services_enabled()');
  const variants = functionBlock(source, 'public._business_variants_enabled()');
  const purchaseGuard = functionBlock(source, 'public._business_enforce_purchase_capability()');
  const saleGuard = functionBlock(source, 'public._business_enforce_new_sale_capabilities()');

  for (const [label, block] of [
    ['get_current_business_configuration_v1', readConfig],
    ['actualizar_configuracion_negocio_v1', updateConfig],
    ['get_business_profile_v1', readProfile],
    ['update_business_capabilities_v1', updateCaps],
    ['_business_services_enabled', services],
    ['_business_variants_enabled', variants],
    ['_business_enforce_purchase_capability', purchaseGuard],
    ['_business_enforce_new_sale_capabilities', saleGuard],
  ]) {
    if (!block) errors.push(`Falta función reescrita: ${label}`);
  }

  need(errors, readConfig, /SECURITY DEFINER[\s\S]*?SET search_path\s*=\s*''/i, 'lectura config SECURITY DEFINER con search_path vacío');
  need(errors, readConfig, /private\.require_current_organization_id\(\)/i, 'lectura config deriva tenant');
  need(errors, updateConfig, /private\.require_current_organization_id\(\)/i, 'actualización config deriva tenant');
  need(errors, updateConfig, /private\.has_permission\('tenant\.admin'\)/i, 'actualización config exige tenant.admin');
  need(errors, updateConfig, /WHERE\s+c\.organization_id\s*=\s*v_organization_id/i, 'actualización config escribe por tenant');
  need(errors, readProfile, /WHERE\s+c\.organization_id\s*=\s*v_organization_id/i, 'perfil filtra por tenant');
  need(errors, updateCaps, /private\.has_permission\('tenant\.admin'\)/i, 'capabilities exige tenant.admin');
  need(errors, updateCaps, /FROM\s+public\.business_capabilities[\s\S]*?WHERE\s+organization_id\s*=\s*v_organization_id[\s\S]*?FOR UPDATE/i, 'capabilities bloquea fila del tenant');
  need(errors, updateCaps, /UPDATE\s+public\.business_capabilities[\s\S]*?WHERE\s+organization_id\s*=\s*v_organization_id/i, 'capabilities actualiza sólo tenant actual');
  need(errors, services, /private\.current_organization_id\(\)/i, 'services capability tenant-aware');
  need(errors, variants, /private\.current_organization_id\(\)/i, 'variants capability tenant-aware');
  need(errors, purchaseGuard, /private\.require_current_organization_id\(\)/i, 'guard compra tenant-aware');
  need(errors, saleGuard, /private\.require_current_organization_id\(\)/i, 'guard venta tenant-aware');

  for (const policy of ['logos_tenant_admin_delete', 'logos_tenant_admin_insert', 'logos_tenant_admin_update']) {
    const block = policyBlock(source, policy);
    need(errors, block, /private\.has_permission\('tenant\.admin'\)/i, `${policy} exige tenant.admin`);
    need(errors, block, /split_part\(name, '\/', 1\)\s*=\s*private\.current_organization_id\(\)::text/i, `${policy} restringe prefijo UUID tenant`);
  }

  if (/\bbusiness_id\s*=\s*1\b/i.test(sql) || /\b(?:c\.)?id\s*=\s*1\b/i.test(sql)) {
    errors.push('Fase 3.1 contiene singleton SQL ejecutable');
  }
  if (/\bapp_es_admin\s*\(|\bapp_empleado_activo\s*\(/i.test(sql)) {
    errors.push('Fase 3.1 reutiliza helper legacy de empleados');
  }
  if (/GRANT\s+UPDATE\s+ON TABLE\s+public\.(?:configuracion_negocio|business_capabilities)\s+TO\s+authenticated/i.test(sql)) {
    errors.push('Fase 3.1 reabre bypass UPDATE directo');
  }

  return errors;
}

function verifyRuntime(sources) {
  const errors = [];
  const { configService, profileMapper, profileGateway, fiscalMapper } = sources;

  need(errors, configService, /rpc\('get_current_business_configuration_v1'\)/, 'ConfiguracionService usa RPC tenant-aware');
  need(errors, configService, /configuration\['organization_id'\]/, 'ConfiguracionService toma organization_id del backend');
  need(errors, configService, /\$organizationSegment\/logos\/logo_/, 'logos usan prefijo de organización');
  need(errors, configService, /allowedPrefix\s*=\s*'\$\{_storageOrganizationSegment\(\)\}\/logos\/'/, 'cleanup limita el prefijo del tenant');
  if (/\.from\(\s*['"]configuracion_negocio['"]\s*\)/.test(configService)) errors.push('ConfiguracionService lee tabla directamente');
  if (/legacyWritableBusinessId|businessId\s*(?:==|!=|===|!==)\s*['"]1['"]|fallback:\s*['"]1['"]/.test(configService)) errors.push('ConfiguracionService conserva singleton');

  need(errors, profileMapper, /if\s*\(id\.isEmpty\s*\|\|/, 'BusinessProfileMapper acepta ID dinámico no vacío');
  if (/id\s*(?:==|!=|===|!==)\s*['"]1['"]/.test(profileMapper)) errors.push('BusinessProfileMapper exige ID fijo');

  need(errors, profileGateway, /business_profile_v2:\$cacheNamespace:\$user/, 'cache sin sufijo singleton');
  need(errors, profileGateway, /businessId\.trim\(\)\.isEmpty/, 'gateway valida ID dinámico');
  if (/\.eq\(\s*['"]id['"]\s*,\s*1\s*\)|businessId\s*(?:==|!=|===|!==)\s*['"]1['"]|business_profile[^'"\n]*:1/.test(profileGateway)) errors.push('BusinessProfileGateway conserva singleton');

  need(errors, fiscalMapper, /businessId:\s*_text\(raw\['id'\]\)/, 'mapper fiscal usa ID real del backend');
  if (/fallback:\s*['"]1['"]/.test(fiscalMapper)) errors.push('mapper fiscal inventa ID singleton');

  return errors;
}

function readSources() {
  const sources = {};
  for (const [key, file] of Object.entries(paths)) {
    if (!fs.existsSync(file)) throw new Error(`Falta ${path.relative(root, file)}`);
    sources[key] = fs.readFileSync(file, 'utf8');
  }
  return sources;
}

function allErrors(sources) {
  return [...verifyMigration(sources.migration), ...verifyRuntime(sources)];
}

function selfTest() {
  const valid = readSources();
  const initial = allErrors(valid);
  if (initial.length) {
    console.error('SaaS domain configuration self-test FAILED (contrato actual rechazado):');
    for (const error of initial) console.error(`  - ${error}`);
    process.exit(1);
  }

  const cases = [
    ['singleton SQL', { ...valid, migration: `${valid.migration}\nSELECT * FROM public.business_capabilities WHERE business_id = 1;` }],
    ['UPDATE directo', { ...valid, migration: `${valid.migration}\nGRANT UPDATE ON TABLE public.business_capabilities TO authenticated;` }],
    ['gateway singleton', { ...valid, profileGateway: `${valid.profileGateway}\nfinal bad = businessId == '1';` }],
    ['fiscal fallback', { ...valid, fiscalMapper: valid.fiscalMapper.replace("businessId: _text(raw['id'])", "businessId: _text(raw['id'], fallback: '1')") }],
  ];

  const missed = cases.filter(([, mutated]) => allErrors(mutated).length === 0).map(([name]) => name);
  if (missed.length) {
    console.error('SaaS domain configuration self-test FAILED:');
    for (const name of missed) console.error(`  - no detectó ${name}`);
    process.exit(1);
  }
  console.log(`SaaS domain configuration self-test OK (${cases.length + 1} contratos/casos).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

let sources;
try {
  sources = readSources();
} catch (error) {
  console.error(`SaaS domain configuration gate FAILED: ${error.message}`);
  process.exit(1);
}
const errors = allErrors(sources);
if (errors.length) {
  console.error('SaaS domain configuration gate FAILED:');
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}
console.log('SaaS domain configuration gate OK (Fase 3.1).');
