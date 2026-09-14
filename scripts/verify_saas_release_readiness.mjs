import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), 'utf8');
const exists = (relativePath) => fs.existsSync(path.join(root, relativePath));

function need(errors, condition, message) {
  if (!condition) errors.push(message);
}

function validateTemplate(errors, source) {
  need(errors, /DECISIÓN: PENDIENTE/.test(source),
    'template T19 debe permanecer PENDIENTE');
  for (let i = 0; i <= 19; i += 1) {
    const id = `T${String(i).padStart(2, '0')}`;
    need(errors, source.includes(`| ${id} | PENDIENTE |`),
      `template T19 no contiene fila ${id}`);
  }
  const required = [
    'Pruebas críticas fallidas',
    'Pruebas críticas omitidas',
    'Restore drill T18',
    'Trace A/B aislado',
    'Seguridad F9.5',
    'Release F9.6',
    'Release blockers',
    'GO',
    'NO-GO',
  ];
  for (const token of required) {
    need(errors, source.includes(token), `template T19 falta ${token}`);
  }
}

function validateRunbook(errors, source) {
  const required = [
    'FINAL_VALIDATION_REPORT.md',
    'T00–T19',
    'cero pruebas críticas fallidas',
    'cero pruebas críticas omitidas',
    'backup pre-release',
    'migraciones',
    'Edge Functions',
    'Storage',
    'Billing',
    'RPO',
    'RTO',
    'rollback',
    'commit GO',
  ];
  for (const token of required) {
    need(errors, source.toLowerCase().includes(token.toLowerCase()),
      `release runbook falta ${token}`);
  }
  need(errors, /no constituye autorización de despliegue/i.test(source),
    'runbook debe negar autorización implícita de deploy');
}

export function validateFinalReport(source) {
  const errors = [];
  const decision = /\*\*DECISIÓN:\s*(GO|NO-GO|PENDIENTE)\*\*/i.exec(source)?.[1]?.toUpperCase();
  need(errors, Boolean(decision), 'FINAL_VALIDATION_REPORT no declara decisión válida');
  if (decision !== 'GO') return errors;

  for (let i = 0; i <= 19; i += 1) {
    const id = `T${String(i).padStart(2, '0')}`;
    const green = new RegExp(`\\|\\s*${id}\\s*\\|\\s*(?:GREEN|VERDE|PASSED|PASS)\\s*\\|`, 'i');
    need(errors, green.test(source), `GO inválido: ${id} no está verde`);
  }
  need(errors,
    /Pruebas críticas fallidas:\s*0\b/i.test(source),
    'GO inválido: pruebas críticas fallidas debe ser 0');
  need(errors,
    /Pruebas críticas omitidas:\s*0\b/i.test(source),
    'GO inválido: pruebas críticas omitidas debe ser 0');
  need(errors,
    /RESTORE_DRILL_GREEN/.test(source),
    'GO inválido: falta RESTORE_DRILL_GREEN');
  need(errors,
    /TENANT_ISOLATION_VIOLATION:\s*(?:0|NO|AUSENTE)/i.test(source),
    'GO inválido: no confirma ausencia de TENANT_ISOLATION_VIOLATION');
  need(errors,
    /PII_SECRET_LOG_EXPOSURE:\s*(?:0|NO|AUSENTE)/i.test(source),
    'GO inválido: no confirma ausencia de PII_SECRET_LOG_EXPOSURE');
  return errors;
}

