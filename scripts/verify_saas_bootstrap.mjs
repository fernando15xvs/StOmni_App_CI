import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migration = '20260907023826_saas_secure_organization_bootstrap.sql';

function requireMatch(errors, source, regex, description) {
  if (!regex.test(source)) errors.push(`Falta: ${description}`);
}

function verifyBootstrap(source) {
  const errors = [];

  requireMatch(errors, source, /CREATE SEQUENCE IF NOT EXISTS\s+public\.configuracion_negocio_id_seq\s+AS\s+integer/i, 'secuencia para nuevas configuraciones');
  requireMatch(errors, source, /ALTER TABLE\s+public\.configuracion_negocio[\s\S]{0,240}?ALTER COLUMN\s+id\s+SET DEFAULT\s+nextval/i, 'configuracion_negocio.id deja de usar default constante');
  requireMatch(errors, source, /ADD COLUMN\s+organization_id\s+uuid/i, 'configuracion_negocio.organization_id');
  requireMatch(errors, source, /configuracion_negocio_organization_id_fkey[\s\S]{0,180}?REFERENCES\s+public\.organizations\s*\(\s*id\s*\)/i, 'configuracion_negocio -> organizations');
  requireMatch(errors, source, /configuracion_negocio_organization_id_key[\s\S]{0,100}?UNIQUE\s*\(\s*organization_id\s*\)/i, 'una configuracion por organization');

  requireMatch(errors, source, /ALTER TABLE\s+public\.business_capabilities[\s\S]{0,180}?DROP CONSTRAINT IF EXISTS\s+business_capabilities_singleton/i, 'eliminacion de constraint singleton de capabilities');
  requireMatch(errors, source, /ALTER TABLE\s+public\.business_capabilities[\s\S]{0,240}?ADD COLUMN\s+organization_id\s+uuid/i, 'business_capabilities.organization_id');
  requireMatch(errors, source, /business_capabilities_organization_id_fkey[\s\S]{0,180}?REFERENCES\s+public\.organizations\s*\(\s*id\s*\)/i, 'business_capabilities -> organizations');
  requireMatch(errors, source, /business_capabilities_organization_id_key[\s\S]{0,100}?UNIQUE\s*\(\s*organization_id\s*\)/i, 'una fila capabilities por organization');
  requireMatch(errors, source, /FOREIGN KEY\s*\(\s*organization_id\s*,\s*business_id\s*\)[\s\S]{0,180}?REFERENCES\s+public\.configuracion_negocio\s*\(\s*organization_id\s*,\s*id\s*\)/i, 'FK compuesta capabilities/configuracion dentro del tenant');

  const signature = source.match(
    /CREATE OR REPLACE FUNCTION\s+public\.bootstrap_organization_v1\s*\(([\s\S]*?)\)\s*RETURNS\s+uuid/i,
  );
  if (!signature) {
    errors.push('Falta: RPC bootstrap_organization_v1 con retorno UUID');
  } else if (/organization_id/i.test(signature[1])) {
    errors.push('bootstrap_organization_v1 no debe aceptar organization_id del cliente');
  }

  requireMatch(errors, source, /bootstrap_organization_v1[\s\S]{0,600}?LANGUAGE\s+plpgsql[\s\S]{0,120}?SECURITY DEFINER[\s\S]{0,120}?SET search_path\s*=\s*pg_catalog/i, 'bootstrap SECURITY DEFINER con search_path seguro');
  requireMatch(errors, source, /v_user_id\s+uuid\s*:=\s*auth\.uid\(\)/i, 'bootstrap deriva usuario desde auth.uid()');
  requireMatch(errors, source, /FROM\s+auth\.users[\s\S]{0,100}?WHERE\s+id\s*=\s*v_user_id[\s\S]{0,100}?FOR UPDATE/i, 'bootstrap serializa por auth.users');
  requireMatch(errors, source, /FROM\s+public\.app_users[\s\S]{0,120}?WHERE\s+user_id\s*=\s*v_user_id/i, 'bootstrap rechaza usuario ya asociado');
  requireMatch(errors, source, /FROM\s+public\.empleados[\s\S]{0,140}?auth_id\s*=\s*v_user_id\s+OR\s+app_user_id\s*=\s*v_user_id/i, 'bootstrap evita crear empresa sobre identidad legacy sin migrar');

  requireMatch(errors, source, /INSERT INTO\s+public\.organizations\s*\([\s\S]{0,500}?RETURNING\s+id\s+INTO\s+v_organization_id/i, 'bootstrap crea organization y obtiene UUID server-side');
  requireMatch(errors, source, /INSERT INTO\s+public\.app_users[\s\S]{0,500}?v_organization_id[\s\S]{0,220}?'admin'/i, 'bootstrap crea app_user admin');
  requireMatch(errors, source, /INSERT INTO\s+public\.configuracion_negocio[\s\S]{0,500}?v_organization_id[\s\S]{0,260}?RETURNING\s+id\s+INTO\s+v_configuration_id/i, 'bootstrap crea configuracion tenant');
  requireMatch(errors, source, /INSERT INTO\s+public\.business_capabilities[\s\S]{0,300}?v_configuration_id[\s\S]{0,120}?v_organization_id/i, 'bootstrap crea capabilities default tenant');
  requireMatch(errors, source, /RETURN\s+v_organization_id\s*;/i, 'bootstrap retorna organization_id creado');

  requireMatch(errors, source, /REVOKE ALL ON FUNCTION\s+public\.bootstrap_organization_v1\(text,\s*text,\s*text,\s*text,\s*text\)[\s\S]{0,80}?FROM\s+PUBLIC,\s*anon/i, 'bootstrap no ejecutable por PUBLIC/anon');
  requireMatch(errors, source, /GRANT EXECUTE ON FUNCTION\s+public\.bootstrap_organization_v1\(text,\s*text,\s*text,\s*text,\s*text\)[\s\S]{0,80}?TO\s+authenticated/i, 'bootstrap ejecutable solo por authenticated');

  if (/\bbusiness_id\s*=\s*1\b/i.test(source)) {
    errors.push('bootstrap no puede depender de business_id fijo');
  }
  if (
    /INSERT INTO\s+public\.business_capabilities\s*\(\s*business_id\s*,\s*organization_id\s*\)[\s\S]{0,120}?VALUES\s*\(\s*1\b/i.test(
      source,
    )
  ) {
    errors.push('bootstrap no puede insertar business_id fijo');
  }
  if (/\bconfiguracion_negocio\b[\s\S]{0,500}?\bWHERE\s+(?:[a-z_][a-z0-9_]*\.)?id\s*=\s*1\b/i.test(source)) {
    errors.push('bootstrap no puede seleccionar configuracion singleton');
  }
  if (/EXCEPTION\s+WHEN\s+OTHERS/i.test(source)) {
    errors.push('bootstrap no debe tragar errores: la transaccion debe hacer rollback');
  }

  return errors;
}

function selfTest(source) {
  const validErrors = verifyBootstrap(source);
  if (validErrors.length) {
    console.error('SaaS bootstrap self-test FAILED (contrato valido rechazado):');
    for (const error of validErrors) console.error(`  - ${error}`);
    process.exit(1);
  }

  const clientTenant = source.replace(
    'p_display_name text,',
    'p_organization_id uuid,\n  p_display_name text,',
  );
  if (clientTenant === source) {
    console.error('SaaS bootstrap self-test FAILED (fixture organization_id cliente no pudo construirse).');
    process.exit(1);
  }
  if (verifyBootstrap(clientTenant).length === 0) {
    console.error('SaaS bootstrap self-test FAILED (organization_id cliente no detectado).');
    process.exit(1);
  }

  const fixedBusiness = source.replace(
    /v_configuration_id,\s+v_organization_id/,
    '1,\n    v_organization_id',
  );
  if (fixedBusiness === source) {
    console.error('SaaS bootstrap self-test FAILED (fixture business_id fijo no pudo construirse).');
    process.exit(1);
  }
  if (verifyBootstrap(fixedBusiness).length === 0) {
    console.error('SaaS bootstrap self-test FAILED (business_id fijo no detectado).');
    process.exit(1);
  }

  const swallowed = source.replace(
    /RETURN\s+v_organization_id\s*;\s*END;/,
    'RETURN v_organization_id;\nEXCEPTION WHEN OTHERS THEN RETURN NULL;\nEND;',
  );
  if (swallowed === source) {
    console.error('SaaS bootstrap self-test FAILED (fixture rollback roto no pudo construirse).');
    process.exit(1);
  }
  if (verifyBootstrap(swallowed).length === 0) {
    console.error('SaaS bootstrap self-test FAILED (rollback roto no detectado).');
    process.exit(1);
  }

  console.log('SaaS bootstrap self-test OK (4 contratos/casos).');
}

const file = path.join(root, 'supabase', 'migrations', migration);
if (!fs.existsSync(file)) {
  console.error(`SaaS bootstrap gate FAILED: falta ${migration}`);
  process.exit(1);
}

const source = fs.readFileSync(file, 'utf8');
if (process.argv.includes('--self-test')) {
  selfTest(source);
  process.exit(0);
}

const errors = verifyBootstrap(source);
if (errors.length) {
  console.error('SaaS bootstrap gate FAILED:');
  for (const error of errors) console.error(`  - ${error}`);
  process.exit(1);
}

console.log(`SaaS bootstrap gate OK: ${migration}`);
