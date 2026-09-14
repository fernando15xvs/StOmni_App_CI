import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrationName = '20260907235417_saas_inventory_surface_lockdown.sql';

function readMigration() {
  const file = path.join(root, 'supabase', 'migrations', migrationName);
  if (!fs.existsSync(file)) throw new Error(`Falta migración: ${migrationName}`);
  return fs.readFileSync(file, 'utf8');
}

function fnBlock(source, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return source.match(new RegExp(`CREATE\\s+(?:OR\\s+REPLACE\\s+)?FUNCTION\\s+${escaped}[\\s\\S]*?\\$\\$;`, 'i'))?.[0] ?? '';
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
  const need = (regex, label) => {
    if (!regex.test(source)) errors.push(`Falta: ${label}`);
  };

  need(/ALTER FUNCTION\s+public\.evaluar_eliminacion_producto_v1\(bigint\)[\s\S]{0,80}?RENAME TO\s+_legacy_evaluar_eliminacion_producto_v1/i, 'privatizar evaluación legacy');
  need(/ALTER FUNCTION\s+public\.eliminar_producto_seguro_v1\(bigint\)[\s\S]{0,80}?RENAME TO\s+_legacy_eliminar_producto_seguro_v1/i, 'privatizar eliminación legacy');

  for (const legacy of [
    '_legacy_evaluar_eliminacion_producto_v1',
    '_legacy_eliminar_producto_seguro_v1',
  ]) {
    need(new RegExp(`REVOKE ALL ON FUNCTION\\s+public\\.${legacy}\\(bigint\\)[\\s\\S]{0,80}?FROM\\s+PUBLIC,\\s*anon,\\s*authenticated`, 'i'), `${legacy} sin EXECUTE cliente`);
  }

  for (const wrapper of [
    'public.evaluar_eliminacion_producto_v1(',
    'public.eliminar_producto_seguro_v1(',
  ]) {
    const block = fnBlock(source, wrapper);
    if (!block) {
      errors.push(`Falta wrapper: ${wrapper}`);
      continue;
    }
    if (!/private\.has_permission\('tenant\.admin'\)/i.test(block)) errors.push(`${wrapper} debe exigir tenant.admin`);
    if (!/private\.assert_product_in_current_organization\(p_producto_id\)/i.test(block)) errors.push(`${wrapper} debe validar producto del tenant`);
    if (!/SET search_path\s*=\s*''/i.test(block)) errors.push(`${wrapper} debe fijar search_path vacío`);
  }

  const blocked = [
    'ajustar_stock_y_kardex',
    'registrar_ingreso_mercaderia_v2',
    'registrar_merma_v2',
    'registrar_merma_scaled_v2',
    'registrar_merma_scaled_v3',
    'trasladar_stock_v2',
    'trasladar_stock_scaled_v2',
    'trasladar_stock_scaled_v3',
  ];
  for (const name of blocked) {
    need(new RegExp(`REVOKE ALL ON FUNCTION\\s+public\\.${name}\\([\\s\\S]{0,260}?\\)\\s+FROM\\s+PUBLIC,\\s*anon,\\s*authenticated`, 'i'), `${name} fuera de Data API`);
    if (new RegExp(`GRANT\\s+EXECUTE\\s+ON\\s+FUNCTION\\s+public\\.${name}\\(`, 'i').test(source)) {
      errors.push(`${name} no debe recibir GRANT EXECUTE`);
    }
  }

  const allowed = [
    'ajustar_stock_scaled_v2',
    'registrar_ingreso_mercaderia_scaled_v2',
    'registrar_merma_scaled_v4',
    'trasladar_stock_scaled_v4',
    'crear_producto_con_stock',
    'actualizar_producto_seguro_v1',
    'evaluar_eliminacion_producto_v1',
    'eliminar_producto_seguro_v1',
    'save_service_v1',
    'register_traceable_merchandise_receipt_v1',
  ];
  for (const name of allowed) {
    need(new RegExp(`GRANT\\s+EXECUTE\\s+ON\\s+FUNCTION\\s+public\\.${name}\\([\\s\\S]{0,260}?\\)\\s+TO\\s+authenticated`, 'i'), `${name} allowlist authenticated`);
  }

  return errors;
}

function selfTest() {
  const valid = readMigration();
  const validErrors = verify(valid);
  if (validErrors.length) {
    console.error('SaaS inventory surface self-test FAILED (contrato válido rechazado):');
    for (const error of validErrors) console.error(`  - ${error}`);
    process.exit(1);
  }

  const mutations = [
    [
      'legacy merma reexpuesta',
      mutated(
        valid,
        /REVOKE ALL ON FUNCTION public\.registrar_merma_scaled_v3\(/i,
        'GRANT EXECUTE ON FUNCTION public.registrar_merma_scaled_v3(',
        'legacy merma reexpuesta',
      ),
    ],
    [
      'eliminación sin assert tenant',
      mutated(
        valid,
        /PERFORM\s+private\.assert_product_in_current_organization\(p_producto_id\);\s*\r?\n\s*RETURN\s+public\._legacy_eliminar_producto_seguro_v1/i,
        'PERFORM 1;\n  RETURN public._legacy_eliminar_producto_seguro_v1',
        'eliminación sin assert tenant',
      ),
    ],
    [
      'sin grant wrapper eliminación',
      mutated(
        valid,
        /GRANT EXECUTE ON FUNCTION public\.eliminar_producto_seguro_v1\(bigint\)[\s\S]{0,30}?TO authenticated;/i,
        '',
        'sin grant wrapper eliminación',
      ),
    ],
  ];

  const missed = [];
  for (const [name, candidate] of mutations) {
    if (verify(candidate).length === 0) missed.push(name);
  }
  if (missed.length) {
    console.error('SaaS inventory surface self-test FAILED:');
    for (const name of missed) console.error(`  - no detectó ${name}`);
    process.exit(1);
  }

  console.log(`SaaS inventory surface self-test OK (${mutations.length + 1} contratos/casos).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify(readMigration());
if (errors.length) {
  console.error('SaaS inventory surface gate FAILED:');
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}
console.log(`SaaS inventory surface gate OK: ${migrationName}`);
