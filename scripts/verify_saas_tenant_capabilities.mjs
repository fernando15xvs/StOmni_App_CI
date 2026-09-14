import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrationFiles = [
  'supabase/migrations/20260908043000_saas_tenant_capabilities_complete.sql',
  'supabase/migrations/20260908043100_saas_capability_guard_corrections.sql',
];
const runtimeFiles = [
  'packages/core_logic/lib/business/domain/business_profile.dart',
  'packages/core_logic/lib/business/data/business_profile_mapper.dart',
  'packages/mobile_app/lib/features/trazabilidad/pages/trazabilidad_config_page.dart',
  'packages/desktop_app/lib/features/traceability/desktop_traceability_config_panel.dart',
];
const read = (files) => files.map((f) => fs.readFileSync(path.join(root, f), 'utf8')).join('\n');

function need(errors, source, regex, label) {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
}

function verify(sql, runtime) {
  const errors = [];
  need(errors, sql, /ADD COLUMN inventory_enabled boolean NOT NULL DEFAULT true/i, 'inventory_enabled persistido');
  need(errors, sql, /ADD COLUMN multiple_branches boolean NOT NULL DEFAULT true/i, 'multiple_branches persistido');
  need(errors, sql, /ADD COLUMN multiple_warehouses boolean NOT NULL DEFAULT true/i, 'multiple_warehouses persistido');
  need(errors, sql, /business_capabilities_inventory_dependencies[\s\S]{0,500}?NOT purchase_management[\s\S]{0,200}?NOT multiple_warehouses/i, 'invariantes inventory dependencies');
  need(errors, sql, /CREATE OR REPLACE FUNCTION private\.current_business_capability\(p_capability text\)/i, 'helper capability tenant-aware');
  need(errors, sql, /WHERE b\.organization_id=v_org/i, 'helper filtra tenant');
  need(errors, sql, /'multiple_branches',b\.multiple_branches/i, 'perfil expone multiple_branches');
  need(errors, sql, /CREATE OR REPLACE FUNCTION public\.update_business_capabilities_v1[\s\S]{0,3600}?v_multi_branches[\s\S]{0,600}?v_multi_warehouses/i, 'RPC actualiza capacidades nuevas');
  need(errors, sql, /Cannot disable multiple branches while multiple active branches exist/i, 'guard disable multi-branch');
  need(errors, sql, /Cannot disable multiple warehouses while multiple active warehouses exist/i, 'guard disable multi-warehouse');
  need(errors, sql, /Cannot disable inventory while stock exists/i, 'guard disable inventory con stock');
  need(errors, sql, /BEFORE INSERT OR UPDATE OF status ON public\.branches/i, 'branch insert/reactivation enforcement');
  need(errors, sql, /BEFORE INSERT OR UPDATE OF activo ON public\.almacenes/i, 'warehouse insert/reactivation enforcement');
  need(errors, sql, /CREATE TRIGGER zz_inventario_almacen_capability_guard[\s\S]{0,120}?BEFORE INSERT OR UPDATE OR DELETE ON public\.inventario_almacen/i, 'inventory balance enforcement');
  need(errors, sql, /IF TG_OP='DELETE' THEN RETURN OLD; END IF;/i, 'DELETE trigger conserva operación');
  need(errors, runtime, /final bool multipleBranches;/i, 'modelo Dart multipleBranches');
  need(errors, runtime, /multipleBranches: read\('multiple_branches'\)/i, 'mapper decodifica multipleBranches');
  need(errors, runtime, /'multiple_branches': value\.multipleBranches/i, 'mapper codifica multipleBranches');
  need(errors, runtime, /inventoryEnabled \|\|[\s\S]{0,300}?!multipleWarehouses/i, 'modelo admite inventario desactivado sólo sin dependencias');

  const copyCount = [...runtime.matchAll(/BusinessCapabilities\([\s\S]{0,220}?multipleBranches:\s*c\.multipleBranches/g)].length;
  if (copyCount < 2) errors.push('mobile/desktop deben preservar multipleBranches al editar trazabilidad');
  return errors;
}

function selfTest() {
  const sql = read(migrationFiles);
  const runtime = read(runtimeFiles);
  const cases = [
    ['válido', sql, runtime, false],
    ['sin branch persistido', sql.replace('ADD COLUMN multiple_branches boolean NOT NULL DEFAULT true,', ''), runtime, true],
    ['sin guard stock', sql.replace('Cannot disable inventory while stock exists', 'inventory disabled'), runtime, true],
    ['mapper pierde branch', sql, runtime.replace("multipleBranches: read('multiple_branches'),", ''), true],
    ['delete trigger incorrecto', sql.replace("IF TG_OP='DELETE' THEN RETURN OLD; END IF;", ''), runtime, true],
  ];
  const failed = [];
  for (const [name, s, r, shouldFail] of cases) {
    if ((verify(s, r).length > 0) !== shouldFail) failed.push(name);
  }
  if (failed.length) {
    console.error('SaaS tenant capabilities self-test FAILED:');
    failed.forEach((x) => console.error(`  - ${x}`));
    process.exit(1);
  }
  console.log(`SaaS tenant capabilities self-test OK (${cases.length} casos).`);
}

if (process.argv.includes('--self-test')) { selfTest(); process.exit(0); }
const errors = verify(read(migrationFiles), read(runtimeFiles));
if (errors.length) {
  console.error('SaaS tenant capabilities gate FAILED:');
  errors.forEach((e) => console.error(`  - ${e}`));
  process.exit(1);
}
console.log('SaaS tenant capabilities gate OK (F5.1).');
