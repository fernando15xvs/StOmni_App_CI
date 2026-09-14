import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const gates = [
  'scripts/verify_saas_tenant_capabilities.mjs',
  'scripts/verify_saas_generic_catalog.mjs',
  'scripts/verify_saas_custom_fields.mjs',
  'scripts/verify_saas_dynamic_modules_ui.mjs',
];
const audits = [
  'docs/saas/23_FASE5_1_CAPACIDADES_POR_EMPRESA.md',
  'docs/saas/24_FASE5_2_CATALOGO_GENERICO.md',
  'docs/saas/25_FASE5_3_CAMPOS_REGLAS_CONFIGURABLES.md',
  'docs/saas/26_FASE5_4_UI_DINAMICA_MODULOS.md',
];

function verifyLayout() {
  const errors = [];
  for (const file of [...gates, ...audits]) {
    if (!fs.existsSync(path.join(root, file))) errors.push(`Falta ${file}`);
  }
  return errors;
}

function runGate(relativePath, extraArgs = []) {
  return spawnSync(process.execPath, [path.join(root, relativePath), ...extraArgs], {
    cwd: root,
    encoding: 'utf8',
    env: process.env,
  });
}

function execute({ selfTest = false } = {}) {
  const errors = verifyLayout();
  if (errors.length) return errors;
  for (const gate of gates) {
    const result = runGate(gate, selfTest ? ['--self-test'] : []);
    if (result.status !== 0) {
      errors.push(`${gate} falló${selfTest ? ' en self-test' : ''}`);
      const output = `${result.stdout ?? ''}\n${result.stderr ?? ''}`.trim();
      if (output) errors.push(output);
    }
  }
  return errors;
}

const selfTest = process.argv.includes('--self-test');
const errors = execute({ selfTest });
if (errors.length) {
  console.error(`SaaS adaptability block gate FAILED${selfTest ? ' (self-test)' : ''}:`);
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}

console.log(`SaaS adaptability block gate OK${selfTest ? ' (self-test)' : ''}.`);
console.log('  - F5.1 capacidades por empresa');
console.log('  - F5.2 catálogo genérico');
console.log('  - F5.3 campos/reglas configurables');
console.log('  - F5.4 UI dinámica por módulos');
