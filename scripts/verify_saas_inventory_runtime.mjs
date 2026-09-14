import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const files = {
  repository: path.join(root, 'packages/core_logic/lib/features/almacen/data/almacen_repository.dart'),
  admin: path.join(root, 'packages/core_logic/lib/features/almacen/data/almacen_admin_repository.dart'),
  productAdmin: path.join(root, 'packages/core_logic/lib/features/almacen/data/producto_admin_repository.dart'),
  inventoryService: path.join(root, 'packages/core_logic/lib/services/inventario_service.dart'),
};

function verify(sources) {
  const errors = [];
  for (const [name, source] of Object.entries(sources)) {
    if (/\.from\(['"]empleados['"]\)[\s\S]{0,260}?\.eq\(['"]auth_id['"]/i.test(source)) {
      errors.push(`${name}: autorización todavía depende de empleados.auth_id`);
    }
  }

  for (const name of ['repository', 'admin', 'productAdmin']) {
    if (!sources[name].includes("rpc('get_my_tenant_context_v1')")) {
      errors.push(`${name}: falta contexto SaaS canónico`);
    }
  }

  if (/\.from\(['"]inventario_almacen['"]\)\s*\.upsert\s*\(/i.test(sources.repository)) {
    errors.push('repository: no se permite upsert directo sobre saldo de inventario');
  }
  if (!sources.repository.includes('InventarioService.ajustarStock(')) {
    errors.push('repository: la compatibilidad de ajuste debe delegar al RPC autoritativo');
  }

  if (!sources.repository.includes("'$organizationId/products/producto_")) {
    errors.push('repository: upload legacy no usa namespace organization_id/products');
  }
  if (!sources.productAdmin.includes("'$organizationId/products/")) {
    errors.push('productAdmin: upload no usa namespace organization_id/products');
  }

  for (const rpc of [
    'registrar_ingreso_mercaderia_scaled_v2',
    'ajustar_stock_scaled_v2',
    'registrar_merma_scaled_v4',
    'trasladar_stock_scaled_v4',
  ]) {
    if (!sources.inventoryService.includes(`'${rpc}'`)) {
      errors.push(`inventoryService: falta entrypoint vigente ${rpc}`);
    }
  }

  return errors;
}

function readSources() {
  return Object.fromEntries(
    Object.entries(files).map(([name, file]) => {
      if (!fs.existsSync(file)) throw new Error(`Falta runtime: ${file}`);
      return [name, fs.readFileSync(file, 'utf8')];
    }),
  );
}

function selfTest() {
  const valid = {
    repository: "rpc('get_my_tenant_context_v1'); InventarioService.ajustarStock(); '$organizationId/products/producto_';",
    admin: "rpc('get_my_tenant_context_v1');",
    productAdmin: "rpc('get_my_tenant_context_v1'); '$organizationId/products/';",
    inventoryService: "'registrar_ingreso_mercaderia_scaled_v2' 'ajustar_stock_scaled_v2' 'registrar_merma_scaled_v4' 'trasladar_stock_scaled_v4'",
  };
  if (verify(valid).length) {
    console.error('SaaS inventory runtime self-test FAILED (fixture válida rechazada)');
    process.exit(1);
  }

  const cases = [
    ['empleado legacy', {...valid, admin: `${valid.admin} .from('empleados').select('rol').eq('auth_id', user.id)`}],
    ['upsert directo', {...valid, repository: `${valid.repository} .from('inventario_almacen').upsert({})`}],
    ['upload global', {...valid, productAdmin: "rpc('get_my_tenant_context_v1'); upload('producto.jpg')"}],
  ];
  const missed = cases.filter(([, fixture]) => verify(fixture).length===0).map(([name]) => name);
  if (missed.length) {
    console.error('SaaS inventory runtime self-test FAILED:');
    for (const name of missed) console.error(`  - no detectó ${name}`);
    process.exit(1);
  }
  console.log(`SaaS inventory runtime self-test OK (${cases.length + 1} casos).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify(readSources());
if (errors.length) {
  console.error('SaaS inventory runtime gate FAILED:');
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}
console.log('SaaS inventory runtime gate OK.');
