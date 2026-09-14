import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const schemaName = '20260907205440_saas_inventory_tenant_schema.sql';
const rpcName = '20260907205926_saas_inventory_rpc_guards.sql';
const productUpdateName = '20260907210310_saas_product_update_tenant.sql';

function read(name) {
  const p = path.join(root, 'supabase', 'migrations', name);
  if (!fs.existsSync(p)) throw new Error(`Falta migración: ${name}`);
  return fs.readFileSync(p, 'utf8');
}

function need(errors, source, regex, label) {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
}

function mutate(source, regex, replacement, label) {
  const next = source.replace(regex, replacement);
  if (next === source) {
    throw new Error(`Self-test fixture no pudo mutar: ${label}`);
  }
  return next;
}

function fnBlock(source, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return source.match(
    new RegExp(`CREATE\\s+(?:OR\\s+REPLACE\\s+)?FUNCTION\\s+${escaped}[\\s\\S]*?\\$\\$;`, 'i'),
  )?.[0] ?? '';
}

function policyBlock(source, name) {
  return source.match(new RegExp(`CREATE\\s+POLICY\\s+${name}[\\s\\S]*?;`, 'i'))?.[0] ?? '';
}

function verify(schema, rpc, productUpdate) {
  const errors = [];
  const tables = [
    'almacenes',
    'inventario_almacen',
    'inventario_movimientos',
    'inventario_operaciones_idempotentes',
    'inventory_lots',
    'inventory_serials',
    'inventory_traceability_consumptions',
    'inventory_traceability_receipts',
    'stock_alert_tx_context',
    'transferencias_stock',
    'sys_processed_requests',
  ];

  for (const table of tables) {
    need(errors, schema, new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ADD COLUMN\\s+organization_id\\s+uuid`, 'i'), `${table}.organization_id`);
    need(errors, schema, new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ALTER COLUMN\\s+organization_id\\s+SET NOT NULL`, 'i'), `${table}.organization_id NOT NULL`);
    need(errors, schema, new RegExp(`${table}_organization_id_fkey[\\s\\S]{0,180}?REFERENCES\\s+public\\.organizations\\s*\\(\\s*id\\s*\\)`, 'i'), `${table} -> organizations`);
    need(errors, schema, new RegExp(`CREATE TRIGGER\\s+${table}_enforce_organization_id`, 'i'), `${table} trigger tenant`);
    need(errors, schema, new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ENABLE ROW LEVEL SECURITY`, 'i'), `${table} RLS`);
    need(errors, schema, new RegExp(`REVOKE ALL ON TABLE\\s+public\\.${table}\\s+FROM\\s+PUBLIC,\\s*anon,\\s*authenticated`, 'i'), `${table} revoca superficie cliente por defecto`);
  }

  if (/\bmin\s*\(\s*organization_id\s*\)/i.test(schema)) {
    errors.push('No usar min(uuid): PostgreSQL 17.6 no expone aggregate min(uuid)');
  }
  need(
    errors,
    schema,
    /count\(DISTINCT organization_id\)::integer[\s\S]{0,500}?ORDER BY organization_id::text[\s\S]{0,100}?LIMIT 1/i,
    'fallback UUID compatible con PostgreSQL 17',
  );

  const inventoryTrigger = fnBlock(schema, 'private.enforce_inventory_organization_id()');
  need(errors, inventoryTrigger, /private\.current_organization_id\(\)/i, 'trigger deriva tenant autenticado');
  need(errors, inventoryTrigger, /Cross-tenant product\/warehouse relationship is not allowed/i, 'trigger impide producto/almacén cross-tenant');
  need(errors, inventoryTrigger, /Cross-tenant transfer destination is not allowed/i, 'trigger impide destino cross-tenant');
  need(errors, inventoryTrigger, /NEW\.organization_id\s*:=\s*v_current_organization_id/i, 'trigger asigna tenant server-side');

  need(errors, schema, /almacenes_organization_id_id_key[\s\S]{0,100}?UNIQUE\s*\(\s*organization_id\s*,\s*id\s*\)/i, 'almacenes clave compuesta tenant');
  need(errors, schema, /inventario_movimientos_organization_id_id_key[\s\S]{0,100}?UNIQUE\s*\(\s*organization_id\s*,\s*id\s*\)/i, 'movimientos clave compuesta tenant');

  const compositeConstraints = [
    ['inventario_almacen_organization_product_fkey', 'productos'],
    ['inventario_almacen_organization_warehouse_fkey', 'almacenes'],
    ['inventario_movimientos_organization_product_fkey', 'productos'],
    ['inventario_movimientos_organization_warehouse_fkey', 'almacenes'],
    ['inventory_lots_organization_product_fkey', 'productos'],
    ['inventory_lots_organization_warehouse_fkey', 'almacenes'],
    ['inventory_serials_organization_product_fkey', 'productos'],
    ['inventory_serials_organization_warehouse_fkey', 'almacenes'],
    ['inventory_traceability_consumptions_organization_product_fkey', 'productos'],
    ['inventory_traceability_consumptions_organization_warehouse_fkey', 'almacenes'],
    ['inventory_traceability_receipts_organization_product_fkey', 'productos'],
    ['inventory_traceability_receipts_organization_warehouse_fkey', 'almacenes'],
    ['transferencias_stock_organization_origin_fkey', 'almacenes'],
    ['transferencias_stock_organization_destination_fkey', 'almacenes'],
  ];
  for (const [constraint, parent] of compositeConstraints) {
    need(
      errors,
      schema,
      new RegExp(`${constraint}[\\s\\S]{0,220}?FOREIGN KEY\\s*\\(\\s*organization_id\\s*,[\\s\\S]{0,90}?\\)[\\s\\S]{0,220}?REFERENCES\\s+public\\.${parent}\\s*\\(\\s*organization_id\\s*,\\s*id\\s*\\)`, 'i'),
      `${constraint} tenant-qualified`,
    );
  }

  for (const [name, permission] of [
    ['almacenes_tenant_select','tenant.read'],
    ['almacenes_tenant_insert','tenant.admin'],
    ['almacenes_tenant_update','tenant.admin'],
    ['inventario_almacen_tenant_select','tenant.read'],
    ['inventario_movimientos_tenant_select','tenant.admin'],
    ['inventory_lots_tenant_select','tenant.read'],
    ['inventory_serials_tenant_select','tenant.read'],
  ]) {
    const block = policyBlock(schema, name);
    if (!block.includes(`private.has_permission('${permission}')`) || !/row_belongs_to_current_organization\(organization_id\)/i.test(block)) {
      errors.push(`Falta: ${name} tenant-aware`);
    }
  }

  for (const helper of [
    'private.assert_warehouse_in_current_organization',
    'private.assert_supplier_in_current_organization',
    'private.assert_inventory_request_scope',
  ]) {
    need(errors, rpc, new RegExp(`CREATE OR REPLACE FUNCTION\\s+${helper}`, 'i'), helper);
    need(errors, rpc, new RegExp(`REVOKE ALL ON FUNCTION\\s+${helper.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`, 'i'), `${helper} no expuesto`);
  }

  const activeEntrypoints = [
    ['public.ajustar_stock_scaled_v2(', ['assert_product_in_current_organization','assert_warehouse_in_current_organization']],
    ['public.registrar_ingreso_mercaderia_scaled_v2(', ['assert_inventory_request_scope','assert_product_in_current_organization','assert_supplier_in_current_organization','assert_warehouse_in_current_organization']],
    ['public.registrar_merma_scaled_v4(', ['assert_inventory_request_scope','assert_product_in_current_organization','assert_warehouse_in_current_organization']],
    ['public.trasladar_stock_scaled_v4(', ['assert_inventory_request_scope','assert_product_in_current_organization','assert_warehouse_in_current_organization']],
    ['public.crear_producto_con_stock(', ['assert_inventory_request_scope','assert_supplier_in_current_organization','assert_warehouse_in_current_organization']],
    ['public.save_service_v1(', ['require_current_organization_id']],
    ['public.register_traceable_merchandise_receipt_v1(', ['assert_inventory_request_scope','assert_product_in_current_organization','assert_warehouse_in_current_organization','assert_supplier_in_current_organization']],
  ];
  for (const [signature, assertions] of activeEntrypoints) {
    const block = fnBlock(rpc, signature);
    if (!block) errors.push(`Falta entrypoint: ${signature}`);
    for (const assertion of assertions) need(errors, block, new RegExp(assertion, 'i'), `${signature} usa ${assertion}`);
    if (/FROM\s+public\.empleados[\s\S]{0,220}?auth_id\s*=\s*auth\.uid\(\)/i.test(block)) {
      errors.push(`${signature} no debe autorizar por empleados.auth_id`);
    }
  }

  const requestScope = fnBlock(rpc, 'private.assert_inventory_request_scope(');
  for (const table of [
    'inventario_operaciones_idempotentes',
    'inventory_traceability_receipts',
    'inventory_traceability_consumptions',
    'sys_processed_requests',
  ]) {
    need(errors, requestScope, new RegExp(`public\\.${table}[\\s\\S]{0,180}?organization_id\\s+IS DISTINCT FROM`, 'i'), `request_id cross-tenant en ${table}`);
  }

  const createProduct = fnBlock(rpc, 'public.crear_producto_con_stock(');
  need(errors, createProduct, /organization_id\s*=\s*v_organization_id[\s\S]{0,120}?request_id\s*=\s*p_request_id/i, 'alta de producto idempotente por tenant');
  need(errors, createProduct, /organization_id\s*=\s*v_organization_id[\s\S]{0,180}?upper\(trim\(coalesce\(codigo,''\)\)\)\s*=\s*v_codigo/i, 'SKU de alta compara sólo tenant actual');

  const updateProduct = fnBlock(productUpdate, 'public.actualizar_producto_seguro_v1(');
  need(errors, updateProduct, /private\.require_current_organization_id\(\)/i, 'edición deriva tenant');
  need(errors, updateProduct, /private\.assert_product_in_current_organization\(p_producto_id\)/i, 'edición valida producto tenant');
  need(errors, updateProduct, /p\.organization_id\s*=\s*v_organization_id[\s\S]{0,220}?upper\(trim\(coalesce\(p\.codigo,''\)\)\)\s*=\s*v_codigo/i, 'edición SKU única dentro del tenant');
  need(errors, updateProduct, /m\.organization_id\s*=\s*v_organization_id[\s\S]{0,120}?m\.producto_id\s*=\s*p_producto_id/i, 'aperturas sólo tenant actual');

  if (/\bapp_empleado_activo\s*\(|FROM\s+public\.empleados[\s\S]{0,220}?auth_id\s*=\s*auth\.uid\(\)/i.test(rpc)) {
    errors.push('Los RPC nuevos de F3.4 no deben reintroducir autorización por empleado legacy');
  }
  return errors;
}

function selfTest() {
  const schema = read(schemaName);
  const rpc = read(rpcName);
  const update = read(productUpdateName);
  const validErrors = verify(schema, rpc, update);
  if (validErrors.length) {
    console.error('SaaS inventory self-test FAILED (contrato válido rechazado):');
    for (const error of validErrors) console.error(`  - ${error}`);
    process.exit(1);
  }

  const badMinUuid = mutate(
    schema,
    /SELECT\s+organization_id\s+INTO\s+v_fallback_organization_id\s+FROM\s+public\.configuracion_negocio\s+WHERE\s+organization_id\s+IS\s+NOT\s+NULL\s+ORDER\s+BY\s+organization_id::text\s+LIMIT\s+1;/i,
    `SELECT min(organization_id)\n    INTO v_fallback_organization_id\n    FROM public.configuracion_negocio\n    WHERE organization_id IS NOT NULL;`,
    'min uuid incompatible',
  );

  const badLotFk = mutate(
    schema,
    /inventory_lots_organization_product_fkey/i,
    'inventory_lots_product_only_fkey',
    'sin FK lote/producto tenant',
  );

  const badWarehouseAssertion = mutate(
    rpc,
    /PERFORM\s+private\.assert_warehouse_in_current_organization\(nullif\(v_item->>'almacen_id',''\)::bigint\);/i,
    'PERFORM 1;',
    'ingreso sin warehouse assertion',
  );

  const badGlobalSkuUpdate = mutate(
    update,
    /WHERE\s+p\.organization_id\s*=\s*v_organization_id\s+AND\s+p\.id\s*<>\s*p_producto_id\s+AND\s+upper\(trim\(coalesce\(p\.codigo,''\)\)\)\s*=\s*v_codigo/i,
    `WHERE p.id<>p_producto_id\n      AND upper(trim(coalesce(p.codigo,'')))=v_codigo`,
    'edición con SKU global',
  );

  const cases = [
    ['min uuid incompatible', [badMinUuid, rpc, update]],
    ['sin FK lote/producto tenant', [badLotFk, rpc, update]],
    ['ingreso sin warehouse assertion', [schema, badWarehouseAssertion, update]],
    ['edición con SKU global', [schema, rpc, badGlobalSkuUpdate]],
  ];
  const missed = [];
  for (const [name, triple] of cases) {
    if (verify(...triple).length === 0) missed.push(name);
  }
  if (missed.length) {
    console.error('SaaS inventory self-test FAILED:');
    for (const name of missed) console.error(`  - no detectó ${name}`);
    process.exit(1);
  }
  console.log(`SaaS inventory self-test OK (${cases.length + 1} contratos/casos).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify(read(schemaName), read(rpcName), read(productUpdateName));
if (errors.length) {
  console.error('SaaS inventory gate FAILED:');
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}
console.log(`SaaS inventory gate OK: ${schemaName} + ${rpcName} + ${productUpdateName}`);
