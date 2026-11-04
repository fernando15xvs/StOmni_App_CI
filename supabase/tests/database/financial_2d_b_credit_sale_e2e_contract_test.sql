-- Real RPC v5 with synthetic stock, seller, tenant and two credit purchases.
-- Only local/DEV, BEGIN...ROLLBACK; no production/customer records are read.
BEGIN;
CREATE TEMP TABLE _2db_fixture(
 org uuid,actor uuid,branch uuid,role_id uuid,
 employee_id bigint,customer_id bigint,product_id bigint,warehouse_id bigint,
 request0 uuid,request20 uuid,sale_at timestamptz,
 result0 jsonb,result20 jsonb,retry20 jsonb,reader20 jsonb
) ON COMMIT DROP;
INSERT INTO _2db_fixture(
 org,actor,branch,role_id,employee_id,customer_id,product_id,warehouse_id,
 request0,request20,sale_at)
VALUES(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
 840130101,840130102,840130103,840130104,
 gen_random_uuid(),gen_random_uuid(),now()-interval '1 minute');
GRANT SELECT,UPDATE ON TABLE _2db_fixture TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org,'2D-B sale E2E synthetic org','PE','PEN','America/Lima' FROM _2db_fixture;
INSERT INTO auth.users(id,aud,role)
SELECT actor,'authenticated','authenticated' FROM _2db_fixture;
INSERT INTO public.app_users(user_id,organization_id,status,base_role)
SELECT actor,org,'active','admin' FROM _2db_fixture;
INSERT INTO public.branches(id,organization_id,code,name,is_main,status)
SELECT branch,org,'MAIN','Test Branch',true,'active' FROM _2db_fixture;
INSERT INTO public.roles(id,organization_id,code,name,is_system,status)
SELECT role_id,org,'admin','Admin',true,'active' FROM _2db_fixture;
INSERT INTO public.empleados(id,organization_id,branch_id,auth_id,app_user_id,nombre,rol,activo,employment_status)
SELECT employee_id,org,branch,actor,actor,'Test seller','admin',true,'active'
FROM _2db_fixture;
INSERT INTO public.employee_roles(organization_id,employee_id,role_id)
SELECT org,employee_id,role_id FROM _2db_fixture;
INSERT INTO public.configuracion_negocio(id,organization_id,facturacion_habilitada)
SELECT 840130105,org,false FROM _2db_fixture;
INSERT INTO public.business_capabilities(organization_id,business_id,credit_sales,electronic_invoicing)
SELECT org,840130105,true,false FROM _2db_fixture;
INSERT INTO public.clientes(id,organization_id,nombre)
SELECT customer_id,org,'Test Customer' FROM _2db_fixture;
INSERT INTO public.productos(id,organization_id,nombre,precio_unidad,precio_caja,tipo_venta,permitir_sin_stock,activo,es_servicio,item_type)
SELECT product_id,org,'Test Item',100,100,'UNIDAD',false,true,false,'stock_product'
FROM _2db_fixture;
INSERT INTO public.almacenes(id,organization_id,branch_id,nombre)
SELECT warehouse_id,org,branch,'Test Warehouse' FROM _2db_fixture;
INSERT INTO public.inventario_almacen(organization_id,producto_id,almacen_id,cantidad)
SELECT org,product_id,warehouse_id,15 FROM _2db_fixture;
SET LOCAL session_replication_role=origin;

-- Call the deployed production RPC, not a stub. Role is authenticated and
-- tenant is derived from app_users, not accepted as a request parameter.
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM _2db_fixture),true);
SET LOCAL ROLE authenticated;
UPDATE _2db_fixture SET result0=public.process_sale_credit_v5(
 request0,customer_id,100,sale_at,true,0,
 jsonb_build_array(jsonb_build_object(
   'producto_id',product_id,'almacen_id',warehouse_id,'cantidad',1,
   'piezas_reales',1,'precio_unitario',100,
   'precio_unitario_comercial',100,'subtotal',100,'tipo_unidad','unidad')),
 '[]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,100,NULL,
 jsonb_build_array(jsonb_build_object(
   'number',1,'amount',100,
   'due_date',to_char(sale_at+interval '14 day','YYYY-MM-DD')))
);
RESET ROLE;

