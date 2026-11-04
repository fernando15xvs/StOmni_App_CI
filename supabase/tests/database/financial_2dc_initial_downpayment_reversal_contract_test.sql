-- Real RPC v5 with synthetic stock, seller, tenant and two credit purchases.
-- Only local/DEV, BEGIN...ROLLBACK; no production/customer records are read.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(20);
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


-- Actual sale with bank down payment, using authenticated production writer.
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM _2db_fixture),true);
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
  jsonb_build_object('number',1,'amount',40,'due_date',to_char(sale_at+interval '14 day','YYYY-MM-DD')),
  jsonb_build_object('number',2,'amount',40,'due_date',to_char(sale_at+interval '28 day','YYYY-MM-DD')))
);
RESET ROLE;
CREATE TEMP TABLE _2dc_results(
 request_id uuid NOT NULL, original_event_id uuid,
 reversed jsonb, retry jsonb, paid jsonb, payment_event_id uuid,
 payment_reversed jsonb
) ON COMMIT DROP;
INSERT INTO _2dc_results(request_id) VALUES(gen_random_uuid());
UPDATE _2dc_results r SET original_event_id=(
 SELECT ev.id FROM public.venta_eventos_financieros ev
 JOIN public.venta_operaciones_financieras op ON op.id=ev.operacion_id
 CROSS JOIN _2db_fixture f
 WHERE ev.organization_id=f.org AND ev.venta_id=(f.result20->>'venta_id')::bigint
 AND op.tipo='apertura' AND ev.tipo='cobro' LIMIT 1
);
SELECT ok(
  NOT has_function_privilege('authenticated',
   'private.financial_2dc_reverse_initial_transfer(uuid,bigint,uuid,uuid,timestamptz,text)',
   'EXECUTE'),
 'initial reversal remains private, no client grant');
SELECT ok(
 (SELECT (result20->>'success')::boolean
     AND (result20->>'balance')::numeric=80 FROM _2db_fixture),
 'original v5 sale and bank down payment are real');

-- Negative probes are contained in subtransactions; the surrounding
-- fixture is preserved and will still be rolled back in full.
CREATE FUNCTION pg_temp._2dc_rejected(
 p_org uuid,p_sale bigint,p_req uuid,p_origin uuid,p_at timestamptz,p_ref text
) RETURNS boolean LANGUAGE plpgsql AS $body_2dc$
BEGIN
 PERFORM private.financial_2dc_reverse_initial_transfer(
   p_org,p_sale,p_req,p_origin,p_at,p_ref);
 RETURN false;
EXCEPTION WHEN OTHERS THEN RETURN true;
END $body_2dc$;

SELECT ok(
 pg_temp._2dc_rejected(
  gen_random_uuid(),(SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),
  gen_random_uuid(),(SELECT original_event_id FROM _2dc_results),
  now(),'BANK-REV-TEST-20261104'),
 'reversal rejects cross-tenant organization');
SELECT ok(
 pg_temp._2dc_rejected(
  (SELECT org FROM _2db_fixture),(SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),
  gen_random_uuid(),gen_random_uuid(),now(),'BANK-REV-TEST-20261104'),
 'reversal rejects forged original payment event');
SELECT ok(
 pg_temp._2dc_rejected(
  (SELECT org FROM _2db_fixture),(SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),
  gen_random_uuid(),(SELECT original_event_id FROM _2dc_results),now(),'BAD'),
 'reversal rejects inadequate bank reference');

-- Trusted-backend-only call. Bank reference is illustrative, no bank transfer.
UPDATE _2dc_results r SET reversed=private.financial_2dc_reverse_initial_transfer(
 (SELECT org FROM _2db_fixture),
 (SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),
 r.request_id,r.original_event_id,now(),'BANK-REV-TEST-20261104'
);
SELECT ok(
 (SELECT (reversed->>'success')::boolean
  AND (reversed->>'balance')::numeric=100
  AND (reversed->>'amount')::numeric=20
  AND (reversed->>'schedule_version')::integer=2 FROM _2dc_results),
 'initial transfer reversed with v2 and 100 PEN outstanding');
SELECT ok(
 (SELECT count(*)=1 FROM public.venta_cronogramas s CROSS JOIN _2db_fixture f
 WHERE s.organization_id=f.org AND s.venta_id=(f.result20->>'venta_id')::bigint
   AND s.version=1 AND s.estado='sustituido'),
 'v1 schedule retained as substituted history');
SELECT ok(
 (SELECT count(*)=1 FROM public.venta_cronogramas s CROSS JOIN _2db_fixture f
 WHERE s.organization_id=f.org AND s.venta_id=(f.result20->>'venta_id')::bigint
   AND s.version=2 AND s.estado='vigente'),
 'v2 schedule becomes uniquely current');
