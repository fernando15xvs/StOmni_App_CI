import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const databaseDir = path.join(root, 'supabase', 'tests', 'database');
const reportPath = path.join(root, '.dart_tool', 'saas', 'current-pgtap-ci-report.json');

const historicalTests = new Set([
  'fase5_production_fingerprint_test.sql',
  'fase5_public_snapshot_fingerprint_test.sql',
]);

if (!fs.existsSync(databaseDir)) {
  console.error(`No existe ${path.relative(root, databaseDir)}.`);
  process.exit(1);
}

const files = fs
  .readdirSync(databaseDir, { withFileTypes: true })
  .filter((entry) => entry.isFile() && entry.name.endsWith('.sql'))
  .filter((entry) => !historicalTests.has(entry.name))
  .map((entry) => path.join('supabase', 'tests', 'database', entry.name).replaceAll('\\', '/'))
  .sort();

if (files.length === 0) {
  console.error('No se encontraron contratos pgTAP del esquema actual.');
  process.exit(1);
}

console.log(`Ejecutando ${files.length} contratos pgTAP del esquema actual.`);
console.log(`Excluidos por ser fingerprints históricos: ${[...historicalTests].join(', ')}`);

const command = process.platform === 'win32' ? 'supabase.exe' : 'supabase';
const result = spawnSync(command, ['test', 'db', '--local', ...files], {
  cwd: root,
  encoding: 'utf8',
  env: process.env,
});

if (result.stdout) process.stdout.write(result.stdout);
if (result.stderr) process.stderr.write(result.stderr);

const combined = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
const summaryMatch = combined.match(/Files=(\d+),\s*Tests=(\d+)/);
const report = {
  generated_at: new Date().toISOString(),
  git_sha: process.env.GITHUB_SHA ?? null,
  files_requested: files.length,
  historical_excluded: [...historicalTests],
  files_reported: summaryMatch ? Number(summaryMatch[1]) : null,
  assertions_reported: summaryMatch ? Number(summaryMatch[2]) : null,
  exit_code: result.status ?? 1,
  result: (result.status ?? 1) === 0 ? 'PASS' : 'FAIL',
};

fs.mkdirSync(path.dirname(reportPath), { recursive: true });
fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);

if ((result.status ?? 1) !== 0) {
  console.error('pgTAP del esquema actual: FAIL');
  process.exit(result.status ?? 1);
}

console.log(
  `pgTAP del esquema actual: PASS (${report.files_reported ?? files.length} archivos, ${report.assertions_reported ?? 'assertions no parseadas'} assertions).`,
);
