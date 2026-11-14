import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { execFileSync } from 'node:child_process';

import {
  ensure,
  loadLocalSupabaseConfig,
  parseEnvOutput,
  writeJson,
} from '../../../scripts/saas_backup_common.mjs';

const config = loadLocalSupabaseConfig({ requireServiceRole: false });
const env = parseEnvOutput(execFileSync('supabase', ['status', '-o', 'env'], {
  encoding: 'utf8',
  stdio: ['ignore', 'pipe', 'pipe'],
}));
const anonKey = process.env.SUPABASE_ANON_KEY ?? process.env.ANON_KEY ?? env.ANON_KEY;
ensure(anonKey, 'T10 requiere la llave pública anon del stack local.');

const repoRoot = path.resolve(import.meta.dirname, '../../..');
const toml = fs.readFileSync(path.join(repoRoot, 'supabase/config.toml'), 'utf8');
const sections = [...toml.matchAll(/^\[functions\.([a-zA-Z0-9_-]+)\]([\s\S]*?)(?=^\[functions\.|$(?![\s\S]))/gm)];
const slugs = sections.map(([, slug]) => slug);
ensure(slugs.length === 21 && new Set(slugs).size === slugs.length,
  `T10 esperaba 21 Edge Functions distintas, obtuvo ${slugs.length}.`);
for (const [, slug, block] of sections) {
  ensure(/^verify_jwt\s*=\s*true\s*$/m.test(block),
    `T10 función ${slug} no exige verify_jwt.`);
}

const fakeOrganization = '00000000-0000-0000-0000-00000000beef';
const attempts = [
  {
    label: 'sin JWT',
    headers: { apikey: anonKey, 'Content-Type': 'application/json' },
    body: '{}',
  },
  {
    label: 'JWT malformado con spoof de empresa',
    headers: {
      apikey: anonKey,
      Authorization: 'Bearer malformed.jwt.invalid',
      'Content-Type': 'application/json',
      'x-stomni-organization-id': fakeOrganization,
    },
    body: JSON.stringify({ organization_id: fakeOrganization }),
  },
];

async function check(slug, attempt) {
  const url = `${config.apiUrl}/functions/v1/${encodeURIComponent(slug)}`;
  const response = await fetch(url, {
    method: 'POST',
    headers: attempt.headers,
    body: attempt.body,
    signal: AbortSignal.timeout(15000),
  });
  // Authentication is rejected by the gateway before any Edge handler or
  // external fiscal/payment integration can be invoked.
  ensure([401, 403].includes(response.status),
    `T10 ${slug}: ${attempt.label} devolvió HTTP ${response.status} (se exigía 401/403).`);
}

for (let index = 0; index < slugs.length; index += 3) {
  const group = slugs.slice(index, index + 3);
  await Promise.all(group.flatMap((slug) => attempts.map((attempt) => check(slug, attempt))));
}

const reportPath = path.join(repoRoot, '.dart_tool/saas/t10_edge_jwt_boundary_report.json');
writeJson(reportPath, {
  result: 'PASS',
  scope: 'unauthenticated_and_malformed_jwt_only',
  source: 'supabase/tests/e2e/edge_jwt_boundary_e2e.mjs',
  generated_at: new Date().toISOString(),
  edge_functions_checked: slugs.length,
  invalid_auth_requests_denied: slugs.length * attempts.length,
  tenant_spoofing_before_auth_denied: slugs.length,
  local_only: true,
  contains_secrets: false,
  full_tenant_resource_authorization_certified: false,
});
console.log(`T10 Edge JWT gate: ${slugs.length} funciones, ${slugs.length * attempts.length} solicitudes inválidas rechazadas.`);
