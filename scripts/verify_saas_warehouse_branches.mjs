import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const file = 'supabase/migrations/20260908031000_saas_warehouses_by_branch.sql';
const read = () => fs.readFileSync(path.join(root, file), 'utf8');

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

function verify(source) {
  const errors = [];
  need(errors, source, /ALTER TABLE public\.almacenes[\s\S]{0,80}?ADD COLUMN branch_id uuid/i, 'almacenes.branch_id');
  need(errors, source, /UPDATE public\.almacenes a[\s\S]{0,180}?b\.organization_id = a\.organization_id[\s\S]{0,100}?b\.is_main = true/i, 'backfill por branch principal del mismo tenant');
  need(errors, source, /ALTER COLUMN branch_id SET NOT NULL/i, 'branch_id obligatorio');
  need(errors, source, /FOREIGN KEY \(organization_id, branch_id\)[\s\S]{0,120}?REFERENCES public\.branches\(organization_id, id\)/i, 'FK compuesta warehouse->branch');
  need(errors, source, /CREATE INDEX almacenes_organization_branch_active_idx[\s\S]{0,100}?organization_id, branch_id, activo/i, 'índice tenant/branch');
  need(errors, source, /FUNCTION private\.enforce_warehouse_branch\(\)/i, 'trigger helper branch');
  need(errors, source, /v_current_org uuid := private\.current_organization_id\(\)/i, 'tenant derivado server-side');
  need(errors, source, /WHERE b\.organization_id=v_org[\s\S]{0,80}?AND b\.id=NEW\.branch_id[\s\S]{0,80}?AND b\.status='active'/i, 'branch validada dentro del tenant');
  need(errors, source, /CREATE TRIGGER zz_almacenes_enforce_branch[\s\S]{0,100}?BEFORE INSERT OR UPDATE ON public\.almacenes/i, 'trigger branch en almacenes');
  need(errors, source, /IF v_status='inactive' AND EXISTS \([\s\S]{0,180}?a\.organization_id=v_org[\s\S]{0,80}?a\.branch_id=p_branch_id[\s\S]{0,80}?a\.activo,true/i, 'branch con almacenes activos no se desactiva');
  need(errors, source, /WHERE organization_id=v_org AND id=p_branch_id/i, 'update branch tenant-scoped');

  if (/FOREIGN KEY \(branch_id\)\s+REFERENCES public\.branches\(id\)/i.test(source)) {
    errors.push('FK branch no puede depender sólo de UUID sin organization_id');
  }
  return errors;
}

function selfTest() {
  const valid = read();
  const fkSimple = mutated(
    mutated(
      valid,
      /FOREIGN KEY \(organization_id, branch_id\)/i,
      'FOREIGN KEY (branch_id)',
      'FK simple: columnas',
    ),
    /REFERENCES public\.branches\(organization_id, id\)/i,
    'REFERENCES public.branches(id)',
    'FK simple: referencia',
  );
  const cases = [
    ['válido', valid, false],
    ['FK simple insegura', fkSimple, true],
    ['sin NOT NULL', mutated(valid, /ALTER COLUMN branch_id SET NOT NULL,?/i, '', 'sin NOT NULL'), true],
    [
      'sin tenant branch',
      mutated(
        valid,
        /WHERE\s+b\.organization_id=v_org\s+AND\s+b\.id=NEW\.branch_id/gi,
        'WHERE true AND b.id=NEW.branch_id',
        'sin tenant branch',
      ),
      true,
    ],
  ];
  const failed = [];
  for (const [name, source, shouldFail] of cases) {
    const didFail = verify(source).length > 0;
    if (didFail !== shouldFail) failed.push(name);
  }
  if (failed.length) {
    console.error('SaaS warehouse branches self-test FAILED:');
    failed.forEach((name) => console.error(`  - ${name}`));
    process.exit(1);
  }
  console.log(`SaaS warehouse branches self-test OK (${cases.length} casos).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}
const errors = verify(read());
if (errors.length) {
  console.error('SaaS warehouse branches gate FAILED:');
  errors.forEach((e) => console.error(`  - ${e}`));
  process.exit(1);
}
console.log('SaaS warehouse branches gate OK (F4.2).');
