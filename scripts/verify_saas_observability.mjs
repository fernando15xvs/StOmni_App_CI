import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8');
const exists = (relativePath) => fs.existsSync(path.join(root, relativePath));

const jobFunctions = new Set([
  'ejecutar-resumen-diario',
  'procesar-bajas-tributarias',
  'reintentar-comprobantes-pendientes',
  'reintentar-guias-pendientes',
  'reintentar-notas-credito-pendientes',
  'reintentar-procesos-tributarios-pendientes',
]);

const batchOutcomeFunctions = new Set([
  'reintentar-comprobantes-pendientes',
  'reintentar-guias-pendientes',
  'reintentar-notas-credito-pendientes',
  'reintentar-procesos-tributarios-pendientes',
]);

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function need(errors, condition, message) {
  if (!condition) errors.push(message);
}

function discoverEntrypoints(baseDir = path.join(root, 'supabase', 'functions')) {
  return fs.readdirSync(baseDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name !== '_shared')
    .map((entry) => entry.name)
    .filter((name) => fs.existsSync(path.join(baseDir, name, 'index.ts')))
    .sort();
}

export function validateEntrypoint(name, source) {
  const errors = [];
  const escaped = escapeRegex(name);
  need(errors,
    /from\s+['"]\.\.\/_shared\/observability\.ts['"]/.test(source),
    `${name}: no importa _shared/observability.ts`);
  need(errors,
    new RegExp(`serveObserved\\(\\s*['"]${escaped}['"]\\s*,`).test(source),
    `${name}: no usa serveObserved con componente estático igual al directorio`);

  if (jobFunctions.has(name)) {
    need(errors, /bindObservationJob\s*\(/.test(source),
      `${name}: job sin bindObservationJob()`);
    need(errors, /crypto\.randomUUID\s*\(\s*\)/.test(source),
      `${name}: job_id no se genera como UUID`);
    need(errors, /job_id\s*:/.test(source),
      `${name}: job_id no se devuelve para correlación`);
  }

  if (batchOutcomeFunctions.has(name)) {
    need(errors, /markObservationOutcome\s*\(/.test(source),
      `${name}: batch no puede distinguir skipped/fallo parcial`);
  }
  return errors;
}

function validateObservabilityHelper(errors, source) {
  const required = [
    ['x-stomni-trace-id', /x-stomni-trace-id/],
    ['UUID entrante validado', /UUID_RE[\s\S]*?normalizeTraceId/],
    ['UUID generado server-side', /crypto\.randomUUID\s*\(\s*\)/],
    ['bindObservationTenant', /export function bindObservationTenant/],
    ['bindObservationJob', /export function bindObservationJob/],
    ['markObservationOutcome', /export function markObservationOutcome/],
    ['serveObserved', /export function serveObserved/],
    ['writer RPC', /record_observability_event_v1/],
    ['fail-open persistence', /Observability is fail-open[\s\S]*?persist_failed/],
    ['console guard', /installConsoleGuard\s*\(\s*\)/],
    ['Bearer redaction', /Bearer \[redacted\]/],
    ['JWT redaction', /redacted-jwt/],
    ['email redaction', /redacted-email/],
    ['URL redaction', /redacted-url/],
    ['long-number redaction', /redacted-number/],
    ['object redaction', /redacted-object/],
    ['string length bound', /\.slice\(0, 400\)/],
    ['partial batch override', /errorCodeOverride/],
  ];
  for (const [label, expression] of required) {
    need(errors, expression.test(source), `observability.ts: falta ${label}`);
  }
  need(errors,
    !/console\.(?:log|warn|error)\([^\n]*,\s*error\s*\)/.test(source),
    'observability.ts: serializa un error crudo como argumento de consola');
}

function validateAuthGuard(errors, source) {
  need(errors, /import\s+\{\s*bindObservationTenant\s*\}\s+from\s+['"]\.\/observability\.ts['"]/.test(source),
    'auth_guard.ts no importa bindObservationTenant');
  const membership = source.indexOf(".from('app_users')");
  const org = source.indexOf('const organizationId =');
  const bind = source.indexOf('bindObservationTenant(req, organizationId)');
  need(errors, membership >= 0 && org > membership && bind > org,
    'auth_guard.ts enlaza observabilidad antes de resolver tenant server-side');
  need(errors, /membership\?\.status !== 'active'[\s\S]*?organization\?\.status !== 'active'/.test(source),
    'auth_guard.ts no valida membresía/organización activas antes del contexto');
}

function validateMigration(errors, source) {
  const checks = [
    ['ledger', /create table public\.observability_events/i],
    ['RLS', /alter table public\.observability_events enable row level security/i],
    ['revocación authenticated', /revoke all on table public\.observability_events from[\s\S]*?authenticated/i],
    ['writer', /record_observability_event_v1/i],
    ['writer SECURITY DEFINER', /create or replace function public\.record_observability_event_v1[\s\S]*?security definer/i],
    ['writer revocado a clientes', /revoke all on function public\.record_observability_event_v1[\s\S]*?from public,anon,authenticated/i],
    ['writer service_role', /grant execute on function public\.record_observability_event_v1[\s\S]*?to service_role/i],
    ['métricas tenant-safe', /get_observability_metrics_v1/i],
    ['errores tenant-safe', /list_recent_observability_errors_v1/i],
    ['tenant.admin', /tenant\.admin/i],
    ['p50', /percentile_cont\(0\.50\)/i],
    ['p95', /percentile_cont\(0\.95\)/i],
    ['p99', /percentile_cont\(0\.99\)/i],
  ];
  for (const [label, expression] of checks) {
    need(errors, expression.test(source), `migración observability: falta ${label}`);
  }

  const writerStart = source.search(/create or replace function public\.record_observability_event_v1/i);
  const metricsStart = source.search(/create or replace function public\.get_observability_metrics_v1/i);
  const writerBody = writerStart >= 0
    ? source.slice(writerStart, metricsStart > writerStart ? metricsStart : undefined)
    : '';
  need(errors,
    !/current_user\s*(?:=|<>|!=)\s*['"]service_role['"]/i.test(writerBody),
    'migración observability: writer SECURITY DEFINER no debe autorizar mediante current_user=service_role');
}

function validateContracts(errors, { pgTap, audit, map, checklist }) {
  need(errors, /SELECT plan\(22\)/.test(pgTap),
    'observability_contract_test.sql no conserva plan(22)');
  need(errors, /observability_events[\s\S]*?RLS/i.test(pgTap),
    'pgTAP no cubre RLS del ledger');
  need(errors, /authenticated no puede ejecutar writer/i.test(pgTap),
    'pgTAP no bloquea writer para authenticated');
  need(errors, /SECURITY DEFINER y autorización por EXECUTE/.test(pgTap),
    'pgTAP no congela el modelo correcto de autorización del writer');
  need(errors, /p50\/p95\/p99|p50.*p95.*p99/is.test(pgTap),
    'pgTAP no congela percentiles');

  need(errors, /IMPLEMENTADA \/ VALIDACIÓN DINÁMICA LOCAL PENDIENTE/.test(audit),
    'auditoría F9.4 no separa implementación de runtime');
  need(errors, /autorización[\s\S]*?privilegios PostgreSQL de `EXECUTE`[\s\S]*?no mediante `current_user`/i.test(audit),
    'auditoría F9.4 no documenta correctamente SECURITY DEFINER/EXECUTE');
  need(errors, /## 8\. Alertas de servicio[\s\S]*?SERVICE_TELEMETRY_DEGRADED[\s\S]*?BATCH_PARTIAL_FAILURE/.test(audit),
    'auditoría F9.4 no define alertas de servicio');
  need(errors, /TENANT_ISOLATION_VIOLATION[\s\S]*?PII_SECRET_LOG_EXPOSURE/.test(audit),
    'auditoría F9.4 no define alertas de seguridad release-blocking');
  need(errors, /no se fija[\s\S]*?umbral|no se fija[\s\S]*?porcentaje/i.test(audit),
    'auditoría F9.4 inventa o deja ambiguos umbrales no medidos');

  need(errors,
    /node scripts\/verify_saas_observability\.mjs --self-test[\s\S]*?node scripts\/verify_saas_observability\.mjs/.test(map),
    'T02 no incorpora gate de observabilidad');
  need(errors, /observability_contract_test\.sql/.test(map),
    'T04 no incorpora pgTAP de observabilidad');
  need(errors, /# T16[\s\S]*?x-stomni-trace-id[\s\S]*?BATCH_PARTIAL_FAILURE/i.test(map),
    'T16 no incorpora correlación y fallo parcial F9.4');
  need(errors, /# T16[\s\S]*?ORG_A[\s\S]*?ORG_B[\s\S]*?PII/i.test(map),
    'T16 no exige aislamiento A/B y revisión de PII');
  need(errors, /# T19[\s\S]*?p50[\s\S]*?p95[\s\S]*?p99/i.test(map),
    'T19 no conserva evidencia de percentiles F9.4');

  need(errors, /\[x\] \*\*Fase 9\.4 — Observabilidad\*\*/.test(checklist),
    'checklist no registra F9.4 implementada');
  need(errors, /\[x\] Configurar logs y métricas\./.test(checklist),
    'checklist F9.4: logs/métricas sigue abierto');
  need(errors, /\[x\] Definir filtros por tenant para soporte\./.test(checklist),
    'checklist F9.4: filtros tenant sigue abierto');
  need(errors, /\[x\] Evitar PII innecesaria en logs\./.test(checklist),
    'checklist F9.4: PII sigue abierto');
  need(errors, /\[x\] Definir alertas de servicio\./.test(checklist),
    'checklist F9.4: alertas sigue abierto');
  need(errors, /\[ \] \*\*GATE BLOQUE 9 VERDE\*\*/.test(checklist),
    'Gate Bloque 9 se cerró antes de validación dinámica/fases restantes');
}

function verify() {
  const errors = [];
  const functionsDir = path.join(root, 'supabase', 'functions');
  const entrypoints = discoverEntrypoints(functionsDir);
  need(errors, entrypoints.length > 0, 'no se descubrieron Edge Functions');

  for (const name of entrypoints) {
    const source = fs.readFileSync(path.join(functionsDir, name, 'index.ts'), 'utf8');
    errors.push(...validateEntrypoint(name, source));
  }

  const helper = read('supabase/functions/_shared/observability.ts');
  const authGuard = read('supabase/functions/_shared/auth_guard.ts');
  const migration = read('supabase/migrations/20260908059400_saas_observability.sql');
  const pgTap = read('supabase/tests/database/observability_contract_test.sql');
  const audit = read('docs/saas/43_FASE9_4_OBSERVABILIDAD.md');
  const map = read('docs/saas/99_MAPA_MAESTRO_PRUEBAS_SAAS.md');
  const checklist = read('docs/ROADMAP_SAAS_MULTI_TENANT_CHECKLIST.md');

  validateObservabilityHelper(errors, helper);
  validateAuthGuard(errors, authGuard);
  validateMigration(errors, migration);
  validateContracts(errors, { pgTap, audit, map, checklist });

  return { errors, entrypoints };
}

function selfTest() {
  const valid = `
    import { bindObservationJob, markObservationOutcome, serveObserved } from '../_shared/observability.ts'
    Deno.serve(serveObserved('reintentar-comprobantes-pendientes', async (req) => {
      const jobId = crypto.randomUUID(); bindObservationJob(req, jobId)
      markObservationOutcome(req, 'failed', 'BATCH_PARTIAL_FAILURE')
      return Response.json({ job_id: jobId })
    }))`;
  const validErrors = validateEntrypoint('reintentar-comprobantes-pendientes', valid);
  if (validErrors.length) {
    console.error('SaaS observability gate self-test positivo FAILED:', validErrors);
    process.exit(1);
  }

  const invalid = `Deno.serve(async () => Response.json({ ok: true }))`;
  const invalidErrors = validateEntrypoint('reintentar-comprobantes-pendientes', invalid);
  if (invalidErrors.length < 5) {
    console.error('SaaS observability gate self-test negativo FAILED:', invalidErrors);
    process.exit(1);
  }

  const unrelated = `
    import { serveObserved } from '../_shared/observability.ts'
    Deno.serve(serveObserved('consultar-comprobante', async () => Response.json({ ok: true })))`;
  if (validateEntrypoint('consultar-comprobante', unrelated).length) {
    console.error('SaaS observability gate self-test entrypoint normal FAILED');
    process.exit(1);
  }

  console.log(`SaaS observability gate self-test OK (${invalidErrors.length} fallos inseguros detectados).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

for (const requiredPath of [
  'supabase/functions/_shared/observability.ts',
  'supabase/functions/_shared/auth_guard.ts',
  'supabase/migrations/20260908059400_saas_observability.sql',
  'supabase/tests/database/observability_contract_test.sql',
  'docs/saas/43_FASE9_4_OBSERVABILIDAD.md',
  'docs/saas/99_MAPA_MAESTRO_PRUEBAS_SAAS.md',
  'docs/ROADMAP_SAAS_MULTI_TENANT_CHECKLIST.md',
]) {
  if (!exists(requiredPath)) {
    console.error(`SaaS observability gate FAILED: falta ${requiredPath}`);
    process.exit(1);
  }
}

const { errors, entrypoints } = verify();
if (errors.length) {
  console.error('SaaS observability gate FAILED:');
  errors.forEach((error) => console.error(`  - ${error}`));
  process.exit(1);
}

console.log(`SaaS observability gate OK (${entrypoints.length} Edge Functions cubiertas).`);
console.log('  - trace_id correlacionado sin confiar tenant del cliente');
console.log('  - jobs batch tienen job_id y outcome explícito');
console.log('  - ledger/RPC no aceptan payload ni PII libre');
console.log('  - certificación dinámica permanece en T02/T04/T16/T19');
