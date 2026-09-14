import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrationFiles = [
  'supabase/migrations/20260908050000_saas_enterprise_audit_logs.sql',
  'supabase/migrations/20260908050100_saas_enterprise_audit_safety.sql',
];
const coreFiles = [
  'packages/core_logic/lib/audit/domain/audit_log_entry.dart',
  'packages/core_logic/lib/audit/application/audit_log_gateway.dart',
  'packages/core_logic/lib/audit/data/supabase_audit_log_gateway.dart',
  'packages/core_logic/lib/audit/providers/audit_log_providers.dart',
];
const read = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const sql = () => migrationFiles.map(read).join('\n');
const core = () => coreFiles.map(read).join('\n');

function need(errors, source, regex, label) {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
}

function writerCalls(source) {
  return [...source.matchAll(/(?:PERFORM|SELECT)\s+private\.write_audit_log\s*\([\s\S]*?\);/gi)]
    .map((m) => m[0])
    .join('\n');
}

function verify(sqlSource, coreSource) {
  const errors = [];
  need(errors, sqlSource, /CREATE TABLE public\.audit_logs/i, 'tabla audit_logs');
  need(errors, sqlSource, /organization_id uuid NOT NULL REFERENCES public\.organizations\(id\) ON DELETE RESTRICT/i, 'audit tenant FK');
  need(errors, sqlSource, /occurred_at timestamptz NOT NULL DEFAULT clock_timestamp\(\)/i, 'timestamp autoritativo');
  need(errors, sqlSource, /metadata jsonb NOT NULL DEFAULT '\{\}'::jsonb[\s\S]{0,160}?pg_column_size\(metadata\) <= 32768/i, 'metadata objeto <= 32 KiB');
  need(errors, sqlSource, /CREATE INDEX audit_logs_organization_time_idx[\s\S]{0,100}?organization_id, occurred_at DESC, id DESC/i, 'índice tenant/tiempo');
  need(errors, sqlSource, /ALTER TABLE public\.audit_logs ENABLE ROW LEVEL SECURITY/i, 'RLS audit');
  need(errors, sqlSource, /CREATE POLICY audit_logs_tenant_admin_select[\s\S]{0,260}?private\.has_permission\('tenant\.admin'\)[\s\S]{0,160}?row_belongs_to_current_organization\(organization_id\)/i, 'lectura admin tenant-aware');
  need(errors, sqlSource, /REVOKE ALL ON TABLE public\.audit_logs FROM PUBLIC, anon, authenticated/i, 'sin Data API directo');
  need(errors, sqlSource, /CREATE TRIGGER audit_logs_block_mutation[\s\S]{0,120}?BEFORE UPDATE OR DELETE ON public\.audit_logs/i, 'ledger append-only');
  need(errors, sqlSource, /audit_logs is append-only/i, 'mutación rechazada explícitamente');

  need(errors, sqlSource, /CREATE OR REPLACE FUNCTION private\.write_audit_log/i, 'writer privado');
  need(errors, sqlSource, /v_session_org IS DISTINCT FROM p_organization_id[\s\S]{0,120}?Cross-tenant audit event is not allowed/i, 'writer bloquea cross-tenant');
  need(errors, sqlSource, /e\.organization_id=p_organization_id[\s\S]{0,120}?e\.app_user_id=v_user OR e\.auth_id=v_user/i, 'snapshot actor tenant-aware y compatible');
  need(errors, sqlSource, /v_role:='system'/i, 'actor interno no confía en current_user SECURITY DEFINER');
  need(errors, sqlSource, /REVOKE ALL ON FUNCTION private\.write_audit_log/i, 'writer no expuesto');
  need(errors, sqlSource, /private\.audit_pick_fields/i, 'metadata por allowlist');

  need(errors, sqlSource, /productos_audit_price_change/i, 'audita cambios de precio');
  need(errors, sqlSource, /sale_price_rules_audit_change/i, 'audita reglas de precio');
  need(errors, sqlSource, /inventario_movimientos_audit_adjustment/i, 'audita ajustes de stock');
  need(errors, sqlSource, /v_tipo NOT IN \('merma','ajuste','correccion','corrección'\)/i, 'no duplica kardex ordinario');
  need(errors, sqlSource, /ventas_requests_anulados_audit/i, 'audita anulaciones');
  need(errors, sqlSource, /venta_id_original/i, 'anulación identifica venta original');
  need(errors, sqlSource, /ventas_audit_sensitive_discount/i, 'audita descuentos sensibles');
  need(errors, sqlSource, /role_permissions_audit_change/i, 'audita permisos de rol');
  need(errors, sqlSource, /employee_roles_audit_change/i, 'audita roles de empleado');
  need(errors, sqlSource, /employee_permission_overrides_audit_change/i, 'audita overrides');
  need(errors, sqlSource, /business_capabilities_audit_change/i, 'audita capacidades');
  need(errors, sqlSource, /custom_field_definitions_audit_change/i, 'audita campos configurables');
  need(errors, sqlSource, /configuracion_negocio_audit_change/i, 'audita configuración principal');
  need(errors, sqlSource, /jsonb_build_object\('changed_fields',v_changed\)/i, 'configuración registra nombres, no valores completos');

  need(errors, sqlSource, /CREATE OR REPLACE FUNCTION public\.list_audit_logs_v1/i, 'RPC lectura auditoría');
  need(errors, sqlSource, /v_org uuid := private\.require_current_organization_id\(\)/i, 'RPC deriva tenant server-side');
  need(errors, sqlSource, /private\.has_permission\('tenant\.admin'\)/i, 'RPC exige admin');
  need(errors, sqlSource, /v_limit<1 OR v_limit>200/i, 'paginación acotada');
  need(errors, sqlSource, /WHERE a\.organization_id=v_org/i, 'RPC filtra tenant');
  need(errors, sqlSource, /p_before_id IS NULL OR a\.id<p_before_id/i, 'cursor por id');
  need(errors, sqlSource, /GRANT EXECUTE ON FUNCTION public\.list_audit_logs_v1\(integer,bigint,text,text\) TO authenticated/i, 'sólo RPC expuesto');

  need(errors, coreSource, /class AuditLogEntry/i, 'modelo Dart');
  need(errors, coreSource, /abstract interface class AuditLogGateway/i, 'gateway contrato');
  need(errors, coreSource, /class SupabaseAuditLogGateway implements AuditLogGateway/i, 'gateway Supabase');
  need(errors, coreSource, /\.rpc\([\s\S]{0,60}?'list_audit_logs_v1'/i, 'cliente usa RPC literal auditado');
  need(errors, coreSource, /nextBeforeId:/i, 'paginación Dart');
  need(errors, coreSource, /auditLogGatewayProvider/i, 'provider auditoría');

  const calls = writerCalls(sqlSource);
  if (/private\.write_audit_log\s*\([\s\S]*?to_jsonb\s*\(\s*(?:NEW|OLD)\s*\)/i.test(calls)) {
    errors.push('audit_logs no debe recibir filas completas mediante to_jsonb(NEW/OLD)');
  }
  if (/jsonb_build_object\([\s\S]{0,120}?['"](?:password|token|secret|certificate|certificado|private_key|access_token|refresh_token)['"]/i.test(sqlSource)) {
    errors.push('audit metadata no debe incluir secretos/tokens/certificados');
  }
  if (/GRANT\s+(?:INSERT|UPDATE|DELETE|ALL)[^;]*ON(?: TABLE)? public\.audit_logs[^;]*authenticated/i.test(sqlSource)) {
    errors.push('authenticated no debe tener escritura directa sobre audit_logs');
  }
  return errors;
}

function selfTest() {
  const s = sql();
  const c = core();
  const cases = [
    ['válido', s, c, false],
    ['sin append-only', s.replace('BEFORE UPDATE OR DELETE ON public.audit_logs', 'AFTER INSERT ON public.audit_logs'), c, true],
    ['sin tenant RPC', s.replace('WHERE a.organization_id=v_org', 'WHERE true'), c, true],
    ['payload completo', `${s}\nSELECT private.write_audit_log(o,'x.x','x','1','t','SYSTEM',NULL,to_jsonb(NEW));`, c, true],
    ['token en metadata', `${s}\nSELECT jsonb_build_object('access_token',x);`, c, true],
    ['RPC no literal', s, c.replace("'list_audit_logs_v1'", 'rpcName'), true],
  ];
  const failed=[];
  for (const [name,a,b,shouldFail] of cases) {
    const didFail=verify(a,b).length>0;
    if (didFail!==shouldFail) failed.push(name);
  }
  if (failed.length) {
    console.error('SaaS enterprise audit self-test FAILED:');
    for (const name of failed) console.error(`  - ${name}`);
    process.exit(1);
  }
  console.log(`SaaS enterprise audit self-test OK (${cases.length} casos).`);
}

if (process.argv.includes('--self-test')) { selfTest(); process.exit(0); }
const errors=verify(sql(),core());
if (errors.length) {
  console.error('SaaS enterprise audit gate FAILED:');
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}
console.log('SaaS enterprise audit gate OK (F6.1).');
