import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const files = [
  'supabase/migrations/20260908032000_saas_cash_registers_sessions.sql',
  'supabase/migrations/20260908032100_saas_cash_payment_attribution.sql',
  'supabase/migrations/20260908033500_saas_cash_debt_and_expense_runtime.sql',
  'supabase/migrations/20260908033600_saas_cash_single_session_per_user.sql',
];
const read = () => files.map((f) => fs.readFileSync(path.join(root, f), 'utf8')).join('\n');

function need(errors, source, regex, label) {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
}

function fnBlock(source, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return source.match(new RegExp(`CREATE\\s+OR\\s+REPLACE\\s+FUNCTION\\s+${escaped}[\\s\\S]*?\\$\\$;`, 'i'))?.[0] ?? '';
}

function mutateFunction(source, name, mutate, label) {
  const block = fnBlock(source, name);
  if (!block) throw new Error(`Self-test fixture no encontró función: ${label}`);
  const nextBlock = mutate(block);
  if (nextBlock === block) throw new Error(`Self-test fixture no pudo mutar: ${label}`);
  return source.replace(block, nextBlock);
}

function verify(source) {
  const errors = [];
  need(errors, source, /CREATE TABLE public\.cash_registers/i, 'cash_registers');
  need(errors, source, /FOREIGN KEY\s*\(organization_id,\s*branch_id\)[\s\S]{0,140}?REFERENCES public\.branches\(organization_id,id\)/i, 'cash register -> branch tenant-qualified');
  need(errors, source, /ALTER TABLE public\.sesiones_caja[\s\S]{0,160}?ADD COLUMN organization_id uuid[\s\S]{0,160}?ADD COLUMN branch_id uuid[\s\S]{0,160}?ADD COLUMN cash_register_id uuid/i, 'sesiones_caja tenant/branch/register');
  need(errors, source, /sesiones_caja_one_open_per_register_key[\s\S]{0,160}?organization_id,cash_register_id[\s\S]{0,100}?estado='ABIERTA'/i, 'una sesión abierta por caja');
  need(errors, source, /sesiones_caja_one_open_per_user_key[\s\S]{0,160}?organization_id,usuario_id[\s\S]{0,100}?estado='ABIERTA'/i, 'una sesión abierta por usuario');
  need(errors, source, /CREATE POLICY sesiones_caja_tenant_select[\s\S]{0,220}?row_belongs_to_current_organization\(organization_id\)/i, 'RLS tenant sesiones');
  need(errors, source, /ALTER TABLE public\.pagos_venta[\s\S]{0,140}?ADD COLUMN cash_register_id uuid[\s\S]{0,140}?ADD COLUMN cash_session_id uuid/i, 'atribución cash pagos venta');
  need(errors, source, /ALTER TABLE public\.pagos_gasto[\s\S]{0,140}?ADD COLUMN cash_register_id uuid[\s\S]{0,140}?ADD COLUMN cash_session_id uuid/i, 'atribución cash pagos gasto');
  need(errors, source, /WITH\s*\(security_invoker=true\)[\s\S]{0,140}?AS[\s\S]{0,140}?SELECT/i, 'vistas financieras security_invoker');

  const requireSession = fnBlock(source, 'private.require_open_cash_session_id(');
  need(errors, requireSession, /v_org\s+uuid\s*:=\s*private\.require_current_organization_id\(\)/i, 'sesión cash deriva tenant actual');
  const userScopeCount = [...requireSession.matchAll(/s\.usuario_id\s*=\s*auth\.uid\(\)/gi)].length;
  if (userScopeCount < 2) errors.push('Falta: sesión cash filtra tenant+usuario en conteo y selección');
  const openScopeCount = [...requireSession.matchAll(/s\.estado\s*=\s*'ABIERTA'/gi)].length;
  if (openScopeCount < 2) errors.push('Falta: sesión cash exige estado ABIERTA en conteo y selección');

  need(errors, source, /cash_session_available_balance\(p_session_id uuid\)[\s\S]{0,1100}?p\.organization_id=v_org[\s\S]{0,180}?p\.cash_session_id=p_session_id/i, 'saldo por sesión exacta');

  const expense = fnBlock(source, 'public.registrar_gasto_mixto(');
  need(errors, expense, /private\.require_open_cash_session_id\(\)/i, 'gasto mixto reabierto sobre sesión');
  need(errors, expense, /private\.cash_session_available_balance\(v_session_id\)/i, 'gasto mixto valida saldo de sesión');
  need(errors, expense, /cash_session_id/i, 'gasto mixto atribuye pago a sesión');

  const debt = fnBlock(source, 'public.procesar_pago_deuda_v2(');
  need(errors, debt, /WHERE organization_id=v_org AND request_id=p_request_id/i, 'deuda idempotente tenant-scoped');
  need(errors, source, /ADD CONSTRAINT\s+pagos_deuda_requests_pkey[\s\S]{0,100}?PRIMARY KEY\s*\(\s*organization_id\s*,\s*request_id\s*\)/i, 'PK idempotencia por tenant');
  need(errors, debt, /INSERT INTO public\.pagos_venta\([\s\S]{0,420}?cash_session_id/i, 'cobro cliente atribuido a sesión');
  need(errors, debt, /INSERT INTO public\.pagos_gasto\([\s\S]{0,480}?cash_session_id/i, 'pago proveedor atribuido a sesión');
  need(errors, source, /REVOKE ALL ON FUNCTION public\._legacy_procesar_pago_deuda_v2/i, 'motor deuda legacy cerrado');

  if (/FROM public\.sesiones_caja[\s\S]{0,180}?ORDER BY [^;]*fecha_apertura[\s\S]{0,80}?LIMIT 1/i.test(debt)) {
    errors.push('procesar_pago_deuda_v2 no puede resolver caja global por última fecha');
  }
  if (/WHERE pv\.fecha >= v_sesion\.fecha_apertura/i.test(debt)) {
    errors.push('saldo de Caja no puede agregarse sólo por fecha de apertura');
  }
  if (/RETURN public\._legacy_procesar_pago_deuda_v2/i.test(debt)) {
    errors.push('entrypoint de deuda no puede delegar al motor cash legacy');
  }
  return errors;
}

function selfTest() {
  const valid = read();
  const cases = [
    ['válido', valid, false],
    ['sin tenant PK', valid.replace(/PRIMARY KEY\s*\(\s*organization_id\s*,\s*request_id\s*\)/i, 'PRIMARY KEY (request_id)'), true],
    ['delega legacy', valid.replace(/IF\s+p_es_cliente\s+THEN/i, "IF p_es_cliente THEN\n    RETURN public._legacy_procesar_pago_deuda_v2(p_request_id,true,p_deuda_id,p_monto,p_metodo,p_fecha,false);"), true],
    ['sin sesión usuario', mutateFunction(
      valid,
      'private.require_open_cash_session_id(',
      (block) => block.replace(/AND\s+s\.usuario_id\s*=\s*auth\.uid\(\)/gi, 'AND true'),
      'sin sesión usuario',
    ), true],
    ['dos sesiones por usuario', valid.replace(/CREATE UNIQUE INDEX sesiones_caja_one_open_per_user_key[\s\S]*?WHERE estado='ABIERTA';/i, ''), true],
    ['gasto sin sesión', valid.replace(/v_session_id:=private\.require_open_cash_session_id\(\);/i, 'v_session_id:=NULL;'), true],
  ];
  const failed = [];
  for (const [name, mutated, shouldFail] of cases) {
    const didFail = verify(mutated).length > 0;
    if (didFail !== shouldFail) failed.push(name);
  }
  if (failed.length) {
    console.error('SaaS cash registers self-test FAILED:');
    failed.forEach((name) => console.error(`  - ${name}`));
    process.exit(1);
  }
  console.log(`SaaS cash registers self-test OK (${cases.length} casos).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}
const errors = verify(read());
if (errors.length) {
  console.error('SaaS cash registers gate FAILED:');
  errors.forEach((e) => console.error(`  - ${e}`));
  process.exit(1);
}
console.log('SaaS cash registers gate OK (F4.3).');