SELECT ok(
 (SELECT count(*)=3 AND SUM(c.importe_vigente)=100
 FROM public.venta_cuotas c CROSS JOIN _2dc_results r
 WHERE c.cronograma_id=(r.reversed->>'schedule_id')::uuid),
 'new schedule contains three exact installments 40+40+20');
SELECT ok(
 (SELECT count(*)=2 AND SUM(c.importe_vigente)=80
 FROM public.venta_cuotas c CROSS JOIN _2dc_results r
 WHERE c.cronograma_id=(r.reversed->>'previous_schedule_id')::uuid),
 'old installments remain unchanged and auditable');
SELECT ok(
 (SELECT a.apta_para_motor AND a.saldo_calculado=100
 FROM private.financial_2c_audit_sale(
    (SELECT org FROM _2db_fixture),
    (SELECT (result20->>'venta_id')::bigint FROM _2db_fixture)) a),
 'ledger audit remains reconciled after initial bank reversal');
UPDATE _2dc_results r SET retry=private.financial_2dc_reverse_initial_transfer(
 (SELECT org FROM _2db_fixture),
 (SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),
 r.request_id,r.original_event_id,now(),'BANK-REV-TEST-20261104'
);
SELECT ok(
 (SELECT (retry->>'idempotent')::boolean AND retry->>'reversal_event_id'=reversed->>'reversal_event_id'
  FROM _2dc_results),'request replay returns same compensating event');

-- A later transfer must be usable against certified v2 and its allocation reversed.
UPDATE _2dc_results r SET paid=private.financial_2c2_record_transfer_payment(
 (SELECT org FROM _2db_fixture),
 (SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),
 gen_random_uuid(),'PEN',10,now()-interval '1 second'
);
SELECT ok(
 (SELECT (paid->>'success')::boolean AND (paid->>'saldo')::numeric=90
 FROM _2dc_results),'v2 accepts subsequent transfer and reduces 100 to 90');
UPDATE _2dc_results r SET payment_event_id=(
 SELECT ev.id FROM public.venta_eventos_financieros ev
 WHERE ev.id IS NOT NULL AND ev.operacion_id=(r.paid->>'operacion_id')::uuid
 AND ev.tipo='cobro' LIMIT 1
);
SELECT ok(
 (SELECT COALESCE(SUM(m.importe_asignado),0)=10
 FROM public.venta_cuota_movimientos m CROSS JOIN _2dc_results r
 WHERE m.evento_id=r.payment_event_id),'v2 subsequent transfer allocated 10 to installments');
UPDATE _2dc_results r SET payment_reversed=private.financial_2c5a_reverse_transfer_payment(
 (SELECT org FROM _2db_fixture),
 (SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),
 gen_random_uuid(),r.payment_event_id,now()
);
SELECT ok(
 (SELECT (payment_reversed->>'success')::boolean
  AND (payment_reversed->>'saldo')::numeric=100
 FROM _2dc_results),'v2 subsequent payment reversal restores 100 PEN');
SELECT ok(
 (SELECT COALESCE(SUM(m.importe_asignado),0)=0
 FROM public.venta_cuota_movimientos m CROSS JOIN _2db_fixture f
 WHERE m.venta_id=(f.result20->>'venta_id')::bigint),
 'v2 net quota movements zero after compensating reversal');
SELECT ok(
 (SELECT cf.saldo_pendiente=100 AND cf.cobros_netos=0
 FROM public.venta_cuentas_financieras cf CROSS JOIN _2db_fixture f
 WHERE cf.organization_id=f.org AND cf.venta_id=(f.result20->>'venta_id')::bigint),
 'v2 final account reconciles after second reversal');
SELECT ok(
 pg_temp._2dc_rejected(
  (SELECT org FROM _2db_fixture),(SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),
  (SELECT request_id FROM _2dc_results),(SELECT original_event_id FROM _2dc_results),
  now(),'BANK-REV-DIFFERENT-20261104'),
 'divergent idempotent request bank reference is rejected');
SELECT ok(
 pg_temp._2dc_rejected(
  (SELECT org FROM _2db_fixture),(SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),
  gen_random_uuid(),(SELECT original_event_id FROM _2dc_results),
  now(),'BANK-REV-TEST-20261104'),
 'original down payment cannot be reversed twice under another request');
SELECT set_config('request.jwt.claim.sub','',true);
SELECT ok(
 pg_temp._2dc_rejected(
  (SELECT org FROM _2db_fixture),(SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),
  gen_random_uuid(),(SELECT original_event_id FROM _2dc_results),
  now(),'BANK-REV-TEST-20261104'),
 'no JWT actor cannot execute private initial reversal');
SELECT * FROM finish();
ROLLBACK;
