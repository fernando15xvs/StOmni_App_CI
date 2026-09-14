import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const migrations = [
  'supabase/migrations/20260908045000_saas_typed_custom_fields_rules.sql',
  'supabase/migrations/20260908045100_saas_custom_fields_safety.sql',
  'supabase/migrations/20260908045200_saas_custom_fields_trigger_order.sql',
];
const coreFiles = [
  'packages/core_logic/lib/customization/domain/custom_field_definition.dart',
  'packages/core_logic/lib/customization/application/custom_field_gateway.dart',
  'packages/core_logic/lib/customization/data/supabase_custom_field_gateway.dart',
  'packages/core_logic/lib/customization/providers/custom_field_providers.dart',
];
const read = (f) => fs.readFileSync(path.join(root, f), 'utf8');
const sql = () => migrations.map(read).join('\n');
const safety = () => read(migrations[1]);
const core = () => coreFiles.map(read).join('\n');

function need(errors, source, regex, label) {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
}

function verify(sqlSource, safetySource, coreSource) {
  const errors=[];
  for (const table of ['productos','clientes','proveedores']) {
    need(errors,sqlSource,new RegExp(`ALTER TABLE public\\.${table}[\\s\\S]{0,100}?ADD COLUMN custom_fields jsonb NOT NULL DEFAULT '\\{\\}'::jsonb`,'i'),`${table}.custom_fields JSONB`);
  }
  need(errors,sqlSource,/CREATE TABLE public\.custom_field_definitions/i,'tabla definiciones');
  need(errors,sqlSource,/UNIQUE\(organization_id,id\)/i,'clave compuesta definiciones');
  need(errors,sqlSource,/UNIQUE INDEX custom_field_definitions_code_key[\s\S]{0,120}?organization_id,entity_type,code/i,'code único por tenant+entidad');
  need(errors,sqlSource,/entity_type IN \('catalog_item','customer','supplier'\)/i,'entidades permitidas');
  need(errors,sqlSource,/value_type IN \('text','number','boolean','date','select','multiselect'\)/i,'tipos configurables permitidos');
  need(errors,sqlSource,/CREATE POLICY custom_field_definitions_tenant_select[\s\S]{0,200}?row_belongs_to_current_organization\(organization_id\)/i,'RLS definiciones');
  need(errors,safetySource,/v_key NOT IN \('min','max','min_length','max_length'\)/i,'allowlist de reglas no ejecutables');
  need(errors,safetySource,/pg_column_size\(v_values\)>65536/i,'límite payload 64 KiB');
  need(errors,safetySource,/jsonb_array_length\(p_options\)>100/i,'límite opciones');
  need(errors,safetySource,/to_jsonb\(NEW\)/i,'trigger universal layout-safe');
  need(errors,sqlSource,/CREATE TRIGGER clientes_validate_custom_fields/i,'trigger cliente');
  need(errors,sqlSource,/CREATE TRIGGER proveedores_validate_custom_fields/i,'trigger proveedor');
  need(errors,sqlSource,/CREATE TRIGGER zzz_productos_validate_custom_fields/i,'trigger producto después de normalización');
  need(errors,sqlSource,/Populate valid values before making custom field required/i,'required rollout seguro');
  need(errors,safetySource,/Remove existing values before restricting custom field to other item types/i,'cambio de alcance seguro');
  need(errors,sqlSource,/Definition change would invalidate existing catalog values/i,'cambio reglas valida datos existentes');
  need(errors,sqlSource,/CREATE OR REPLACE FUNCTION public\.list_custom_field_definitions_v1/i,'RPC listar definiciones');
  need(errors,sqlSource,/CREATE OR REPLACE FUNCTION public\.upsert_custom_field_definition_v1/i,'RPC guardar definición');
  need(errors,sqlSource,/CREATE OR REPLACE FUNCTION public\.set_entity_custom_fields_v1/i,'RPC guardar valores');
  need(errors,sqlSource,/private\.has_permission\('tenant\.admin'\)/i,'definiciones sólo tenant.admin');
  need(errors,sqlSource,/private\.has_permission\('tenant\.write'\)/i,'valores requieren tenant.write');

  need(errors,coreSource,/enum CustomFieldEntityType[\s\S]{0,300}?catalogItem\('catalog_item'\)[\s\S]{0,300}?customer\('customer'\)[\s\S]{0,300}?supplier\('supplier'\)/i,'enum entidad Dart');
  need(errors,coreSource,/enum CustomFieldValueType[\s\S]{0,500}?multiselect\('multiselect'\)/i,'enum tipo Dart');
  need(errors,coreSource,/class CustomFieldDefinition/i,'modelo Dart definición');
  need(errors,coreSource,/abstract interface class CustomFieldGateway/i,'gateway Dart');
  need(errors,coreSource,/class SupabaseCustomFieldGateway implements CustomFieldGateway/i,'gateway Supabase');
  need(errors,coreSource,/list_custom_field_definitions_v1/i,'cliente RPC lista definiciones');
  need(errors,coreSource,/upsert_custom_field_definition_v1/i,'cliente RPC guarda definiciones');
  need(errors,coreSource,/set_entity_custom_fields_v1/i,'cliente RPC guarda valores');
  need(errors,coreSource,/customFieldGatewayProvider/i,'provider configurable');

  if (/CREATE TABLE public\.custom_field_values/i.test(sqlSource)) {
    errors.push('F5.3 no debe introducir EAV por valor; valores viven en custom_fields JSONB');
  }
  if (/pattern/i.test(safetySource)) {
    errors.push('El contrato final F5.3 no debe ejecutar regex configurables por tenant');
  }
  const finalTrigger = safetySource.match(/CREATE OR REPLACE FUNCTION private\.validate_entity_custom_fields\(\)[\s\S]*?\$\$;/i)?.[0] ?? '';
  if (/NEW\.item_type/i.test(finalTrigger)) {
    errors.push('Trigger universal no debe asumir columnas específicas del record NEW');
  }
  return errors;
}

function selfTest() {
  const s=sql(), safe=safety(), c=core();
  const cases=[
    ['válido',s,safe,c,false],
    ['EAV',`${s}\nCREATE TABLE public.custom_field_values(id bigint);`,safe,c,true],
    ['sin payload cap',s,safe.replace('pg_column_size(v_values)>65536','false'),c,true],
    ['regex configurable',s,`${safe}\n-- pattern`,c,true],
    ['sin RPC values',s.replace('CREATE OR REPLACE FUNCTION public.set_entity_custom_fields_v1','CREATE OR REPLACE FUNCTION public.set_entity_values_removed'),safe,c,true],
  ];
  const failed=[];
  for (const [name,a,b,d,shouldFail] of cases) {
    const didFail=verify(a,b,d).length>0;
    if (didFail!==shouldFail) failed.push(name);
  }
  if (failed.length) {
    console.error('SaaS custom fields self-test FAILED:');
    failed.forEach((x)=>console.error(`  - ${x}`));
    process.exit(1);
  }
  console.log(`SaaS custom fields self-test OK (${cases.length} casos).`);
}

if (process.argv.includes('--self-test')) { selfTest(); process.exit(0); }
const errors=verify(sql(),safety(),core());
if (errors.length) {
  console.error('SaaS custom fields gate FAILED:');
  errors.forEach((e)=>console.error(`  - ${e}`));
  process.exit(1);
}
console.log('SaaS custom fields gate OK (F5.3).');