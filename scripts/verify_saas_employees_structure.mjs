import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const files = [
  'supabase/migrations/20260907022207_saas_employees_identity_separation.sql',
  'supabase/migrations/20260908035000_saas_employees_professional_structure.sql',
  'supabase/migrations/20260908035100_saas_employee_payments_contract.sql',
  'supabase/migrations/20260908035200_saas_employee_payment_delete_rpc.sql',
];
const runtimeFile = 'packages/core_logic/lib/features/empleados/data/empleados_repository.dart';
const read = () => files.map((f) => fs.readFileSync(path.join(root, f), 'utf8')).join('\n');
const readRuntime = () => fs.readFileSync(path.join(root, runtimeFile), 'utf8');

function need(errors, source, regex, label) {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
}

function mutated(source, regex, replacement, label) {
  const next = source.replace(regex, replacement);
  if (next === source) {
    throw new Error(`Self-test fixture no pudo mutar: ${label}`);
  }
  return next;
}

function verify(source, runtime = readRuntime()) {
  const errors = [];
  need(errors, source, /ADD COLUMN organization_id uuid[\s\S]{0,80}?ADD COLUMN app_user_id uuid/i, 'identidad empleado separada de login');
  need(errors, source, /ADD COLUMN branch_id uuid[\s\S]{0,80}?ADD COLUMN employment_status text/i, 'branch + estado laboral');
  need(errors, source, /FOREIGN KEY\(organization_id,branch_id\)[\s\S]{0,100}?REFERENCES public\.branches\(organization_id,id\)/i, 'empleado -> branch tenant-qualified');
  need(errors, source, /empleados_employment_status_valid[\s\S]{0,120}?active[\s\S]{0,80}?inactive[\s\S]{0,80}?leave[\s\S]{0,80}?terminated/i, 'estados laborales válidos');
  need(errors, source, /CREATE TRIGGER zz_empleados_branch_status[\s\S]{0,120}?BEFORE INSERT OR UPDATE ON public\.empleados/i, 'trigger laboral');
  need(errors, source, /ALTER TABLE public\.pagos_empleados[\s\S]{0,100}?ADD COLUMN organization_id uuid[\s\S]{0,100}?ADD COLUMN cash_register_id uuid[\s\S]{0,100}?ADD COLUMN cash_session_id uuid/i, 'pagos empleados tenant/cash');
  need(errors, source, /FOREIGN KEY\(organization_id,empleado_id\)[\s\S]{0,120}?REFERENCES public\.empleados\(organization_id,id\)/i, 'pago -> empleado tenant-qualified');
  need(errors, source, /ALTER COLUMN empleado_id SET NOT NULL/i, 'pago empleado obligatorio');
  need(errors, source, /CREATE POLICY pagos_empleados_tenant_admin_select[\s\S]{0,200}?tenant\.admin[\s\S]{0,160}?row_belongs_to_current_organization\(organization_id\)/i, 'RLS pagos de personal');
  need(errors, source, /CREATE OR REPLACE FUNCTION public\.registrar_pago_empleado_mixto[\s\S]{0,1600}?e\.organization_id=v_org[\s\S]{0,1800}?private\.require_open_cash_session_id\(\)/i, 'RPC pago empleado tenant/cash-aware');
  need(errors, source, /INSERT INTO public\.pagos_empleados\([\s\S]{0,400}?organization_id[\s\S]{0,400}?cash_session_id/i, 'RPC persiste tenant y sesión');
  need(errors, source, /cash_session_available_balance\(p_session_id uuid\)[\s\S]{0,1400}?FROM public\.pagos_empleados p[\s\S]{0,180}?p\.organization_id=v_org[\s\S]{0,120}?p\.cash_session_id=p_session_id/i, 'saldo Caja incluye personal por sesión');
  need(errors, source, /CREATE OR REPLACE FUNCTION public\.eliminar_pago_empleado_v1[\s\S]{0,600}?WHERE organization_id=v_org AND id=p_pago_id/i, 'eliminación pago tenant-aware');
  need(errors, source, /Employee payment belongs to a closed cash session/i, 'sesión cerrada preserva evidencia');
  need(errors, source, /CREATE OR REPLACE VIEW public\.movimientos[\s\S]{0,2600}?FROM public\.pagos_empleados pe/i, 'movimientos reincorpora personal');
  need(errors, source, /CREATE OR REPLACE VIEW public\.reportes_movimientos_financieros[\s\S]{0,3200}?FROM public\.pagos_empleados pe/i, 'reportes reincorporan personal');
  need(errors, source, /CREATE OR REPLACE FUNCTION public\.get_estado_caja_chica\(\)[\s\S]{0,1600}?FROM public\.pagos_empleados p[\s\S]{0,180}?cash_session_id=v_session\.id/i, 'estado Caja incluye personal por sesión');
  need(errors, source, /GRANT EXECUTE ON FUNCTION public\.registrar_pago_empleado_mixto\(bigint,text,timestamptz,jsonb\) TO authenticated/i, 'RPC pago empleado reabierto explícitamente');
  need(errors, source, /GRANT EXECUTE ON FUNCTION public\.eliminar_pago_empleado_v1\(bigint\) TO authenticated/i, 'RPC delete pago allowlisted');
  need(errors, runtime, /\.rpc\(\s*'registrar_pago_empleado_mixto'/i, 'runtime registra pago por RPC');
  need(errors, runtime, /\.rpc\(\s*'eliminar_pago_empleado_v1'/i, 'runtime elimina pago por RPC');
  if (/from\('pagos_empleados'\)\.delete/i.test(runtime.replace(/\s+/g,''))) {
    errors.push('runtime no puede borrar pagos_empleados directamente');
  }

  const currentRpc = source.slice(source.lastIndexOf('CREATE OR REPLACE FUNCTION public.registrar_pago_empleado_mixto'));
  if (/SELECT sc\.\*[\s\S]{0,120}?WHERE sc\.estado = 'ABIERTA'[\s\S]{0,120}?ORDER BY sc\.fecha_apertura/i.test(currentRpc)) {
    errors.push('pago de empleado no puede buscar caja global por fecha');
  }
  if (/FROM public\.pagos_empleados AS pe[\s\S]{0,160}?pe\.fecha >= v_sesion\.fecha_apertura/i.test(currentRpc)) {
    errors.push('pago de empleado no puede calcular Caja por ventana temporal global');
  }
  return errors;
}

function selfTest() {
  const valid = read();
  const runtime = readRuntime();
  const cases = [
    ['válido', valid, runtime, false],
    [
      'sin branch tenant',
      mutated(valid, /FOREIGN KEY\s*\(organization_id,\s*branch_id\)/i, 'FOREIGN KEY(branch_id)', 'sin branch tenant'),
      runtime,
      true,
    ],
    [
      'sin empleado obligatorio',
      mutated(valid, /ALTER COLUMN empleado_id SET NOT NULL;/i, '', 'sin empleado obligatorio'),
      runtime,
      true,
    ],
    [
      'RPC sin tenant empleado',
      mutated(valid, /e\.organization_id=v_org\s+AND\s+e\.id=p_empleado_id/i, 'e.id=p_empleado_id', 'RPC sin tenant empleado'),
      runtime,
      true,
    ],
    [
      'delete directo runtime',
      valid,
      mutated(
        runtime,
        /await\s+_client\.rpc\(\s*'eliminar_pago_empleado_v1'\s*,\s*params:\s*\{\s*'p_pago_id':\s*pagoId\s*\}\s*,?\s*\);/i,
        "await _client.from('pagos_empleados').delete().eq('id', pagoId);",
        'delete directo runtime',
      ),
      true,
    ],
  ];
  const failed=[];
  for (const [name,source,runtimeSource,shouldFail] of cases) {
    const didFail=verify(source,runtimeSource).length>0;
    if (didFail!==shouldFail) failed.push(name);
  }
  if (failed.length) {
    console.error('SaaS employee structure self-test FAILED:');
    failed.forEach((x)=>console.error(`  - ${x}`));
    process.exit(1);
  }
  console.log(`SaaS employee structure self-test OK (${cases.length} casos).`);
}

if (process.argv.includes('--self-test')) { selfTest(); process.exit(0); }
const errors=verify(read());
if (errors.length) {
  console.error('SaaS employee structure gate FAILED:');
  errors.forEach((e)=>console.error(`  - ${e}`));
  process.exit(1);
}
console.log('SaaS employee structure gate OK (F4.4).');
