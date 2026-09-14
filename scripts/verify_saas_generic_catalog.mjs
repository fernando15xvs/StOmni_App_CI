import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrationFiles = [
  'supabase/migrations/20260908044000_saas_generic_catalog_item_types_bundles.sql',
  'supabase/migrations/20260908044100_saas_generic_catalog_bundle_safety.sql',
];
const dartFiles = [
  'packages/core_logic/lib/features/catalogo/domain/catalog_item_type.dart',
  'packages/core_logic/lib/features/almacen/domain/producto.dart',
  'packages/core_logic/lib/features/almacen/data/producto_mapper.dart',
  'packages/core_logic/lib/features/shared/models/producto_busqueda.dart',
  'packages/core_logic/lib/features/almacen/data/almacen_sync_contract.dart',
  'packages/core_logic/lib/features/almacen/data/local_db_service.dart',
];
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const sql = () => migrationFiles.map(read).join('\n');
const dart = () => dartFiles.map(read).join('\n');

function need(errors, source, regex, label) {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
}

function mutated(source, regex, replacement, label) {
  const next = source.replace(regex, replacement);
  if (next === source) {
    throw new Error(`Self-test fixture no pudo mutar: ${label}`);
  }
  return next;
}

function lastFnBlock(source, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const matches = [...source.matchAll(new RegExp(`CREATE\\s+OR\\s+REPLACE\\s+FUNCTION\\s+${escaped}[\\s\\S]*?\\$\\$;`, 'ig'))];
  return matches.at(-1)?.[0] ?? '';
}

