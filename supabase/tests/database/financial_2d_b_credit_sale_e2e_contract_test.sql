-- Real RPC v5 with synthetic stock, seller, tenant and two credit purchases.
-- Only local/DEV, BEGIN...ROLLBACK; no production/customer records are read.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(21);
CREATE TEMP TABLE _2db_fixture(
 org uuid,actor uuid,branch uuid,role_id uuid,
 employee_id bigint,customer_id bigint,product_id bigint,warehouse_id bigint,
 request0 uuid,request20 uuid,request_units uuid,sale_at timestamptz,
 result0 jsonb,result20 jsonb,retry20 jsonb,reader20 jsonb, result_units jsonb,reader_units jsonb
) ON COMMIT DROP;
INSERT INTO _2db_fixture(
 org,actor,branch,role_id,employee_id,customer_id,product_id,warehouse_id,
 request0,request20,request_units,sale_at)
VALUES(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
 840130101,840130102,840130103,840130104,
 gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),now()-interval '1 minute');
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
-- Configured presentation: one "caja" consists of 2 "unidad" base units.
INSERT INTO public.product_unit_profiles(product_id,organization_id,revision,profile)
SELECT product_id,org,1, '{
 "schema_version":2,"base_code":"unidad",
 "presentations":[
  {"code":"unidad","singular":"Unidad","plural":"Unidades","factor":1,"fractional":false,"precision":0,"fiscal_unit_code":"NIU"},
  {"code":"caja","singular":"Caja","plural":"Cajas","factor":2,"fractional":false,"precision":0,"fiscal_unit_code":"BX"}
 ]
}'::jsonb FROM _2db_fixture;
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
SELECT ok(
 (SELECT (result0->>'success')::boolean AND NOT (result0->>'idempotent')::boolean
   AND (result0->>'balance')::numeric=100 FROM _2db_fixture),'real v5 persisted a credit sale');
SELECT ok(
 (SELECT count(*)=1 FROM public.venta_cronogramas cr CROSS JOIN _2db_fixture f
 WHERE cr.organization_id=f.org AND cr.venta_id=(f.result0->>'venta_id')::bigint
   AND cr.version=1 AND cr.estado='vigente'),'persisted one versioned schedule');
SELECT ok(
 (SELECT count(*)=1 AND sum(c.importe_vigente)=100
 FROM public.venta_cuotas c CROSS JOIN _2db_fixture f
 WHERE c.organization_id=f.org AND c.venta_id=(f.result0->>'venta_id')::bigint),'persisted one exact installment');
SELECT ok(
 (SELECT count(*)=1 AND sum(cf.saldo_pendiente)=100
 FROM public.venta_cuentas_financieras cf CROSS JOIN _2db_fixture f
 WHERE cf.organization_id=f.org AND cf.venta_id=(f.result0->>'venta_id')::bigint
   AND cf.exigible=100 AND cf.cobros_netos=0),'opening ledger balanced');
