import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrationPath = 'supabase/migrations/20260908030000_saas_branches.sql';
const read = () => fs.readFileSync(path.join(root, migrationPath), 'utf8');

function need(errors, source, regex, label) {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
}

function verify(source) {
  const errors = [];
  need(errors, source, /CREATE TABLE public\.branches/i, 'tabla branches');
  need(errors, source, /organization_id uuid NOT NULL/i, 'ownership tenant obligatorio');
  need(errors, source, /FOREIGN KEY \(organization_id\)[\s\S]{0,100}?REFERENCES public\.organizations\(id\)/i, 'FK a organizations');
  need(errors, source, /UNIQUE \(organization_id, id\)/i, 'clave compuesta para F4.2-F4.4');
  need(errors, source, /UNIQUE INDEX branches_organization_code_key[\s\S]{0,100}?\(organization_id, code\)/i, 'código único por tenant');
  need(errors, source, /UNIQUE INDEX branches_one_main_per_organization_key[\s\S]{0,100}?\(organization_id\)[\s\S]{0,40}?WHERE is_main/i, 'una principal máxima por tenant');
  need(errors, source, /ENABLE ROW LEVEL SECURITY/i, 'RLS habilitado');
  need(errors, source, /CREATE POLICY branches_tenant_select[\s\S]{0,220}?private\.row_belongs_to_current_organization\(organization_id\)/i, 'SELECT tenant-aware');
  need(errors, source, /REVOKE ALL ON TABLE public\.branches FROM PUBLIC, anon, authenticated/i, 'tabla cerrada por defecto');
  need(errors, source, /GRANT SELECT ON TABLE public\.branches TO authenticated/i, 'sólo lectura Data API');
  need(errors, source, /INSERT INTO public\.branches[\s\S]{0,220}?SELECT o\.id, 'MAIN', 'Principal', true, 'active'[\s\S]{0,120}?FROM public\.organizations o/i, 'backfill de principal');
  need(errors, source, /TRIGGER trg_organization_create_main_branch[\s\S]{0,100}?AFTER INSERT ON public\.organizations/i, 'principal automática para nuevos tenants');

  for (const rpc of ['create_branch_v1', 'update_branch_v1', 'set_main_branch_v1']) {
    need(errors, source, new RegExp(`CREATE OR REPLACE FUNCTION public\\.${rpc}`, 'i'), `RPC ${rpc}`);
  }
  need(errors, source, /v_org uuid := private\.require_current_organization_id\(\)/i, 'RPC derivan tenant server-side');
  need(errors, source, /private\.has_permission\('tenant\.admin'\)/i, 'mutaciones requieren tenant.admin');
  need(errors, source, /WHERE organization_id=v_org AND id=p_branch_id/i, 'updates scopeados por tenant');
  need(errors, source, /REVOKE ALL ON FUNCTION public\.create_branch_v1[\s\S]{0,100}?FROM PUBLIC, anon/i, 'create no expuesto a anon/public');

  const executable = source.replace(/--.*$/gm, '');
  if (/\bp_organization_id\b|\borganization_id\s+uuid\s+DEFAULT/i.test(executable.match(/CREATE OR REPLACE FUNCTION public\.create_branch_v1[\s\S]*?\$\$;/i)?.[0] ?? '')) {
    errors.push('create_branch_v1 no debe aceptar organization_id del cliente');
  }
  if (/GRANT\s+(?:INSERT|UPDATE|DELETE|ALL)[^;]*ON TABLE public\.branches[^;]*TO authenticated/i.test(executable)) {
    errors.push('authenticated no debe tener escritura directa sobre branches');
  }
  return errors;
}

function selfTest() {
  const valid = read();
  const cases = [
    ['contrato válido', valid, false],
    ['sin RLS', valid.replace('ALTER TABLE public.branches ENABLE ROW LEVEL SECURITY;', ''), true],
    ['sin tenant RPC', valid.replaceAll('private.require_current_organization_id()', 'NULL::uuid'), true],
    ['escritura directa cliente', `${valid}\nGRANT INSERT ON TABLE public.branches TO authenticated;`, true],
  ];
  const failed = [];
  for (const [name, source, shouldFail] of cases) {
    const didFail = verify(source).length > 0;
    if (didFail !== shouldFail) failed.push(name);
  }
  if (failed.length) {
    console.error('SaaS branches self-test FAILED:');
    failed.forEach((name) => console.error(`  - ${name}`));
    process.exit(1);
  }
  console.log(`SaaS branches self-test OK (${cases.length} casos).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify(read());
if (errors.length) {
  console.error('SaaS branches gate FAILED:');
  errors.forEach((error) => console.error(`  - ${error}`));
  process.exit(1);
}
console.log('SaaS branches gate OK (F4.1).');