function verify(sqlSource, dartSource) {
  const errors = [];
  need(errors, sqlSource, /ADD COLUMN item_type text NOT NULL DEFAULT 'stock_product'/i, 'productos.item_type');
  need(errors, sqlSource, /item_type IN \('stock_product','non_stock_product','service','bundle'\)/i, 'allowlist item_type');
  need(errors, sqlSource, /CREATE TABLE public\.bundle_components/i, 'tabla bundle_components');
  need(errors, sqlSource, /PRIMARY KEY\(organization_id,bundle_product_id,component_product_id\)/i, 'PK bundle tenant-aware');
  need(errors, sqlSource, /FOREIGN KEY\(organization_id,bundle_product_id\)[\s\S]{0,120}?REFERENCES public\.productos\(organization_id,id\)/i, 'bundle -> producto tenant-qualified');
  need(errors, sqlSource, /FOREIGN KEY\(organization_id,component_product_id\)[\s\S]{0,120}?REFERENCES public\.productos\(organization_id,id\)/i, 'componente -> producto tenant-qualified');
  need(errors, sqlSource, /CREATE POLICY bundle_components_tenant_select[\s\S]{0,220}?row_belongs_to_current_organization\(organization_id\)/i, 'RLS bundle tenant');
  need(errors, sqlSource, /CREATE OR REPLACE FUNCTION public\.set_bundle_components_v1/i, 'RPC componentes bundle');
  need(errors, sqlSource, /CREATE OR REPLACE FUNCTION public\.set_catalog_item_type_v1/i, 'RPC item_type');
  need(errors, sqlSource, /private\.has_permission\('tenant\.admin'\)/i, 'mutaciones catálogo requieren tenant.admin');
  need(errors, sqlSource, /Cannot convert a stocked item to a non-stock catalog type/i, 'transición con stock bloqueada');
  need(errors, sqlSource, /Nested bundles are not supported/i, 'bundles anidados bloqueados');

  // validate_bundle_component() se redefine en 08044100. La seguridad efectiva
  // debe comprobarse en la última definición, no por la mera presencia del texto
  // de error en cualquier migración anterior.
  const bundleValidation = lastFnBlock(sqlSource, 'private.validate_bundle_component(');
  need(errors, bundleValidation, /IF\s+v_component_type\s*=\s*'stock_product'\s+AND\s+v_trace_mode\s*<>\s*'none'\s+THEN/i, 'componente trazable queda bloqueado por condición efectiva');
  need(errors, bundleValidation, /Traceable stock products are not supported as bundle components/i, 'componente trazable devuelve rechazo explícito');

  need(errors, sqlSource, /Bundles are temporarily limited to internal tickets/i, 'bundle fiscal fail-closed');
  need(errors, sqlSource, /ADD COLUMN bundle_components_snapshot jsonb/i, 'snapshot inmutable de componentes');
  need(errors, sqlSource, /CREATE TRIGGER detalle_ventas_consume_bundle_components[\s\S]{0,100}?BEFORE INSERT ON public\.detalle_ventas/i, 'consumo transaccional bundle');
  need(errors, sqlSource, /CREATE TRIGGER detalle_ventas_restore_bundle_components[\s\S]{0,100}?BEFORE DELETE ON public\.detalle_ventas/i, 'restauración por anulación');
  need(errors, sqlSource, /ventas_requests_anulados[\s\S]{0,180}?venta_id_original=OLD\.venta_id/i, 'restauración sólo con evidencia de anulación');
  need(errors, sqlSource, /ON CONFLICT\(producto_id,almacen_id\)/i, 'ON CONFLICT compatible con F3.4');

  // No-stock tiene dos garantías complementarias:
  // 1) normalización del producto a stock_minimo=0;
  // 2) toda fila de inventario de esos tipos se fuerza a cantidad=0, y al
  //    cambiar item_type el RPC limpia cualquier fila histórica del tenant.
  need(errors, sqlSource, /(?:item_type|v_target_type)\s+IN\s*\('non_stock_product','service','bundle'\)[\s\S]{0,220}?NEW\.stock_minimo\s*:=\s*0(?:\.0+)?/i, 'no-stock fuerza stock_minimo cero');
  need(errors, sqlSource, /CREATE OR REPLACE FUNCTION public\._item_type_zero_inventory_v1\(\)[\s\S]{0,900}?v_type\s+IN\s*\('non_stock_product','service','bundle'\)[\s\S]{0,120}?NEW\.cantidad\s*:=\s*0(?:\.0+)?/i, 'trigger no-stock siempre fuerza cantidad cero');
  need(errors, sqlSource, /CREATE OR REPLACE FUNCTION public\.set_catalog_item_type_v1\([\s\S]{0,2600}?UPDATE public\.inventario_almacen[\s\S]{0,160}?SET cantidad\s*=\s*0(?:\.0+)?[\s\S]{0,180}?WHERE organization_id\s*=\s*v_org AND producto_id\s*=\s*p_product_id/i, 'cambio a no-stock limpia inventario del tenant');
  need(errors, sqlSource, /item_type<>'stock_product'[\s\S]{0,160}?Only stock products can be received as inventory/i, 'compras sólo stock_product');

  need(errors, dartSource, /enum CatalogItemType[\s\S]{0,220}?stockProduct\('stock_product'\)[\s\S]{0,220}?nonStockProduct\('non_stock_product'\)[\s\S]{0,220}?service\('service'\)[\s\S]{0,220}?bundle\('bundle'\)/i, 'enum Dart item types');
  need(errors, dartSource, /final CatalogItemType itemType;/i, 'Producto carga itemType');
  need(errors, dartSource, /CatalogItemType\.fromCode\([\s\S]{0,120}?json\['item_type'\]/i, 'mapper decodifica item_type');
  need(errors, dartSource, /'item_type': product\.itemType\.code/i, 'mapper serializa item_type');
  need(errors, dartSource, /'es_servicio': product\.esServicio/i, 'compatibilidad es_servicio');
  need(errors, dartSource, /item_type,cantidad_por_caja/i, 'sync remoto solicita item_type');
  need(errors, dartSource, /version: 10/i, 'SQLite v10');
  need(errors, dartSource, /ALTER TABLE productos ADD COLUMN item_type TEXT NOT NULL DEFAULT 'stock_product'/i, 'migración SQLite item_type');
  need(errors, dartSource, /ALTER TABLE productos ADD COLUMN es_servicio INTEGER NOT NULL DEFAULT 0/i, 'migración SQLite es_servicio');

  if (/ON CONFLICT\(organization_id,producto_id,almacen_id\)/i.test(sqlSource.slice(sqlSource.lastIndexOf('CREATE OR REPLACE FUNCTION private.consume_bundle_components_on_sale_detail')))) {
    errors.push('El contrato final no debe usar ON CONFLICT compuesto inexistente en F3.4');
  }
  if (/v_component\.item_type='stock_product'[\s\S]{0,1600}?_consume_inventory_traceability_v1/i.test(sqlSource)) {
    errors.push('Bundle V1 no debe fingir consumo trazable sin selección explícita de lotes/series');
  }
  return errors;
}

function selfTest() {
  const validSql = sql();
  const validDart = dart();
  const cases = [
    ['válido', validSql, validDart, false],
    ['sin tenant bundle FK', mutated(validSql, /FOREIGN KEY\(organization_id,bundle_product_id\)/i, 'FOREIGN KEY(bundle_product_id)', 'sin tenant bundle FK'), validDart, true],
    ['bundle trazable abierto', mutated(validSql, /IF v_component_type='stock_product' AND v_trace_mode<>'none' THEN/i, 'IF false THEN', 'bundle trazable abierto'), validDart, true],
    ['cache v9', validSql, mutated(validDart, /version:\s*10/i, 'version: 9', 'cache v9'), true],
    ['mapper sin item type', validSql, mutated(validDart, /'item_type':\s*product\.itemType\.code,?/i, '', 'mapper sin item type'), true],
    ['no-stock trigger abierto', mutated(validSql, /IF v_type IN \('non_stock_product','service','bundle'\) THEN NEW\.cantidad:=0; END IF;/i, 'IF false THEN NEW.cantidad:=0; END IF;', 'no-stock trigger abierto'), validDart, true],
    ['no-stock sin limpieza tenant', mutated(validSql, /WHERE organization_id=v_org AND producto_id=p_product_id;/i, 'WHERE false;', 'no-stock sin limpieza tenant'), validDart, true],
  ];
  const failed = [];
  for (const [name, s, d, shouldFail] of cases) {
    const didFail = verify(s, d).length > 0;
    if (didFail !== shouldFail) failed.push(name);
  }
  if (failed.length) {
    console.error('SaaS generic catalog self-test FAILED:');
    failed.forEach((x) => console.error(`  - ${x}`));
    process.exit(1);
  }
  console.log(`SaaS generic catalog self-test OK (${cases.length} casos).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}
const errors = verify(sql(), dart());
if (errors.length) {
  console.error('SaaS generic catalog gate FAILED:');
  errors.forEach((e) => console.error(`  - ${e}`));
  process.exit(1);
}
console.log('SaaS generic catalog gate OK (F5.2).');