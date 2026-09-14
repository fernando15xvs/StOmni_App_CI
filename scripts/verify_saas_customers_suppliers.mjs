import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrationName = '20260907032027_saas_customers_suppliers_tenant.sql';
const migrationPath = path.join(root, 'supabase', 'migrations', migrationName);

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

function executableSql(source) {
  return source.replace(/--.*$/gm, '');
}

function policyBlock(source, name) {
  return source.match(
    new RegExp(`CREATE\\s+POLICY\\s+${name}[\\s\\S]*?;`, 'i'),
  )?.[0] ?? '';
}

function functionBlock(source, signature) {
  const escaped = signature.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return source.match(
    new RegExp(`CREATE\\s+OR\\s+REPLACE\\s+FUNCTION\\s+${escaped}[\\s\\S]*?\\$\\$;`, 'i'),
  )?.[0] ?? '';
}

function verify(source) {
  const errors = [];
  const sql = executableSql(source);

  for (const table of ['clientes', 'proveedores']) {
    need(
      errors,
      source,
      new RegExp(`ALTER TABLE\\s+public\\.${table}[\\s\\S]{0,180}?ADD COLUMN\\s+organization_id\\s+uuid`, 'i'),
      `${table}.organization_id`,
    );
    need(
      errors,
      source,
      new RegExp(`ADD CONSTRAINT\\s+${table}_organization_id_fkey\\b[\\s\\S]{0,180}?FOREIGN KEY\\s*\\(\\s*organization_id\\s*\\)[\\s\\S]{0,140}?REFERENCES\\s+public\\.organizations\\s*\\(\\s*id\\s*\\)`, 'i'),
      `${table}.organization_id -> organizations`,
    );
    need(
      errors,
      source,
      new RegExp(`ADD CONSTRAINT\\s+${table}_organization_id_id_key\\b[\\s\\S]{0,120}?UNIQUE\\s*\\(\\s*organization_id\\s*,\\s*id\\s*\\)`, 'i'),
      `${table} clave compuesta tenant`,
    );
    need(
      errors,
      source,
      new RegExp(`ALTER TABLE\\s+public\\.${table}[\\s\\S]{0,120}?ALTER COLUMN\\s+organization_id\\s+SET NOT NULL`, 'i'),
      `${table}.organization_id NOT NULL`,
    );
    need(
      errors,
      source,
      new RegExp(`CREATE INDEX\\s+${table}_organization_id_idx[\\s\\S]{0,100}?ON\\s+public\\.${table}\\s*\\(\\s*organization_id\\s*\\)`, 'i'),
      `${table} índice tenant`,
    );
    need(
      errors,
      source,
      new RegExp(`CREATE TRIGGER\\s+${table}_enforce_organization_id[\\s\\S]{0,180}?EXECUTE FUNCTION\\s+private\\.enforce_row_organization_id\\(\\)`, 'i'),
      `${table} trigger tenant server-side`,
    );
    need(
      errors,
      source,
      new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ENABLE ROW LEVEL SECURITY`, 'i'),
      `${table} RLS`,
    );
    need(
      errors,
      source,
      new RegExp(`REVOKE ALL ON TABLE\\s+public\\.${table}\\s+FROM\\s+PUBLIC,\\s*anon`, 'i'),
      `${table} no expuesta a anon`,
    );
    need(
      errors,
      source,
      new RegExp(`GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE\\s+public\\.${table}\\s+TO\\s+authenticated`, 'i'),
      `${table} grants explícitos Data API`,
    );
  }

  need(
    errors,
    source,
    /CREATE UNIQUE INDEX\s+clientes_organization_document_key[\s\S]{0,180}?\(organization_id,\s*btrim\(dni_ruc\)\)[\s\S]{0,120}?NULLIF\(btrim\(dni_ruc\),\s*''\)\s+IS NOT NULL/i,
    'documento de cliente único por tenant',
  );
  need(
    errors,
    source,
    /CREATE UNIQUE INDEX\s+proveedores_organization_ruc_key[\s\S]{0,180}?\(organization_id,\s*btrim\(ruc\)\)[\s\S]{0,120}?NULLIF\(btrim\(ruc\),\s*''\)\s+IS NOT NULL/i,
    'RUC de proveedor único por tenant',
  );

  need(
    errors,
    source,
    /count\(DISTINCT organization_id\)[\s\S]{0,220}?v_organization_count\s*<>\s*1/i,
    'backfill legacy aborta si el tenant es ambiguo',
  );
  need(
    errors,
    source,
    /UPDATE\s+public\.clientes[\s\S]{0,100}?SET\s+organization_id\s*=\s*v_organization_id/i,
    'backfill clientes',
  );
  need(
    errors,
    source,
    /UPDATE\s+public\.proveedores[\s\S]{0,100}?SET\s+organization_id\s*=\s*v_organization_id/i,
    'backfill proveedores',
  );

  const enforce = functionBlock(source, 'private.enforce_row_organization_id()');
  need(errors, enforce, /v_organization_id\s+uuid\s*:=\s*private\.current_organization_id\(\)/i, 'trigger deriva tenant autenticado');
  need(errors, enforce, /current_user\s+IN\s*\('service_role',\s*'postgres'\)/i, 'escritura privilegiada diferenciada');
  need(errors, enforce, /NEW\.organization_id\s+IS NOT NULL[\s\S]{0,160}?NEW\.organization_id\s+IS DISTINCT FROM\s+v_organization_id/i, 'cliente no puede elegir otro tenant');
  need(errors, enforce, /NEW\.organization_id\s*:=\s*v_organization_id/i, 'INSERT recibe tenant server-side');
  need(errors, enforce, /NEW\.organization_id\s+IS DISTINCT FROM\s+OLD\.organization_id/i, 'organization_id inmutable');

  const customerPolicies = {
    select: policyBlock(source, 'clientes_tenant_select'),
    insert: policyBlock(source, 'clientes_tenant_insert'),
    update: policyBlock(source, 'clientes_tenant_update'),
    delete: policyBlock(source, 'clientes_tenant_delete'),
  };
  for (const [operation, block] of Object.entries(customerPolicies)) {
    need(errors, block, /private\.row_belongs_to_current_organization\(organization_id\)/i, `clientes ${operation} filtra tenant`);
    need(errors, block, /private\.has_permission\('tenant\.(?:read|write)'\)/i, `clientes ${operation} exige permiso`);
  }
  need(errors, customerPolicies.update, /WITH CHECK[\s\S]*private\.row_belongs_to_current_organization\(organization_id\)/i, 'clientes UPDATE tiene WITH CHECK tenant');

  const supplierPolicies = {
    select: policyBlock(source, 'proveedores_tenant_select'),
    insert: policyBlock(source, 'proveedores_tenant_insert'),
    update: policyBlock(source, 'proveedores_tenant_update'),
    delete: policyBlock(source, 'proveedores_tenant_delete'),
  };
  need(errors, supplierPolicies.select, /private\.has_permission\('tenant\.read'\)/i, 'proveedores SELECT exige lectura');
  for (const operation of ['insert', 'update', 'delete']) {
    need(errors, supplierPolicies[operation], /private\.has_permission\('tenant\.admin'\)/i, `proveedores ${operation} conserva escritura admin`);
    need(errors, supplierPolicies[operation], /private\.row_belongs_to_current_organization\(organization_id\)/i, `proveedores ${operation} filtra tenant`);
  }
  need(errors, supplierPolicies.update, /WITH CHECK[\s\S]*private\.row_belongs_to_current_organization\(organization_id\)/i, 'proveedores UPDATE tiene WITH CHECK tenant');

  if (/\bapp_empleado_activo\s*\(|\bapp_es_admin\s*\(/i.test(sql)) {
    errors.push('F3.2 no debe reutilizar helpers de autorización legacy');
  }
  if (/CREATE\s+POLICY[\s\S]{0,260}?TO\s+authenticated\s*(?:;|USING\s*\(\s*true\s*\))/i.test(sql)) {
    errors.push('No se acepta policy authenticated sin predicado tenant');
  }
  if (/GRANT\s+.+ON TABLE\s+public\.(?:clientes|proveedores)\s+TO\s+anon/i.test(sql)) {
    errors.push('clientes/proveedores no deben otorgar acceso a anon');
  }

  return errors;
}

function readMigration() {
  if (!fs.existsSync(migrationPath)) {
    throw new Error(`Falta migración: ${migrationName}`);
  }
  return fs.readFileSync(migrationPath, 'utf8');
}

function selfTest() {
  const valid = readMigration();
  const validErrors = verify(valid);
  if (validErrors.length) {
    console.error('SaaS customers/suppliers self-test FAILED (contrato válido rechazado):');
    for (const error of validErrors) console.error(`  - ${error}`);
    process.exit(1);
  }

  const cases = [
    [
      'helper legacy',
      `${valid}\nCREATE POLICY bad ON public.clientes TO authenticated USING (public.app_empleado_activo());`,
    ],
    [
      'anon grant',
      `${valid}\nGRANT SELECT ON TABLE public.clientes TO anon;`,
    ],
    [
      'sin asignación server-side',
      mutated(
        valid,
        /NEW\.organization_id\s*:=\s*v_organization_id;/i,
        'RETURN NEW;',
        'sin asignación server-side',
      ),
    ],
    [
      'sin unicidad tenant de proveedor',
      mutated(
        valid,
        /CREATE UNIQUE INDEX\s+proveedores_organization_ruc_key/i,
        'CREATE INDEX proveedores_organization_ruc_key',
        'sin unicidad tenant de proveedor',
      ),
    ],
    [
      'clave compuesta de proveedor ausente',
      mutated(
        valid,
        /ADD CONSTRAINT\s+proveedores_organization_id_id_key\s+UNIQUE\s*\(\s*organization_id\s*,\s*id\s*\)/i,
        'ADD CONSTRAINT proveedores_organization_id_id_key UNIQUE (id)',
        'clave compuesta de proveedor ausente',
      ),
    ],
  ];

  const missed = [];
  for (const [name, mutatedSource] of cases) {
    if (verify(mutatedSource).length === 0) missed.push(name);
  }

  if (missed.length) {
    console.error('SaaS customers/suppliers self-test FAILED:');
    for (const name of missed) console.error(`  - no detectó ${name}`);
    process.exit(1);
  }

  console.log(`SaaS customers/suppliers self-test OK (${cases.length + 1} contratos/casos).`);
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const errors = verify(readMigration());
if (errors.length) {
  console.error('SaaS customers/suppliers gate FAILED:');
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}

console.log(`SaaS customers/suppliers gate OK: ${migrationName}`);