function validateMasterDocs(errors, checklist, map, audit) {
  need(errors, /\[x\] Fase 9\.6 — Release comercial\./.test(checklist),
    'checklist no marca F9.6 implementada');
  need(errors, /\[ \] \*\*GATE BLOQUE 9 VERDE\*\*/.test(checklist),
    'Gate Bloque 9 se cerró antes de T00–T19');
  need(errors, /\[ \] StOmni listo para comercialización SaaS\./.test(checklist),
    'estado global declaró comercialización antes de GO');
  need(errors,
    /node scripts\/verify_saas_release_readiness\.mjs --self-test[\s\S]*?node scripts\/verify_saas_release_readiness\.mjs/.test(map),
    'T02 no incluye gate de release readiness');
  need(errors, /# T19 — Informe de validación final y decisión Go\/No-Go/.test(map),
    'mapa no conserva T19');
  need(errors, /FINAL_VALIDATION_REPORT_TEMPLATE\.md/.test(map),
    'T19 no referencia la plantilla final versionada');
  need(errors, /IMPLEMENTADA \/ GO COMERCIAL PENDIENTE DE T00–T19/.test(audit),
    'auditoría F9.6 no separa implementación de GO comercial');
}

function verify() {
  const errors = [];
  const required = [
    'docs/saas/RELEASE_RUNBOOK.md',
    'docs/saas/FINAL_VALIDATION_REPORT_TEMPLATE.md',
    'docs/saas/45_FASE9_6_RELEASE_COMERCIAL.md',
    'docs/saas/99_MAPA_MAESTRO_PRUEBAS_SAAS.md',
    'docs/ROADMAP_SAAS_MULTI_TENANT_CHECKLIST.md',
    'scripts/verify_saas_release_readiness.mjs',
  ];
  for (const file of required) {
    need(errors, exists(file), `falta artefacto release: ${file}`);
  }
  if (errors.length) return errors;

  const runbook = read('docs/saas/RELEASE_RUNBOOK.md');
  const template = read('docs/saas/FINAL_VALIDATION_REPORT_TEMPLATE.md');
  const audit = read('docs/saas/45_FASE9_6_RELEASE_COMERCIAL.md');
  const map = read('docs/saas/99_MAPA_MAESTRO_PRUEBAS_SAAS.md');
  const checklist = read('docs/ROADMAP_SAAS_MULTI_TENANT_CHECKLIST.md');

  validateRunbook(errors, runbook);
  validateTemplate(errors, template);
  validateMasterDocs(errors, checklist, map, audit);

  const finalReport = 'docs/saas/FINAL_VALIDATION_REPORT.md';
  if (exists(finalReport)) {
    errors.push(...validateFinalReport(read(finalReport)));
  }
  return errors;
}

function selfTest() {
  const noGo = '**DECISIÓN: NO-GO**';
  if (validateFinalReport(noGo).length) {
    console.error('Release gate self-test NO-GO FAILED');
    process.exit(1);
  }

  const fakeGo = '**DECISIÓN: GO**\nPruebas críticas fallidas: 0\nPruebas críticas omitidas: 0';
  const fakeErrors = validateFinalReport(fakeGo);
  if (fakeErrors.length < 20) {
    console.error('Release gate self-test GO incompleto FAILED:', fakeErrors);
    process.exit(1);
  }

  const rows = Array.from({ length: 20 }, (_, i) => {
    const id = `T${String(i).padStart(2, '0')}`;
    return `| ${id} | GREEN | 0 | ok |`;
  }).join('\n');
  const validGo = `
**DECISIÓN: GO**
${rows}
Pruebas críticas fallidas: 0
Pruebas críticas omitidas: 0
RESTORE_DRILL_GREEN
TENANT_ISOLATION_VIOLATION: AUSENTE
PII_SECRET_LOG_EXPOSURE: AUSENTE
`;
  const validErrors = validateFinalReport(validGo);
  if (validErrors.length) {
    console.error('Release gate self-test GO completo FAILED:', validErrors);
    process.exit(1);
  }

  console.log(`SaaS release readiness gate self-test OK (${fakeErrors.length} omisiones GO detectadas).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify();
if (errors.length) {
  console.error('SaaS release readiness gate FAILED:');
  errors.forEach((error) => console.error(`  - ${error}`));
  process.exit(1);
}

console.log('SaaS release readiness gate OK a nivel de implementación.');
console.log('  - runbook y template T19 presentes');
console.log('  - ningún GO se acepta sin T00–T19 + cero fallos/omisiones críticas');
console.log('  - Gate Bloque 9 y estado comercial permanecen abiertos hasta validación dinámica');