-- Assertions fail the whole reversible transaction if any contract breaks.
CREATE FUNCTION pg_temp.credit_e2e_check(p_ok boolean,p_label text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF p_ok IS DISTINCT FROM true THEN
 RAISE EXCEPTION '2D-B real sale: %',p_label; END IF; END $$;
SELECT pg_temp.credit_e2e_check(
 (SELECT (result0->>'success')::boolean AND NOT (result0->>'idempotent')::boolean
   AND (result0->>'balance')::numeric=100 FROM _2db_fixture),'real v5 persisted a credit sale');
SELECT pg_temp.credit_e2e_check(
 (SELECT count(*)=1 FROM public.venta_cronogramas cr CROSS JOIN _2db_fixture f
 WHERE cr.organization_id=f.org AND cr.venta_id=(f.result0->>'venta_id')::bigint
   AND cr.version=1 AND cr.estado='vigente'),'persisted one versioned schedule');
SELECT pg_temp.credit_e2e_check(
 (SELECT count(*)=1 AND sum(c.importe_vigente)=100
 FROM public.venta_cuotas c CROSS JOIN _2db_fixture f
 WHERE c.organization_id=f.org AND c.venta_id=(f.result0->>'venta_id')::bigint),'persisted one exact installment');
SELECT pg_temp.credit_e2e_check(
 (SELECT count(*)=1 AND sum(cf.saldo_pendiente)=100
 FROM public.venta_cuentas_financieras cf CROSS JOIN _2db_fixture f
 WHERE cf.organization_id=f.org AND cf.venta_id=(f.result0->>'venta_id')::bigint
   AND cf.exigible=100 AND cf.cobros_netos=0),'opening ledger balanced');
SELECT pg_temp.credit_e2e_check(
 (SELECT ia.cantidad=14 FROM public.inventario_almacen ia
 CROSS JOIN _2db_fixture f WHERE ia.organization_id=f.org
 AND ia.producto_id=f.product_id AND ia.almacen_id=f.warehouse_id),'real stock decremented once');

-- A second genuine sale with a S/ 20 initial bank transfer and two installments.
-- Retrying the exact same request must not take more stock or double book revenue.
SET LOCAL ROLE authenticated;
UPDATE _2db_fixture SET result20=public.process_sale_credit_v5(
 request20,customer_id,100,sale_at,true,20,
 jsonb_build_array(jsonb_build_object(
   'producto_id',product_id,'almacen_id',warehouse_id,'cantidad',1,
   'piezas_reales',1,'precio_unitario',100,
   'precio_unitario_comercial',100,'subtotal',100,'tipo_unidad','unidad')),
 '[{"metodo":"transferencia","monto":20}]'::jsonb,
 NULL,NULL,'ticket_interno',0,0,NULL,100,NULL,
 jsonb_build_array(
   jsonb_build_object('number',1,'amount',40,
      'due_date',to_char(sale_at+interval '14 day','YYYY-MM-DD')),
   jsonb_build_object('number',2,'amount',40,
      'due_date',to_char(sale_at+interval '28 day','YYYY-MM-DD')))
);
UPDATE _2db_fixture SET retry20=public.process_sale_credit_v5(
 request20,customer_id,100,sale_at,true,20,
 jsonb_build_array(jsonb_build_object(
   'producto_id',product_id,'almacen_id',warehouse_id,'cantidad',1,
   'piezas_reales',1,'precio_unitario',100,
   'precio_unitario_comercial',100,'subtotal',100,'tipo_unidad','unidad')),
 '[{"metodo":"transferencia","monto":20}]'::jsonb,
 NULL,NULL,'ticket_interno',0,0,NULL,100,NULL,
 jsonb_build_array(
   jsonb_build_object('number',1,'amount',40,
      'due_date',to_char(sale_at+interval '14 day','YYYY-MM-DD')),
   jsonb_build_object('number',2,'amount',40,
      'due_date',to_char(sale_at+interval '28 day','YYYY-MM-DD')))
);
UPDATE _2db_fixture SET reader20=public.obtener_cronograma_credito_v1(
  (result20->>'venta_id')::bigint);
RESET ROLE;
SELECT pg_temp.credit_e2e_check(
 (SELECT (result20->>'success')::boolean
   AND NOT (result20->>'idempotent')::boolean
   AND (result20->>'balance')::numeric=80
   AND (retry20->>'idempotent')::boolean
   AND retry20->>'venta_id'=result20->>'venta_id'
 FROM _2db_fixture),'real bank down-payment and exact request retry');
SELECT pg_temp.credit_e2e_check(
 (SELECT reader20->>'venta_id'=result20->>'venta_id'
   AND (reader20->>'cobros_netos')::numeric=20
   AND (reader20->>'saldo_pendiente')::numeric=80
   AND jsonb_array_length(reader20->'cuotas')=2
 FROM _2db_fixture),'authenticated reader returns current bank-paid schedule');
SELECT pg_temp.credit_e2e_check(
 (SELECT count(*)=1 AND SUM(monto)=20
  FROM public.pagos_venta pv CROSS JOIN _2db_fixture f
  WHERE pv.organization_id=f.org AND pv.venta_id=(f.result20->>'venta_id')::bigint),
  'one initial transfer payment after retry');
SELECT pg_temp.credit_e2e_check(
 (SELECT COUNT(*)=2 AND SUM(c.importe_vigente)=80
  FROM public.venta_cuotas c CROSS JOIN _2db_fixture f
  WHERE c.organization_id=f.org AND c.venta_id=(f.result20->>'venta_id')::bigint),
  'two installments persist and match outstanding balance');
SELECT pg_temp.credit_e2e_check(
 (SELECT ia.cantidad=13 FROM public.inventario_almacen ia
 CROSS JOIN _2db_fixture f WHERE ia.organization_id=f.org
 AND ia.producto_id=f.product_id AND ia.almacen_id=f.warehouse_id),
 'two sales consume two items, retry none');

SELECT set_config('request.jwt.claim.sub','',true);
SELECT pg_temp.credit_e2e_check(
 (SELECT public.obtener_cronograma_credito_v1((result0->>'venta_id')::bigint)
   IS NULL FROM _2db_fixture),'no JWT cannot read sale');
SELECT jsonb_build_object('credit_v5_e2e','passed','type','synthetic-real-sale','fixture_reversible',true) AS result;
ROLLBACK;
