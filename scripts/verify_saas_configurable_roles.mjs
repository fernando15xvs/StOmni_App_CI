import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ownershipFile = 'supabase/migrations/20260908025000_saas_employee_permissions_tenant.sql';
const files = [
  'supabase/migrations/20260908041000_saas_configurable_roles_permissions.sql',
  'supabase/migrations/20260908041100_saas_permission_override_rls_scope.sql',
  'supabase/migrations/20260908041200_saas_rbac_flutter_compatibility.sql',
];
const readFile = (file) => fs.readFileSync(path.join(root, file), 'utf8');
const read = () => files.map(readFile).join('\n');
const readOwnership = () => readFile(ownershipFile);

// RPC activo consumido por core_logic; mantenerlo nombrado y verificado aquí
// hace que el gate transversal pueda clasificarlo contra el dominio F4.5.
const classifiedRuntimeRpcs = ['update_employee_permission_overrides_v1'];

function need(errors, source, regex, label) {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
}

function verify(source, ownership) {
  const errors=[];
  for (const table of ['permissions','roles','role_permissions','employee_roles']) {
    need(errors,source,new RegExp(`CREATE TABLE public\\.${table}\\b`,'i'),`tabla ${table}`);
  }
  need(errors,source,/roles_organization_fkey[\s\S]{0,120}?REFERENCES public\.organizations\(id\)/i,'roles pertenece a tenant');
  need(errors,source,/role_permissions_role_fkey[\s\S]{0,180}?FOREIGN KEY\s*\(\s*organization_id\s*,\s*role_id\s*\)[\s\S]{0,140}?roles\s*\(\s*organization_id\s*,\s*id\s*\)/i,'role_permissions tenant-qualified');
  need(errors,source,/employee_roles_employee_fkey[\s\S]{0,180}?FOREIGN KEY\s*\(\s*organization_id\s*,\s*employee_id\s*\)[\s\S]{0,140}?empleados\s*\(\s*organization_id\s*,\s*id\s*\)/i,'employee_roles empleado tenant-qualified');
  need(errors,source,/employee_roles_role_fkey[\s\S]{0,180}?FOREIGN KEY\s*\(\s*organization_id\s*,\s*role_id\s*\)[\s\S]{0,140}?roles\s*\(\s*organization_id\s*,\s*id\s*\)/i,'employee_roles rol tenant-qualified');
  need(errors,source,/INSERT INTO public\.roles\s*\(\s*organization_id\s*,\s*code\s*,\s*name\s*,\s*is_system\s*,\s*status\s*\)[\s\S]{0,260}?'admin'[\s\S]{0,260}?'operator'/i,'roles sistema por tenant');
  need(errors,source,/trg_organization_create_system_roles[\s\S]{0,140}?AFTER INSERT ON public\.organizations/i,'roles en nuevos tenants');

  // El ownership de overrides fue establecido en F2.3 y F4.5 lo consume; no
  // debe exigirse que F4.5 repita ALTER/PK/FK ya aplicados anteriormente.
  need(errors,ownership,/ALTER TABLE public\.employee_permission_overrides[\s\S]{0,100}?ADD COLUMN organization_id uuid/i,'overrides reciben tenant (F2.3)');
  need(errors,ownership,/employee_permission_overrides_pkey[\s\S]{0,100}?PRIMARY KEY\s*\(\s*organization_id\s*,\s*employee_id\s*,\s*permission_code\s*\)/i,'PK overrides tenant-aware (F2.3)');
  need(errors,ownership,/employee_permission_overrides_employee_fkey[\s\S]{0,180}?FOREIGN KEY\s*\(\s*organization_id\s*,\s*employee_id\s*\)[\s\S]{0,140}?empleados\s*\(\s*organization_id\s*,\s*id\s*\)/i,'override -> empleado tenant-qualified (F2.3)');

  need(errors,source,/CREATE POLICY employee_permission_tenant_read[\s\S]{0,600}?employee_permission_overrides\.organization_id[\s\S]{0,320}?e\.organization_id\s*=\s*employee_permission_overrides\.organization_id/i,'policy overrides scope explícito');
  need(errors,source,/CREATE OR REPLACE FUNCTION public\.app_tiene_permiso\(p_permission_code text\)[\s\S]{0,3200}?FROM public\.employee_roles er[\s\S]{0,700}?JOIN public\.role_permissions rp/i,'app_tiene_permiso usa roles configurables');
  need(errors,source,/FROM public\.employee_permission_overrides o[\s\S]{0,220}?o\.organization_id\s*=\s*v_org[\s\S]{0,200}?o\.employee_id\s*=\s*v_employee_id/i,'override efectivo filtrado por tenant');
  need(errors,source,/CREATE OR REPLACE FUNCTION public\.create_role_v1/i,'RPC create_role_v1');
  need(errors,source,/CREATE OR REPLACE FUNCTION public\.set_role_permissions_v1/i,'RPC set_role_permissions_v1');
  need(errors,source,/CREATE OR REPLACE FUNCTION public\.set_employee_roles_v1/i,'RPC set_employee_roles_v1');
  need(errors,source,/CREATE OR REPLACE FUNCTION public\.update_employee_permission_overrides_v1\s*\(/i,classifiedRuntimeRpcs[0]);
  need(errors,source,/IF v_role\.code\s*=\s*'admin' THEN RAISE EXCEPTION/i,'permisos admin sistema inmutables');
  need(errors,source,/private\.has_permission\('tenant\.admin'\)/i,'administración de roles exige raíz tenant.admin');
  need(errors,source,/CREATE OR REPLACE FUNCTION public\.get_employee_permission_settings_v1[\s\S]{0,6000}?'role'\s*,\s*v_primary_role[\s\S]{0,140}?'roles'\s*,\s*v_roles[\s\S]{0,140}?'permissions'\s*,\s*v_permissions/i,'respuesta settings compatible + roles configurables');
  need(errors,source,/'base_allowed'\s*,\s*EXISTS\([\s\S]{0,1100}?'allowed'\s*,\s*CASE/i,'settings conserva base_allowed/allowed para Flutter');
  need(errors,source,/CREATE OR REPLACE FUNCTION public\.get_my_effective_permissions_v1[\s\S]{0,2600}?'role'\s*,\s*COALESCE\(v_primary_role\s*,\s*'operator'\)/i,'effective permissions conserva role');

  const effective = source.match(/CREATE OR REPLACE FUNCTION public\.app_tiene_permiso\(p_permission_code text\)[\s\S]*?\$\$;/i)?.[0] ?? '';
  if (/_app_role_base_permissions/i.test(effective)) errors.push('app_tiene_permiso no debe depender de matriz hardcodeada legacy');
  if (/WHERE\s+e\.id\s*=\s*p_employee_id(?![\s\S]{0,100}organization_id)/i.test(source)) errors.push('lookup de empleado en RPC de permisos debe estar tenant-scoped');
  return errors;
}

function mutateRequired(source, pattern, replacement, label) {
  const mutated = source.replace(pattern, replacement);
  if (mutated === source) {
    console.error(`SaaS configurable roles self-test FIXTURE FAILED: ${label}`);
    process.exit(1);
  }
  return mutated;
}

function selfTest() {
  const valid=read();
  const ownership=readOwnership();
  const noTenantOverride=mutateRequired(
    ownership,
    /PRIMARY KEY\s*\(\s*organization_id\s*,\s*employee_id\s*,\s*permission_code\s*\)/i,
    'PRIMARY KEY(employee_id,permission_code)',
    'sin tenant override',
  );
  const appHardcoded=mutateRequired(
    valid,
    /(SELECT EXISTS\(\r?\n\s+SELECT 1 FROM public\.employee_roles er)/i,
    "PERFORM public._app_role_base_permissions('operador');\n  $1",
    'app hardcodeado',
  );
  const ambiguousPolicy=mutateRequired(
    valid,
    /e\.organization_id\s*=\s*employee_permission_overrides\.organization_id/i,
    'e.organization_id=organization_id',
    'policy ambigua',
  );
  const noRoleCompatibility=mutateRequired(
    valid,
    /'role'\s*,\s*v_primary_role\s*,/i,
    "'primary_role',v_primary_role,",
    'sin compatibilidad role',
  );

  const cases=[
    ['válido',valid,ownership,false],
    ['sin tenant override',valid,noTenantOverride,true],
    ['app hardcodeado',appHardcoded,ownership,true],
    ['policy ambigua',ambiguousPolicy,ownership,true],
    ['sin compatibilidad role',noRoleCompatibility,ownership,true],
  ];
  const failed=[];
  for (const [name,source,ownerSource,shouldFail] of cases) {
    const didFail=verify(source,ownerSource).length>0;
    if (didFail!==shouldFail) failed.push(name);
  }
  if (failed.length) {
    console.error('SaaS configurable roles self-test FAILED:');
    failed.forEach((x)=>console.error(`  - ${x}`));
    process.exit(1);
  }
  console.log(`SaaS configurable roles self-test OK (${cases.length} casos).`);
}

if (process.argv.includes('--self-test')) { selfTest(); process.exit(0); }
const errors=verify(read(),readOwnership());
if (errors.length) {
  console.error('SaaS configurable roles gate FAILED:');
  errors.forEach((e)=>console.error(`  - ${e}`));
  process.exit(1);
}
console.log('SaaS configurable roles gate OK (F4.5 + ownership F2.3).');
