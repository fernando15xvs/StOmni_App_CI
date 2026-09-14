import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const reportPath = path.join(root, '.dart_tool', 'saas', 't02-ci-report.json');

const tests = [
  ['verify_no_new_singletons.mjs', true],
  ['verify_saas_foundation.mjs', true],
  ['verify_saas_bootstrap.mjs', true],
  ['verify_saas_authorization.mjs', true],
  ['verify_saas_rls.mjs', true],
  ['verify_saas_rpc_transversal.mjs', true],
  ['verify_saas_domain_configuration.mjs', true],
  ['verify_saas_customers_suppliers.mjs', true],
  ['verify_saas_catalog_foundation.mjs', true],
  ['verify_saas_inventory.mjs', true],
  ['verify_saas_inventory_runtime.mjs', true],
  ['verify_saas_inventory_surface.mjs', true],
  ['verify_saas_sales.mjs', true],
  ['verify_saas_purchases.mjs', true],
  ['verify_saas_fiscal.mjs', true],
  ['verify_saas_branches.mjs', true],
  ['verify_saas_warehouse_branches.mjs', true],
  ['verify_saas_cash_registers.mjs', true],
  ['verify_saas_employees_structure.mjs', true],
  ['verify_saas_configurable_roles.mjs', true],
  ['verify_saas_adaptability_block.mjs', true],
  ['verify_saas_intelligence_block.mjs', false],
  ['verify_saas_billing_block.mjs', false],
  ['verify_saas_organization_signup.mjs', true],
  ['verify_saas_guided_onboarding.mjs', true],
  ['verify_saas_onboarding_ux.mjs', true],
  ['verify_saas_business_branding.mjs', true],
  ['verify_saas_multi_tenant_e2e.mjs', true],
  ['verify_saas_load_concurrency.mjs', true],
  ['verify_saas_backup_recovery.mjs', true],
  ['verify_saas_observability.mjs', true],
  ['verify_saas_final_security.mjs', true],
  ['verify_saas_release_readiness.mjs', true],
  ['verify_saas_edge_functions.mjs', true],
  ['verify_saas_rpc_surface.mjs', true],
];

function runNode(args) {
  const result = spawnSync(process.execPath, args, {
    cwd: root,
    encoding: 'utf8',
    env: process.env,
  });
  if (result.stdout) process.stdout.write(result.stdout);
  if (result.stderr) process.stderr.write(result.stderr);
  return {
    status: result.status ?? 1,
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? '',
  };
}

const results = [];
for (const [script, selfTest] of tests) {
  const relative = path.join('scripts', script);
  const absolute = path.join(root, relative);
  console.log(`\n==================================================`);
  console.log(`T02 CI -> ${script}`);
  console.log(`==================================================`);

  const entry = { script, node_check: null, self_test: null, gate: null, ok: false };
  if (!fs.existsSync(absolute)) {
    entry.node_check = { status: 1, error: 'SCRIPT_NO_EXISTE' };
    results.push(entry);
    console.error(`Falta ${relative}`);
    continue;
  }

  console.log('>>> NODE --CHECK');
  entry.node_check = runNode(['--check', absolute]);
  if (entry.node_check.status !== 0) {
    results.push(entry);
    continue;
  }

  if (selfTest) {
    console.log('>>> SELF-TEST');
    entry.self_test = runNode([absolute, '--self-test']);
  }

  console.log('>>> GATE NORMAL');
  entry.gate = runNode([absolute]);
  entry.ok = entry.node_check.status === 0
    && (!selfTest || entry.self_test?.status === 0)
    && entry.gate.status === 0;
  results.push(entry);
}

const failures = results.filter((result) => !result.ok);
const report = {
  generated_at: new Date().toISOString(),
  git_sha: process.env.GITHUB_SHA ?? null,
  total: results.length,
  passed: results.length - failures.length,
  failed: failures.length,
  results: results.map((result) => ({
    script: result.script,
    ok: result.ok,
    node_check_status: result.node_check?.status ?? null,
    self_test_status: result.self_test?.status ?? null,
    gate_status: result.gate?.status ?? null,
  })),
};
fs.mkdirSync(path.dirname(reportPath), { recursive: true });
fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);

console.log('\n==================================================');
console.log(`T02 RESULTADO: ${report.passed}/${report.total} gates completos`);
if (failures.length) {
  console.error(`T02 FALLÓ en ${failures.length} script(s):`);
  for (const failure of failures) {
    console.error(
      `  - ${failure.script}: check=${failure.node_check?.status ?? '-'} self=${failure.self_test?.status ?? '-'} gate=${failure.gate?.status ?? '-'}`,
    );
  }
  process.exit(1);
}
console.log('T02 COMPLETO: VERDE');
