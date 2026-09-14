import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const schemaName = '20260908000316_saas_sales_tenant_schema.sql';
const rpcName = '20260908000924_saas_sales_rpc_guards.sql';
const legacyName = '20260908001424_saas_sales_legacy_internal_scope.sql';

const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const schema = () => read(`supabase/migrations/${schemaName}`);
const rpc = () => read(`supabase/migrations/${rpcName}`);
const legacy = () => read(`supabase/migrations/${legacyName}`);
const ventasRepo = () => read('packages/core_logic/lib/features/ventas/data/ventas_repository.dart');
const deudasRepo = () => read('packages/core_logic/lib/features/deudas/data/deudas_repository.dart');

function need(errors, source, regex, label) {
  if (!regex.test(source)) errors.push(`Falta: ${label}`);
}

function fnBlock(source, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return source.match(new RegExp(`CREATE\\s+(?:OR\\s+REPLACE\\s+)?FUNCTION\\s+${escaped}[\\s\\S]*?\\$\\$;`, 'i'))?.[0] ?? '';
}

function mutated(source, regex, replacement, label) {
  const next = source.replace(regex, replacement);
  if (next === source) {
    throw new Error(`Self-test fixture no pudo mutar: ${label}`);
  }
  return next;
}

function verify(s, r, l, vr, dr) {
  const errors = [];
  const domainTables = [
    'ventas','detalle_ventas','pagos_venta','cotizaciones','detalle_cotizaciones',
    'pagos_deuda_requests','ventas_requests_anulados',
  ];

  for (const table of domainTables) {
    need(errors,s,new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ADD COLUMN\\s+organization_id\\s+uuid`,'i'),`${table}.organization_id`);
    need(errors,s,new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ALTER COLUMN\\s+organization_id\\s+SET NOT NULL`,'i'),`${table}.organization_id NOT NULL`);
    need(errors,s,new RegExp(`${table}_organization_id_fkey[\\s\\S]{0,180}?REFERENCES\\s+public\\.organizations\\s*\\(\\s*id\\s*\\)`,'i'),`${table} -> organizations`);
    need(errors,s,new RegExp(`CREATE TRIGGER\\s+${table}_enforce_organization_id`,'i'),`${table} trigger tenant`);
    need(errors,s,new RegExp(`ALTER TABLE\\s+public\\.${table}\\s+ENABLE ROW LEVEL SECURITY`,'i'),`${table} RLS`);
    need(errors,s,new RegExp(`REVOKE ALL ON TABLE\\s+public\\.${table}\\s+FROM\\s+PUBLIC,\\s*anon,\\s*authenticated`,'i'),`${table} default deny`);
  }

  const composite = [
    ['ventas_cliente_id_fkey','clientes'],
    ['ventas_vendedor_id_fkey','empleados'],
    ['detalle_ventas_venta_id_fkey','ventas'],
    ['detalle_ventas_producto_id_fkey','productos'],
    ['detalle_ventas_almacen_id_fkey','almacenes'],
    ['pagos_venta_venta_id_fkey','ventas'],
    ['cotizaciones_cliente_id_fkey','clientes'],
    ['detalle_cotizaciones_cotizacion_id_fkey','cotizaciones'],
    ['detalle_cotizaciones_producto_id_fkey','productos'],
    ['detalle_cotizaciones_almacen_id_fkey','almacenes'],
    ['pagos_deuda_requests_empleado_id_fkey','empleados'],
  ];
  for (const [constraint,parent] of composite) {
    need(errors,s,new RegExp(`${constraint}[\\s\\S]{0,180}?FOREIGN KEY\\s*\\(\\s*organization_id\\s*,[\\s\\S]{0,100}?\\)[\\s\\S]{0,180}?REFERENCES\\s+public\\.${parent}\\s*\\(\\s*organization_id\\s*,\\s*id\\s*\\)`,'i'),`${constraint} tenant-qualified`);
  }
  need(errors,s,/pagos_venta_request_id_fkey[\s\S]{0,220}?FOREIGN KEY\s*\(\s*organization_id\s*,\s*request_id\s*\)[\s\S]{0,180}?pagos_deuda_requests\s*\(\s*organization_id\s*,\s*request_id\s*\)/i,'pago/request tenant-qualified');

  for (const [policy,perm] of [
    ['ventas_tenant_select','tenant.read'],['detalle_ventas_tenant_select','tenant.read'],
    ['pagos_venta_tenant_select','tenant.read'],['cotizaciones_tenant_select','tenant.read'],
    ['detalle_cotizaciones_tenant_select','tenant.read'],['ventas_requests_anulados_tenant_select','tenant.admin'],
  ]) {
    const block=s.match(new RegExp(`CREATE POLICY\\s+${policy}[\\s\\S]*?;`,'i'))?.[0]??'';
    if (!block.includes(`private.has_permission('${perm}')`) || !/row_belongs_to_current_organization\(organization_id\)/i.test(block)) {
      errors.push(`Falta: ${policy} tenant-aware`);
    }
  }

  need(errors,r,/ALTER TABLE\s+public\.constancias_descuento\s+ADD COLUMN\s+organization_id\s+uuid/i,'constancias_descuento tenant');
  need(errors,r,/constancias_descuento_venta_id_fkey[\s\S]{0,220}?FOREIGN KEY\s*\(\s*organization_id\s*,\s*venta_id\s*\)[\s\S]{0,180}?public\.ventas\s*\(\s*organization_id\s*,\s*id\s*\)/i,'constancia -> venta tenant');
  need(errors,r,/constancias_descuento_organization_codigo_key[\s\S]{0,120}?organization_id\s*,\s*codigo/i,'código constancia por tenant');

  for (const helper of [
    'private.assert_customer_in_current_organization',
    'private.assert_quotation_in_current_organization',
    'private.assert_sale_in_current_organization',
    'private.assert_sale_payment_in_current_organization',
    'private.assert_sales_request_scope',
    'private.assert_sales_payload_in_current_organization',
  ]) {
    need(errors,r,new RegExp(`CREATE OR REPLACE FUNCTION\\s+${helper}`,'i'),helper);
    need(errors,r,new RegExp(`REVOKE ALL ON FUNCTION\\s+${helper.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')}`,'i'),`${helper} privado`);
  }

  for (const [regex,label] of [
    [/WHERE cn\.organization_id = private\.require_current_organization_id\(\)/i,'configuración de venta por tenant'],
    [/vra\.organization_id = private\.require_current_organization_id\(\)/i,'request anulado por tenant'],
    [/v\.organization_id = private\.require_current_organization_id\(\)[\s\S]{0,100}?v\.request_id = p_request_id/i,'idempotencia venta por tenant'],
    [/c\.organization_id = private\.require_current_organization_id\(\)[\s\S]{0,100}?c\.id = p_cliente_id/i,'cliente por tenant'],
    [/p\.organization_id = private\.require_current_organization_id\(\)[\s\S]{0,100}?p\.id = v_prod_id/i,'producto por tenant'],
    [/a\.organization_id = private\.require_current_organization_id\(\)[\s\S]{0,100}?a\.id = v_almacen_id/i,'almacén por tenant'],
    [/ia\.organization_id = private\.require_current_organization_id\(\)[\s\S]{0,120}?ia\.producto_id = v_prod_id/i,'stock leído por tenant'],
    [/WHERE organization_id = private\.require_current_organization_id\(\)[\s\S]{0,120}?producto_id = v_prod_id/i,'stock actualizado por tenant'],
  ]) need(errors,r,regex,label);

  const saleV4=fnBlock(r,'public.process_sale_v4(');
  const saleUnitsV4=fnBlock(r,'public.process_sale_with_units_v4(');
  for (const [block,name] of [[saleV4,'process_sale_v4'],[saleUnitsV4,'process_sale_with_units_v4']]) {
    need(errors,block,/assert_sales_payload_in_current_organization/i,`${name} precheck tenant`);
    need(errors,block,/Electronic invoicing is temporarily disabled until fiscal tenant rollout F3\.7/i,`${name} bloquea fiscal aún global`);
    need(errors,block,/app_tiene_permiso\('sales\.create'\)/i,`${name} permiso ventas`);
    need(errors,block,/SET search_path\s*=\s*''/i,`${name} search_path`);
  }

  const debt=fnBlock(r,'public.procesar_pago_deuda_v2(');
  need(errors,debt,/p_es_cliente IS DISTINCT FROM true/i,'pago proveedor diferido a F3.6');
  need(errors,debt,/Cash debt payments are disabled until cash sessions are tenant-aware in F4\.3/i,'caja en efectivo diferida a F4.3');
  need(errors,debt,/assert_sale_in_current_organization\(p_deuda_id\)/i,'cobro cliente valida venta tenant');

  const quote=fnBlock(r,'public.guardar_cotizacion_v2(');
  const quoteUnits=fnBlock(r,'public.guardar_cotizacion_with_units_v2(');
  for (const [block,name] of [[quote,'guardar_cotizacion_v2'],[quoteUnits,'guardar_cotizacion_with_units_v2']]) {
    need(errors,block,/assert_sales_payload_in_current_organization/i,`${name} valida payload tenant`);
  }

  const cancel=fnBlock(r,'public.anular_venta_v2(');
  need(errors,cancel,/assert_sale_in_current_organization\(p_venta_id\)/i,'anulación valida venta tenant');
  need(errors,cancel,/ventas_requests_anulados[\s\S]{0,120}?organization_id=v_org/i,'anulación idempotente tenant');

  const paymentDelete=fnBlock(r,'public.eliminar_pago_venta_v1(');
  need(errors,paymentDelete,/assert_sale_payment_in_current_organization/i,'eliminar pago valida tenant');
  need(errors,paymentDelete,/WHERE organization_id=v_org AND id=p_venta_id/i,'recalcula venta tenant');

  for (const [regex,label] of [
    [/patch_cancel_legacy[\s\S]*?e\.organization_id = private\.require_current_organization_id\(\)[\s\S]*?e\.auth_id = auth\.uid\(\)/i,'actor de anulación por tenant'],
    [/patch_cancel_legacy[\s\S]*?FROM public\.ventas[\s\S]*?organization_id = private\.require_current_organization_id\(\)[\s\S]*?id = p_venta_id/i,'venta de anulación por tenant'],
    [/patch_cancel_legacy[\s\S]*?dv\.organization_id = private\.require_current_organization_id\(\)[\s\S]*?dv\.venta_id = p_venta_id/i,'detalles de anulación por tenant'],
    [/patch_debt_legacy[\s\S]*?e\.organization_id = private\.require_current_organization_id\(\)[\s\S]*?e\.auth_id = v_auth_user_id/i,'actor de cobro por tenant'],
    [/patch_debt_legacy[\s\S]*?pagos_deuda_requests[\s\S]*?organization_id = private\.require_current_organization_id\(\)[\s\S]*?request_id = p_request_id/i,'replay de cobro por tenant'],
    [/patch_debt_legacy[\s\S]*?FROM public\.ventas[\s\S]*?organization_id = private\.require_current_organization_id\(\)[\s\S]*?id = p_deuda_id/i,'deuda cliente por tenant'],
  ]) need(errors,l,regex,label);
  need(errors,l,/REVOKE ALL ON FUNCTION public\.anular_venta_v2_unscaled_legacy\(bigint,text\) FROM PUBLIC,anon,authenticated/i,'legacy anulación no expuesto');
  need(errors,l,/REVOKE ALL ON FUNCTION public\._legacy_procesar_pago_deuda_v2\([\s\S]{0,180}?\) FROM PUBLIC,anon,authenticated/i,'legacy cobro no expuesto');

  const blocked=[
    'process_sale_v3','process_sale_authorized_v4','process_sale_with_units_v1',
    'process_sale_with_units_v2','process_sale_with_units_v3','anular_venta',
    'anular_venta_with_units_v3','guardar_cotizacion_with_units_v1','procesar_pago_deuda',
  ];
  for (const name of blocked) {
    need(errors,r,new RegExp(`REVOKE ALL ON FUNCTION\\s+public\\.${name}\\(`,'i'),`${name} revocado`);
  }

  for (const name of [
    'process_sale_v4','process_sale_with_units_v4','guardar_cotizacion_v2',
    'guardar_cotizacion_with_units_v2','actualizar_cotizaciones_vencidas',
    'eliminar_cotizacion_v2','eliminar_pago_venta_v1','procesar_pago_deuda_v2','anular_venta_v2',
  ]) {
    need(errors,r,new RegExp(`GRANT EXECUTE ON FUNCTION\\s+public\\.${name}\\(`,'i'),`${name} allowlist`);
  }

  need(errors,vr,/\? 'process_sale_with_units_v4'\s*:\s*'process_sale_v4'/i,'VentasRepository usa v4');
  need(errors,vr,/\? 'guardar_cotizacion_with_units_v2'\s*:\s*'guardar_cotizacion_v2'/i,'VentasRepository usa cotización v2');
  need(errors,vr,/'anular_venta_v2'/i,'VentasRepository usa anulación v2');
  need(errors,vr,/'eliminar_pago_venta_v1'/i,'VentasRepository usa eliminación pago v1 segura');
  need(errors,dr,/'procesar_pago_deuda_v2'/i,'DeudasRepository usa pago deuda v2');
  if (/['"]process_sale_v3['"]|['"]process_sale_with_units_v[123]['"]/.test(vr)) errors.push('Runtime no debe invocar motores de venta legacy');

  return errors;
}

function selfTest() {
  const s=schema(), r=rpc(), l=legacy(), vr=ventasRepo(), dr=deudasRepo();
  const valid=verify(s,r,l,vr,dr);
  if (valid.length) {
    console.error('SaaS sales self-test FAILED (contrato válido rechazado):');
    valid.forEach(e=>console.error(`  - ${e}`));
    process.exit(1);
  }
  const mutations=[
    ['sin FK detalle/producto tenant',mutated(s,/ADD CONSTRAINT\s+detalle_ventas_producto_id_fkey\b/i,'ADD CONSTRAINT detalle_ventas_producto_global_fkey','sin FK detalle/producto tenant'),r,l,vr,dr],
    ['singleton configuración restaurado',s,mutated(r,/WHERE\s+cn\.organization_id\s*=\s*private\.require_current_organization_id\(\)/i,'-- tenant filter removed','singleton configuración restaurado'),l,vr,dr],
    ['v4 sin precheck',s,mutated(r,/PERFORM\s+private\.assert_sales_payload_in_current_organization\(p_request_id,p_cliente_id,p_cotizacion_id,p_detalles\);/i,'PERFORM 1;','v4 sin precheck'),l,vr,dr],
    ['legacy cobro global',s,r,mutated(l,/AND\s+e\.auth_id\s*=\s*v_auth_user_id/i,'AND true','legacy cobro global'),vr,dr],
    ['runtime vuelve a v3',s,r,l,mutated(vr,/'process_sale_v4'/,"'process_sale_v3'",'runtime vuelve a v3'),dr],
  ];
  const missed=[];
  for (const [name,ms,mr,ml,mvr,mdr] of mutations) if (verify(ms,mr,ml,mvr,mdr).length===0) missed.push(name);
  if (missed.length) {
    console.error('SaaS sales self-test FAILED:');
    missed.forEach(n=>console.error(`  - no detectó ${n}`));
    process.exit(1);
  }
  console.log(`SaaS sales self-test OK (${mutations.length+1} contratos/casos).`);
}

if (process.argv.includes('--self-test')) { selfTest(); process.exit(0); }
const errors=verify(schema(),rpc(),legacy(),ventasRepo(),deudasRepo());
if (errors.length) {
  console.error('SaaS sales gate FAILED:');
  errors.forEach(e=>console.error(`  - ${e}`));
  process.exit(1);
}
console.log(`SaaS sales gate OK: ${schemaName} + ${rpcName} + ${legacyName}`);