SELECT ok(
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
SELECT ok(
 (SELECT (result20->>'success')::boolean
   AND NOT (result20->>'idempotent')::boolean
   AND (result20->>'balance')::numeric=80
   AND (retry20->>'idempotent')::boolean
   AND retry20->>'venta_id'=result20->>'venta_id'
 FROM _2db_fixture),'real bank down-payment and exact request retry');
SELECT ok(
 (SELECT reader20->>'venta_id'=result20->>'venta_id'
   AND (reader20->>'cobros_netos')::numeric=20
   AND (reader20->>'saldo_pendiente')::numeric=80
   AND jsonb_array_length(reader20->'cuotas')=2
 FROM _2db_fixture),'authenticated reader returns current bank-paid schedule');
SELECT ok(
 (SELECT count(*)=1 AND SUM(monto)=20
  FROM public.pagos_venta pv CROSS JOIN _2db_fixture f
  WHERE pv.organization_id=f.org AND pv.venta_id=(f.result20->>'venta_id')::bigint),
  'one initial transfer payment after retry');
SELECT ok(
 (SELECT COUNT(*)=2 AND SUM(c.importe_vigente)=80
  FROM public.venta_cuotas c CROSS JOIN _2db_fixture f
  WHERE c.organization_id=f.org AND c.venta_id=(f.result20->>'venta_id')::bigint),
  'two installments persist and match outstanding balance');
SELECT ok(
 (SELECT ia.cantidad=13 FROM public.inventario_almacen ia
 CROSS JOIN _2db_fixture f WHERE ia.organization_id=f.org
 AND ia.producto_id=f.product_id AND ia.almacen_id=f.warehouse_id),
 'two sales consume two items, retry none');

-- Third real v5 sale: configured "caja" profile routes via process_sale_with_units_v4,
-- normalizes 1 box to 2 base units and retains immutable presentation snapshot.
SET LOCAL ROLE authenticated;
UPDATE _2db_fixture SET result_units=public.process_sale_credit_v5(
 request_units,customer_id,200,sale_at,true,0,
 jsonb_build_array(jsonb_build_object(
   'producto_id',product_id,'almacen_id',warehouse_id,
   'cantidad',1,'piezas_reales',2,
   'precio_unitario',100,'precio_unitario_comercial',200,
   'subtotal',200,'tipo_unidad','caja','unit_profile_revision',1,'stock_scale',1)),
 '[]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,200,NULL,
 jsonb_build_array(
   jsonb_build_object('number',1,'amount',100,
      'due_date',to_char(sale_at+interval '14 day','YYYY-MM-DD')),
   jsonb_build_object('number',2,'amount',100,
      'due_date',to_char(sale_at+interval '28 day','YYYY-MM-DD')))
);
UPDATE _2db_fixture SET reader_units=public.obtener_cronograma_credito_v1(
  (result_units->>'venta_id')::bigint);
RESET ROLE;
SELECT ok(
 (SELECT (result_units->>'success')::boolean
   AND (result_units->>'balance')::numeric=200
   AND (result_units->>'credit_schedule_version')::integer=1
 FROM _2db_fixture),'configured units v5 created a real credit sale');
SELECT ok(
 (SELECT count(*)=1
   AND bool_and(d.presentation_snapshot->>'code'='caja')
   AND bool_and((d.presentation_snapshot->>'factor')::numeric=2)
   AND bool_and((d.presentation_snapshot->>'revision')::integer=1)
 FROM public.detalle_ventas d CROSS JOIN _2db_fixture f
 WHERE d.organization_id=f.org
 AND d.venta_id=(f.result_units->>'venta_id')::bigint),
 'configured presentation snapshot preserves caja with factor 2 and revision 1');
SELECT ok(
 (SELECT ia.cantidad=11 FROM public.inventario_almacen ia
 CROSS JOIN _2db_fixture f WHERE ia.organization_id=f.org
 AND ia.producto_id=f.product_id AND ia.almacen_id=f.warehouse_id),
 'configured one box consumes two base units, exact stock now 11');
SELECT ok(
 (SELECT (reader_units->>'saldo_pendiente')::numeric=200
   AND jsonb_array_length(reader_units->'cuotas')=2
   AND (reader_units->'cuotas'->0->>'importe_vigente')::numeric=100
 FROM _2db_fixture),'configured unit credit schedule reads two exact installments');
SELECT ok(
 (SELECT COUNT(*)=1
 FROM public.venta_cuentas_financieras cf CROSS JOIN _2db_fixture f
 WHERE cf.organization_id=f.org
   AND cf.venta_id=(f.result_units->>'venta_id')::bigint
   AND cf.exigible=200 AND cf.cobros_netos=0 AND cf.saldo_pendiente=200),
 'configured unit account reconciles exact PEN amounts');

-- A subsequent bank payment is allocated FIFO and can be reversed
-- by 2C5A. This is NOT the original down-payment reversal contract.
CREATE TEMP TABLE _2db_transfer_followup(
 request_id uuid NOT NULL, reverse_request_id uuid NOT NULL,
 result_pay jsonb, result_reversal jsonb, original_event_id uuid
) ON COMMIT DROP;
INSERT INTO _2db_transfer_followup
 VALUES(gen_random_uuid(),gen_random_uuid(),NULL,NULL,NULL);
UPDATE _2db_transfer_followup t
SET result_pay=private.financial_2c2_record_transfer_payment(
 (SELECT org FROM _2db_fixture),
 (SELECT (result_units->>'venta_id')::bigint FROM _2db_fixture),
 t.request_id,'PEN',50,now()-interval '10 seconds'
);
UPDATE _2db_transfer_followup t
SET original_event_id=(
 SELECT ev.id FROM public.venta_eventos_financieros ev
 WHERE ev.operacion_id=(t.result_pay->>'operacion_id')::uuid
   AND ev.tipo='cobro' LIMIT 1
);
SELECT ok(
 (SELECT (result_pay->>'success')::boolean
   AND (result_pay->>'saldo')::numeric=150
 FROM _2db_transfer_followup),
 'subsequent canonical transfer reduces credit balance from 200 to 150');
SELECT ok(
 (SELECT SUM(m.importe_asignado)=50
 FROM public.venta_cuota_movimientos m
 CROSS JOIN _2db_fixture f
 WHERE m.venta_id=(f.result_units->>'venta_id')::bigint
 AND m.tipo='cobro'),
 'subsequent transfer allocated exactly 50 to installments');
UPDATE _2db_transfer_followup t
SET result_reversal=private.financial_2c5a_reverse_transfer_payment(
 (SELECT org FROM _2db_fixture),
 (SELECT (result_units->>'venta_id')::bigint FROM _2db_fixture),
 t.reverse_request_id,t.original_event_id,now()
);
SELECT ok(
 (SELECT (result_reversal->>'success')::boolean
   AND (result_reversal->>'saldo')::numeric=200
 FROM _2db_transfer_followup),
 'reversed follow-up transfer restores original credit balance');
SELECT ok(
 (SELECT cf.saldo_pendiente=200 AND cf.cobros_netos=0
 FROM public.venta_cuentas_financieras cf CROSS JOIN _2db_fixture f
 WHERE cf.venta_id=(f.result_units->>'venta_id')::bigint AND cf.organization_id=f.org),
 'financial account exactly reconciles after follow-up reversal');
SELECT ok(
 (SELECT COALESCE(SUM(m.importe_asignado),0)=0
 FROM public.venta_cuota_movimientos m CROSS JOIN _2db_fixture f
 WHERE m.venta_id=(f.result_units->>'venta_id')::bigint),
 'installment allocations net to zero after reversal');

SELECT set_config('request.jwt.claim.sub','',true);
SELECT ok(
 (SELECT public.obtener_cronograma_credito_v1((result0->>'venta_id')::bigint)
   IS NULL FROM _2db_fixture),'no JWT cannot read sale');
SELECT * FROM finish();
ROLLBACK;
