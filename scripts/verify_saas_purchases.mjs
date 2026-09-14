import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const schemaName = '20260908020030_saas_purchases_tenant_schema.sql';
const rpcName = '20260908020031_saas_purchases_rpc_guards.sql';
const hardeningName = '20260908020032_saas_purchases_request_scope_hardening.sql';

const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const schema = () => read(`supabase/migrations/${schemaName}`);
const rpc = () => read(`supabase/migrations/${rpcName}`);
const hardening = () => read(`supabase/migrations/${hardeningName}`);
const purchaseRuntime = () => read('packages/core_logic/lib/features/compras/data/supabase_purchase_order_gateway.dart');
const expenseRuntime = () => read('packages/core_logic/lib/features/gastos/data/gastos_repository.dart');
const debtRuntime = () => read('packages/core_logic/lib/features/deudas/data/deudas_repository.dart');

function need(errors, source, regex, label) {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
}

function fnBlock(source, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return source.match(new RegExp(`CREATE\\s+OR\\s+REPLACE\\s+FUNCTION\\s+${escaped}[\\s\\S]*?\\$\\$;`, 'i'))?.[0] ?? '';
}

function verify(s, r, h, pr, er, dr) {
  const errors = [];
  const tables = [
    'purchase_orders','purchase_order_lines','purchase_receipts',
    'purchase_receipt_lines','gastos','pagos_gasto',
  ];

  for (const table of tables) {
    need(errors,s,new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ADD COLUMN\\s+organization_id\\s+uuid`,'i'),`${table}.organization_id`);
    need(errors,s,new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ALTER COLUMN\\s+organization_id\\s+SET NOT NULL`,'i'),`${table}.organization_id NOT NULL`);
    need(errors,s,new RegExp(`${table}_organization_id_fkey[\\s\\S]{0,180}?REFERENCES\\s+public\\.organizations\\s*\\(\\s*id\\s*\\)`,'i'),`${table} -> organizations`);
    need(errors,s,new RegExp(`${table}_organization_id_id_key[\\s\\S]{0,120}?UNIQUE\\s*\\(\\s*organization_id\\s*,\\s*id\\s*\\)`,'i'),`${table} clave compuesta`);
    need(errors,s,new RegExp(`CREATE TRIGGER\\s+${table}_enforce_organization_id`,'i'),`${table} trigger tenant`);
    need(errors,s,new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ENABLE ROW LEVEL SECURITY`,'i'),`${table} RLS`);
  }

  const composite = [
    ['purchase_orders_supplier_id_fkey','proveedores','supplier_id'],
    ['purchase_orders_warehouse_id_fkey','almacenes','warehouse_id'],
    ['purchase_order_lines_purchase_order_id_fkey','purchase_orders','purchase_order_id'],
    ['purchase_order_lines_product_id_fkey','productos','product_id'],
    ['purchase_receipts_purchase_order_id_fkey','purchase_orders','purchase_order_id'],
    ['purchase_receipt_lines_purchase_receipt_id_fkey','purchase_receipts','purchase_receipt_id'],
    ['purchase_receipt_lines_purchase_order_line_id_fkey','purchase_order_lines','purchase_order_line_id'],
    ['gastos_proveedor_id_fkey','proveedores','proveedor_id'],
    ['pagos_gasto_gasto_id_fkey','gastos','gasto_id'],
  ];
  for (const [constraint,parent,column] of composite) {
    need(errors,s,new RegExp(`ADD CONSTRAINT\\s+${constraint}[\\s\\S]{0,220}?FOREIGN KEY\\s*\\(\\s*organization_id\\s*,\\s*${column}\\s*\\)[\\s\\S]{0,180}?REFERENCES\\s+public\\.${parent}\\s*\\(\\s*organization_id\\s*,\\s*id\\s*\\)`,'i'),`${constraint} tenant-qualified`);
  }
  need(errors,s,/pagos_gasto_request_id_fkey[\s\S]{0,220}?FOREIGN KEY\s*\(\s*organization_id\s*,\s*request_id\s*\)[\s\S]{0,200}?pagos_deuda_requests\s*\(\s*organization_id\s*,\s*request_id\s*\)/i,'pago gasto/request tenant-qualified');

  need(errors,s,/purchase_orders_organization_request_key[\s\S]{0,120}?UNIQUE\s*\(\s*organization_id\s*,\s*request_id\s*\)/i,'idempotencia OC por tenant');
  need(errors,s,/purchase_receipts_organization_request_key[\s\S]{0,120}?UNIQUE\s*\(\s*organization_id\s*,\s*request_id\s*\)/i,'idempotencia recepción por tenant');
  need(errors,s,/pagos_gasto_organization_request_uidx[\s\S]{0,150}?organization_id\s*,\s*request_id/i,'idempotencia pago gasto por tenant');

  for (const [policy,table] of [['gastos_tenant_select','gastos'],['pagos_gasto_tenant_select','pagos_gasto']]) {
    const block=s.match(new RegExp(`CREATE POLICY\\s+${policy}[\\s\\S]*?;`,'i'))?.[0]??'';
    if (!/private\.has_permission\('tenant\.read'\)/i.test(block) || !/row_belongs_to_current_organization\(organization_id\)/i.test(block)) {
      errors.push(`Falta: ${policy} tenant-aware en ${table}`);
    }
  }
  for (const table of ['purchase_orders','purchase_order_lines','purchase_receipts','purchase_receipt_lines']) {
    need(errors,s,new RegExp(`REVOKE ALL ON TABLE\\s+public\\.${table}\\s+FROM\\s+PUBLIC,\\s*anon,\\s*authenticated`,'i'),`${table} RPC-only`);
  }
  need(errors,s,/REVOKE ALL ON TABLE\s+public\.gastos\s+FROM\s+PUBLIC,anon,authenticated/i,'gastos write default deny');
  need(errors,s,/GRANT SELECT ON TABLE\s+public\.gastos\s+TO\s+authenticated/i,'gastos sólo lectura directa');

  const capability=fnBlock(r,'public._business_enforce_purchase_capability(');
  need(errors,capability,/business_capabilities[\s\S]{0,180}?organization_id\s*=\s*v_org/i,'capability compras por tenant');
  if (/business_id\s*=\s*1/i.test(capability)) errors.push('Singleton business_id=1 reapareció en compras');
  need(errors,capability,/SET search_path\s*=\s*''/i,'capability guard search_path');

  const serviceGuard=fnBlock(r,'public._service_block_purchase_line_v1(');
  need(errors,serviceGuard,/p\.organization_id\s*=\s*v_org/i,'service purchase guard por tenant');

  for (const helper of [
    'private.assert_supplier_in_current_organization',
    'private.assert_purchase_order_in_current_organization',
    'private.assert_expense_in_current_organization',
    'private.assert_expense_payment_in_current_organization',
    'private.assert_purchase_payload_in_current_organization',
    'private.purchase_order_json',
  ]) {
    const source = helper==='private.assert_purchase_payload_in_current_organization' ? h : r;
    need(errors,source,new RegExp(`CREATE OR REPLACE FUNCTION\\s+${helper}`,'i'),helper);
    need(errors,source,new RegExp(`REVOKE ALL ON FUNCTION\\s+${helper.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}`,'i'),`${helper} privado`);
  }

  const createOrder=fnBlock(r,'public.create_purchase_order_v1(');
  need(errors,createOrder,/assert_purchase_payload_in_current_organization/i,'crear OC valida tenant');
  need(errors,createOrder,/organization_id,request_id,supplier_id,warehouse_id/i,'crear OC escribe tenant explícito');
  need(errors,createOrder,/WHERE organization_id=v_org AND request_id=p_request_id/i,'replay OC por tenant');
  need(errors,createOrder,/SET search_path\s*=\s*''/i,'crear OC search_path');

  const listOrders=fnBlock(r,'public.list_purchase_orders_v1(');
  need(errors,listOrders,/WHERE o\.organization_id=v_org/i,'listar OC por tenant');

  const cancelOrder=fnBlock(r,'public.cancel_purchase_order_v1(');
  need(errors,cancelOrder,/assert_purchase_order_in_current_organization/i,'anular OC valida tenant');
  need(errors,cancelOrder,/WHERE organization_id=v_org AND id=p_purchase_order_id/i,'anular OC muta tenant');

  const receive=fnBlock(r,'public.receive_purchase_order_v2(');
  need(errors,receive,/assert_purchase_order_in_current_organization/i,'recibir OC valida tenant');
  need(errors,receive,/WHERE r\.organization_id=v_org AND r\.request_id=p_request_id/i,'replay recepción por tenant');
  need(errors,receive,/organization_id,request_id,purchase_order_id,received_at,document,notes,received_by/i,'recepción escribe tenant explícito');
  need(errors,receive,/WHERE organization_id=v_org[\s\S]{0,140}?purchase_order_id=p_purchase_order_id/i,'línea recepción tenant');

  // 08020031 creó una versión intermedia con precheck UUID global. 08020032
  // lo elimina antes del estado final del esquema. Validamos el parche final,
  // no tratamos la definición intermedia como si fuera la función resultante.
  need(errors,h,/DO \$patch_receipt_request_scope\$/i,'hardening retira precheck UUID global');
  need(errors,h,/WHERE request_id=p_request_id AND organization_id IS DISTINCT FROM v_org/i,'hardening identifica exactamente el precheck global');
  need(errors,h,/v_def:=replace\(v_def,v_old_lf,''\)/i,'hardening elimina variante LF');
  need(errors,h,/v_def:=replace\(v_def,v_old_crlf,''\)/i,'hardening elimina variante CRLF');
  need(errors,h,/EXECUTE v_def/i,'hardening reinstala función corregida');

  const expense=fnBlock(r,'public.registrar_gasto_mixto(');
  need(errors,expense,/private\.has_permission\('tenant\.write'\)/i,'gasto exige tenant.write');
  need(errors,expense,/assert_supplier_in_current_organization/i,'gasto valida proveedor tenant');
  need(errors,expense,/Cash-box expense payments are disabled until cash sessions are tenant-aware in F4\.3/i,'gasto caja fail-closed');
  need(errors,expense,/organization_id,fecha,proveedor_id,categoria,monto,descripcion,estado,saldo/i,'gasto escribe tenant explícito');

  const deleteExpense=fnBlock(r,'public.eliminar_gasto_v1(');
  need(errors,deleteExpense,/assert_expense_in_current_organization/i,'eliminar gasto valida tenant');
  const deleteExpensePayment=fnBlock(r,'public.eliminar_pago_gasto_v1(');
  need(errors,deleteExpensePayment,/assert_expense_payment_in_current_organization/i,'eliminar pago gasto valida tenant');
  need(errors,deleteExpensePayment,/WHERE organization_id=v_org AND gasto_id=p_gasto_id/i,'recalcula pagos por tenant');

  need(errors,r,/REVOKE ALL ON FUNCTION\s+public\.receive_purchase_order_v1\(/i,'receive purchase v1 revocado');
  need(errors,r,/REVOKE ALL ON FUNCTION\s+public\.registrar_gasto\(/i,'registrar_gasto legacy revocado');
  need(errors,r,/REVOKE ALL ON FUNCTION\s+public\._purchase_order_json\(/i,'serializer legacy revocado');

  need(errors,r,/F3\.6 debt patch mismatch: supplier expense lookup/i,'patch deuda proveedor lookup');
  need(errors,r,/F3\.6 debt patch mismatch: supplier expense update/i,'patch deuda proveedor update');
  const debt=fnBlock(r,'public.procesar_pago_deuda_v2(');
  need(errors,debt,/p_es_cliente IS FALSE/i,'pago deuda reabre proveedor');
  need(errors,debt,/assert_expense_in_current_organization\(p_deuda_id\)/i,'pago proveedor valida gasto tenant');
  need(errors,debt,/Cash-box supplier payments are disabled until cash sessions are tenant-aware in F4\.3/i,'pago proveedor caja fail-closed');
  need(errors,debt,/app_tiene_permiso\('purchases\.manage'\)/i,'pago proveedor exige permiso compras');

  need(errors,h,/CREATE OR REPLACE FUNCTION\s+private\.enforce_debt_request_target_tenant/i,'trigger helper deuda polimórfica');
  need(errors,h,/CREATE TRIGGER\s+pagos_deuda_requests_validate_target_tenant/i,'trigger deuda polimórfica');
  need(errors,h,/FROM public\.gastos[\s\S]{0,120}?organization_id=NEW\.organization_id[\s\S]{0,80}?id=NEW\.deuda_id/i,'deuda proveedor target tenant');
  need(errors,h,/FROM public\.ventas[\s\S]{0,120}?organization_id=NEW\.organization_id[\s\S]{0,80}?id=NEW\.deuda_id/i,'deuda cliente target tenant');

  // Runtime consume sólo entrypoints allowlisted.
  for (const name of ['list_purchase_orders_v1','create_purchase_order_v1','receive_purchase_order_v2','cancel_purchase_order_v1']) {
    need(errors,pr,new RegExp(`['"]${name}['"]`),`runtime compras usa ${name}`);
  }
  if (/['"]receive_purchase_order_v1['"]/.test(pr)) errors.push('Runtime compras no debe usar receive_purchase_order_v1');
  need(errors,er,/'registrar_gasto_mixto'/i,'runtime gastos usa registrar_gasto_mixto');
  need(errors,er,/'eliminar_gasto_v1'/i,'runtime gastos usa eliminar_gasto_v1');
  need(errors,er,/'eliminar_pago_gasto_v1'/i,'runtime gastos usa eliminar_pago_gasto_v1');
  need(errors,dr,/'procesar_pago_deuda_v2'/i,'runtime deuda usa v2');

  for (const name of [
    'create_purchase_order_v1','list_purchase_orders_v1','cancel_purchase_order_v1',
    'receive_purchase_order_v2','registrar_gasto_mixto','eliminar_gasto_v1',
    'eliminar_pago_gasto_v1','procesar_pago_deuda_v2',
  ]) {
    need(errors,r,new RegExp(`GRANT EXECUTE ON FUNCTION\\s+public\\.${name}\\(`,'i'),`${name} allowlist`);
  }

  return errors;
}

function selfTest() {
  const s=schema(),r=rpc(),h=hardening(),pr=purchaseRuntime(),er=expenseRuntime(),dr=debtRuntime();
  const valid=verify(s,r,h,pr,er,dr);
  if (valid.length) {
    console.error('SaaS purchases self-test FAILED (contrato válido rechazado):');
    valid.forEach(e=>console.error(`  - ${e}`));
    process.exit(1);
  }

  const mutations=[
    ['singleton capability',s,r.replace('WHERE b.organization_id = v_org','WHERE business_id = 1'),h,pr,er,dr],
    ['sin FK OC/proveedor tenant',s.replace('ADD CONSTRAINT purchase_orders_supplier_id_fkey','ADD CONSTRAINT purchase_orders_supplier_global_fkey'),r,h,pr,er,dr],
    ['recepción runtime v1',s,r,h,pr.replace("'receive_purchase_order_v2'","'receive_purchase_order_v1'"),er,dr],
    ['sin request-scope hardening',s,r,h.replace('DO $patch_receipt_request_scope$','DO $patch_receipt_request_scope_removed$'),pr,er,dr],
    ['sin debt target trigger',s,r,h.replace('CREATE TRIGGER pagos_deuda_requests_validate_target_tenant','CREATE TRIGGER pagos_deuda_requests_target_removed'),pr,er,dr],
    ['gasto sin bloqueo caja',s,r.replace('Cash-box expense payments are disabled until cash sessions are tenant-aware in F4.3','cash allowed'),h,pr,er,dr],
  ];
  const missed=[];
  for (const [name,ms,mr,mh,mpr,mer,mdr] of mutations) {
    if (verify(ms,mr,mh,mpr,mer,mdr).length===0) missed.push(name);
  }
  if (missed.length) {
    console.error('SaaS purchases self-test FAILED:');
    missed.forEach(n=>console.error(`  - no detectó ${n}`));
    process.exit(1);
  }
  console.log(`SaaS purchases self-test OK (${mutations.length+1} contratos/casos).`);
}

if (process.argv.includes('--self-test')) { selfTest(); process.exit(0); }
const errors=verify(schema(),rpc(),hardening(),purchaseRuntime(),expenseRuntime(),debtRuntime());
if (errors.length) {
  console.error('SaaS purchases gate FAILED:');
  errors.forEach(e=>console.error(`  - ${e}`));
  process.exit(1);
}
console.log(`SaaS purchases gate OK: ${schemaName} + ${rpcName} + ${hardeningName}`);
