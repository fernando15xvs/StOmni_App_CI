import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrationName = '20260907033419_saas_catalog_tenant.sql';
const migrationPath = path.join(root, 'supabase', 'migrations', migrationName);

function need(errors, source, regex, label) {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
}

function block(source, start) {
  const escaped = start.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return source.match(new RegExp(`${escaped}[\\s\\S]*?\\$\\$;`, 'i'))?.[0] ?? '';
}

function policy(source, name) {
  return source.match(new RegExp(`CREATE\\s+POLICY\\s+${name}[\\s\\S]*?;`, 'i'))?.[0] ?? '';
}

function mutated(source, regex, replacement, label) {
  const next = source.replace(regex, replacement);
  if (next === source) {
    throw new Error(`Self-test fixture no pudo mutar: ${label}`);
  }
  return next;
}

function verify(source) {
  const errors = [];
  const tables = [
    'productos',
    'product_unit_profiles',
    'product_variant_groups',
    'product_variant_members',
    'service_metadata',
    'sale_price_rules',
    'product_traceability_configs',
  ];

  for (const table of tables) {
    need(errors, source, new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ADD COLUMN\\s+organization_id\\s+uuid`, 'i'), `${table}.organization_id`);
    need(errors, source, new RegExp(`${table}_organization_id_fkey[\\s\\S]{0,180}?REFERENCES\\s+public\\.organizations\\s*\\(\\s*id\\s*\\)`, 'i'), `${table} FK organizations`);
    need(errors, source, new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ALTER COLUMN\\s+organization_id\\s+SET NOT NULL`, 'i'), `${table}.organization_id NOT NULL`);
    need(errors, source, new RegExp(`CREATE TRIGGER\\s+${table}_enforce_organization_id[\\s\\S]{0,160}?private\\.enforce_row_organization_id\\(\\)`, 'i'), `${table} trigger tenant`);
    need(errors, source, new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ENABLE ROW LEVEL SECURITY`, 'i'), `${table} RLS`);
  }

  need(errors, source, /productos_organization_id_id_key[\s\S]{0,100}?UNIQUE\s*\(\s*organization_id\s*,\s*id\s*\)/i, 'productos clave compuesta');
  need(errors, source, /product_variant_groups_organization_id_id_key[\s\S]{0,100}?UNIQUE\s*\(\s*organization_id\s*,\s*id\s*\)/i, 'variant groups clave compuesta');
  need(errors, source, /CREATE UNIQUE INDEX\s+productos_organization_code_key[\s\S]{0,160}?organization_id,\s*upper\(btrim\(codigo\)\)/i, 'código de producto único por tenant');

  need(errors, source, /productos_organization_proveedor_fkey[\s\S]{0,180}?FOREIGN KEY\s*\(\s*organization_id\s*,\s*proveedor_id\s*\)[\s\S]{0,180}?REFERENCES\s+public\.proveedores\s*\(\s*organization_id\s*,\s*id\s*\)[\s\S]{0,120}?ON DELETE SET NULL\s*\(\s*proveedor_id\s*\)/i, 'producto/proveedor FK compuesta conserva tenant');

  for (const [constraint, parent] of [
    ['product_unit_profiles_organization_product_fkey', 'productos'],
    ['product_traceability_configs_organization_product_fkey', 'productos'],
    ['service_metadata_organization_product_fkey', 'productos'],
    ['sale_price_rules_organization_product_fkey', 'productos'],
  ]) {
    need(errors, source, new RegExp(`${constraint}[\\s\\S]{0,180}?FOREIGN KEY\\s*\\(\\s*organization_id\\s*,\\s*product_id\\s*\\)[\\s\\S]{0,180}?REFERENCES\\s+public\\.${parent}\\s*\\(\\s*organization_id\\s*,\\s*id\\s*\\)`, 'i'), `${constraint} tenant-qualified`);
  }
  need(errors, source, /product_variant_members_organization_group_fkey[\s\S]{0,180}?REFERENCES\s+public\.product_variant_groups\s*\(\s*organization_id\s*,\s*id\s*\)/i, 'variant member -> group tenant');
  need(errors, source, /product_variant_members_organization_product_fkey[\s\S]{0,180}?REFERENCES\s+public\.productos\s*\(\s*organization_id\s*,\s*id\s*\)/i, 'variant member -> product tenant');

  need(errors, source, /count\(DISTINCT organization_id\)[\s\S]{0,220}?v_organization_count\s*<>\s*1/i, 'backfill legacy fail-closed');
  need(errors, source, /Cross-tenant product\/provider relationship exists/i, 'precheck product/provider cross-tenant');
  need(errors, source, /Cross-tenant variant membership exists/i, 'precheck variant cross-tenant');

  const productSelect = policy(source, 'productos_tenant_select');
  const productInsert = policy(source, 'productos_tenant_insert');
  const productUpdate = policy(source, 'productos_tenant_update');
  for (const [name, p] of [['SELECT',productSelect],['INSERT',productInsert],['UPDATE',productUpdate]]) {
    need(errors, p, /private\.row_belongs_to_current_organization\(organization_id\)/i, `productos ${name} tenant predicate`);
  }
  need(errors, productInsert, /private\.has_permission\('tenant\.admin'\)/i, 'productos INSERT admin');
  need(errors, productUpdate, /WITH CHECK[\s\S]*private\.has_permission\('tenant\.admin'\)/i, 'productos UPDATE USING + WITH CHECK admin');

  const context = block(source, 'CREATE OR REPLACE FUNCTION public.get_my_tenant_context_v1()');
  need(errors, context, /private\.require_current_organization_id\(\)/i, 'tenant context deriva organization server-side');
  need(errors, context, /private\.current_base_role\(\)/i, 'tenant context deriva rol server-side');

  for (const fn of [
    'public.get_product_unit_profiles_v1(p_product_ids bigint[])',
    'public.get_product_traceability_config_v1(p_product_id bigint)',
    'public.list_product_variant_groups_v1()',
    'public.list_sale_price_rules_v1()',
    'public.list_services_v1(p_include_inactive boolean DEFAULT false)',
  ]) {
    const b = block(source, `CREATE OR REPLACE FUNCTION ${fn}`);
    need(errors, b, /organization_id/i, `${fn} filtra tenant`);
  }

  for (const legacy of [
    '_legacy_save_product_unit_profile_v6',
    '_legacy_save_product_traceability_config_v1',
    '_legacy_save_sale_price_rule_v1',
    '_legacy_delete_sale_price_rule_v1',
    '_legacy_save_product_variant_group_v1',
    '_legacy_delete_product_variant_group_v1',
    '_legacy_deactivate_service_v1',
  ]) {
    need(errors, source, new RegExp(`REVOKE ALL ON FUNCTION\\s+public\\.${legacy}`, 'i'), `${legacy} no expuesta`);
  }

  const unitSave = block(source, 'CREATE FUNCTION public.save_product_unit_profile_v6(');
  need(errors, unitSave, /private\.assert_product_in_current_organization\(p_product_id\)/i, 'unit profile wrapper valida producto tenant');
  const traceSave = block(source, 'CREATE FUNCTION public.save_product_traceability_config_v1(');
  need(errors, traceSave, /private\.assert_product_in_current_organization\(p_product_id\)/i, 'traceability wrapper valida producto tenant');
  const priceSave = block(source, 'CREATE FUNCTION public.save_sale_price_rule_v1(');
  need(errors, priceSave, /private\.assert_product_in_current_organization\(p_product_id\)/i, 'price wrapper valida producto tenant');
  need(errors, priceSave, /private\.assert_price_rule_in_current_organization\(p_id\)/i, 'price wrapper valida regla tenant');
  const variantSave = block(source, 'CREATE FUNCTION public.save_product_variant_group_v1(');
  need(errors, variantSave, /private\.assert_variant_group_in_current_organization\(p_group_id\)/i, 'variant wrapper valida grupo tenant');
  need(errors, variantSave, /p\.organization_id\s*=\s*v_organization_id/i, 'variant wrapper valida productos tenant');

  for (const version of [1,2,3,4,5]) {
    need(errors, source, new RegExp(`REVOKE ALL ON FUNCTION\\s+public\\.save_product_unit_profile_v${version}\\(bigint,bigint,jsonb\\)\\s+FROM\\s+authenticated`, 'i'), `unit profile v${version} retirada de cliente`);
  }

  for (const name of ['productos_imagenes_tenant_select','productos_imagenes_tenant_insert','productos_imagenes_tenant_update','productos_imagenes_tenant_delete']) {
    const p = policy(source, name);
    need(errors, p, /bucket_id\s*=\s*'imagenes_productos'/i, `${name} bucket`);
    need(errors, p, /split_part\(name, '\/', 1\)\s*=\s*private\.current_organization_id\(\)::text/i, `${name} prefijo tenant`);
  }

  if (/CREATE\s+POLICY[\s\S]{0,240}?TO\s+authenticated\s+USING\s*\(\s*true\s*\)/i.test(source)) {
    errors.push('No se permite policy authenticated sin tenant predicate');
  }
  if (/GRANT\s+.+ON TABLE\s+public\.(?:productos|product_unit_profiles|sale_price_rules|product_traceability_configs)\s+TO\s+anon/i.test(source)) {
    errors.push('Catálogo no debe otorgar grants de tabla a anon');
  }

  return errors;
}

function readMigration() {
  if (!fs.existsSync(migrationPath)) throw new Error(`Falta ${migrationName}`);
  return fs.readFileSync(migrationPath, 'utf8');
}

function selfTest() {
  const valid = readMigration();
  const baseErrors = verify(valid);
  if (baseErrors.length) {
    console.error('SaaS catalog foundation self-test FAILED (contrato válido rechazado):');
    for (const error of baseErrors) console.error(`  - ${error}`);
    process.exit(1);
  }

  const cases = [
    [
      'sin código tenant',
      mutated(valid, /CREATE UNIQUE INDEX\s+productos_organization_code_key/i, 'CREATE INDEX productos_organization_code_key', 'sin código tenant'),
    ],
    [
      'FK proveedor simple',
      mutated(valid, /ON DELETE SET NULL\s*\(\s*proveedor_id\s*\)\s*;/i, 'ON DELETE SET NULL;', 'FK proveedor simple'),
    ],
    [
      'wrapper sin assertion',
      mutated(
        valid,
        /(CREATE FUNCTION public\.save_product_unit_profile_v6\([\s\S]{0,1400}?)PERFORM\s+private\.assert_product_in_current_organization\(p_product_id\)\s*;/i,
        '$1PERFORM 1;',
        'wrapper sin assertion',
      ),
    ],
    [
      'storage sin namespace',
      mutated(valid, /split_part\(name, '\/', 1\)\s*=\s*private\.current_organization_id\(\)::text/i, 'true', 'storage sin namespace'),
    ],
  ];
  const missed = [];
  for (const [name, changed] of cases) {
    if (verify(changed).length === 0) missed.push(name);
  }
  if (missed.length) {
    console.error('SaaS catalog foundation self-test FAILED:');
    for (const name of missed) console.error(`  - no detectó ${name}`);
    process.exit(1);
  }
  console.log(`SaaS catalog foundation self-test OK (${cases.length + 1} contratos/casos).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify(readMigration());
if (errors.length) {
  console.error('SaaS catalog foundation gate FAILED:');
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}
console.log(`SaaS catalog foundation gate OK: ${migrationName}`);
