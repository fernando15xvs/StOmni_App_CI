import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { loadLocalSupabaseConfig, psql } from './saas_backup_common.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const e2ePath = path.join(root, 'supabase', 'tests', 'e2e', 'multi_tenant_e2e.mjs');
const reportPath = path.join(root, '.dart_tool', 'saas', 'f9_1_e2e_report.json');

const result = spawnSync(process.execPath, [e2ePath], {
  cwd: root,
  encoding: 'utf8',
  env: process.env,
});

if (result.stdout) process.stdout.write(result.stdout);
if (result.stderr) process.stderr.write(result.stderr);
if ((result.status ?? 1) !== 0) {
  process.exit(result.status ?? 1);
}

const config = loadLocalSupabaseConfig();

function latestOrganizationId(label) {
  const escaped = label.replaceAll("'", "''");
  return psql(
    config.dbUrl,
    `SELECT id::text
       FROM public.organizations
      WHERE display_name LIKE 'StOmni E2E ${escaped} %'
      ORDER BY created_at DESC NULLS LAST, id DESC
      LIMIT 1;`,
  );
}

const orgA = latestOrganizationId('ORG_A');
const orgB = latestOrganizationId('ORG_B');
if (!orgA || !orgB || orgA === orgB) {
  throw new Error('No se pudieron resolver dos organizaciones E2E distintas para evidencia CI.');
}

const scenarioIds = [
  'E2E-01-local-only',
  'E2E-02-auth-a-b-parallel',
  'E2E-03-self-service-signup-a-b',
  'E2E-04-onboarding-a-b-parallel',
  'E2E-05-customer-crud-a-b',
  'E2E-06-cross-tenant-read-blocked',
  'E2E-07-cross-tenant-update-blocked',
  'E2E-08-cross-tenant-delete-blocked',
  'E2E-09-organization-id-spoof-blocked',
  'E2E-10-onboarding-cross-tenant-filter-blocked',
];

const report = {
  generated_at: new Date().toISOString(),
  git_sha: process.env.GITHUB_SHA ?? null,
  source: 'supabase/tests/e2e/multi_tenant_e2e.mjs',
  result: 'PASS',
  scenario_count: scenarioIds.length,
  scenarios: scenarioIds,
  organizations: {
    ORG_A: orgA,
    ORG_B: orgB,
  },
  contains_secrets: false,
  note: 'Reporte sanitizado: no contiene JWT, passwords, anon/service-role keys ni credenciales.',
};

fs.mkdirSync(path.dirname(reportPath), { recursive: true });
fs.writeFileSync(reportPath, `${JSON.stringify(report, null, 2)}\n`);
console.log(`Evidencia E2E CI escrita en ${path.relative(root, reportPath)}.`);
