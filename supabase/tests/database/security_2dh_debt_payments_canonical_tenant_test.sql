-- 2D-H: real authenticated purchase flows with isolated organization A/B.
-- It tests scoped creation/replay, foreign IDs, partial/final receipt,
-- cancellation, operator RBAC and employment revocation. Fully rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(42);
CREATE TEMP TABLE _fx(label text,uid uuid,org uuid,branch uuid,req uuid,order_id bigint,line_id bigint,receipt_req uuid) ON COMMIT DROP;
INSERT INTO _fx(label,uid,req,receipt_req)
 SELECT label,gen_random_uuid(),gen_random_uuid(),gen_random_uuid() FROM (VALUES('A'),('B')) x(label);
GRANT ALL ON _fx TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO auth.users(id,aud,role,email,email_confirmed_at)
SELECT uid,'authenticated','authenticated','purchase-2dh-'||uid::text||'@example.invalid',now() FROM _fx;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
UPDATE _fx SET org=(public.create_my_organization_v1('Purchases 2DH A','PE','PEN','America/Lima')->>'organization_id')::uuid WHERE label='A';
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
UPDATE _fx SET org=(public.create_my_organization_v1('Purchases 2DH B','PE','PEN','America/Lima')->>'organization_id')::uuid WHERE label='B';
RESET ROLE;
UPDATE _fx a SET branch=b.id FROM public.branches b WHERE b.organization_id=a.org AND b.is_main;
SET LOCAL session_replication_role=replica;
INSERT INTO public.proveedores(id,organization_id,nombre,activo,estado)
SELECT CASE label WHEN 'A' THEN 840211601 ELSE 840211602 END,org,'Supplier '||label,true,'activo' FROM _fx;
INSERT INTO public.almacenes(id,organization_id,branch_id,nombre,activo)
SELECT CASE label WHEN 'A' THEN 840211501 ELSE 840211502 END,org,branch,'Warehouse '||label,true FROM _fx;
INSERT INTO public.productos(id,organization_id,codigo,nombre,precio_unidad,precio_caja,precio_compra,tipo_venta,cantidad_por_caja,permitir_sin_stock,activo,es_servicio,item_type)
SELECT CASE label WHEN 'A' THEN 840211401 ELSE 840211402 END,org,'PUR-'||label,'Product '||label,15,15,5,'UNIDAD',1,false,true,false,'stock_product' FROM _fx;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
UPDATE _fx SET order_id=(public.create_purchase_order_v1((SELECT req FROM _fx WHERE label='A'),840211601,840211501,now(),NULL,'2DH A','[{"product_id":840211401,"base_quantity":2,"unit_cost":5}]')->>'id')::bigint WHERE label='A';
UPDATE _fx SET line_id=(SELECT (j->>'id')::bigint
FROM public.list_purchase_orders_v1(NULL,10) o CROSS JOIN LATERAL jsonb_array_elements(o->'lines') j LIMIT 1)
WHERE label='A';
RESET ROLE;
-- Real organization bootstrap A/B from shared fixture; all rows rollback.
CREATE TEMP TABLE _debt(label text,sale_id bigint,expense_id bigint,bank_req uuid,cash_req uuid,
 expense_req uuid,session_id uuid,pay_at timestamptz,cash_at timestamptz,
 bank_result jsonb,cash_result jsonb,expense_result jsonb) ON COMMIT DROP;
INSERT INTO _debt(label,bank_req,cash_req,expense_req,session_id,pay_at,cash_at)
SELECT label,gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
now()-interval '1 minute',now()-interval '30 seconds' FROM _fx;
UPDATE _debt b SET bank_req=a.bank_req,cash_req=a.cash_req,expense_req=a.expense_req
FROM _debt a WHERE a.label='A' AND b.label='B';
GRANT ALL ON _debt TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.clientes(id,organization_id,nombre)
SELECT CASE label WHEN 'A' THEN 840250701 ELSE 840250702 END,org,'Debt test '||label FROM _fx;
INSERT INTO public.inventario_almacen(organization_id,producto_id,almacen_id,cantidad)
SELECT org,CASE label WHEN 'A' THEN 840211401 ELSE 840211402 END,
CASE label WHEN 'A' THEN 840211501 ELSE 840211502 END,30 FROM _fx;
INSERT INTO public.sesiones_caja(id,organization_id,branch_id,cash_register_id,usuario_id,estado,monto_apertura,fecha_apertura)
SELECT d.session_id,f.org,f.branch,r.id,f.uid,'ABIERTA',CASE f.label WHEN 'A' THEN 100 ELSE 200 END,now()-interval '10 minutes'
FROM _debt d JOIN _fx f ON f.label=d.label
JOIN public.cash_registers r ON r.organization_id=f.org AND r.is_default;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
UPDATE _debt SET sale_id=(public.process_sale_credit_v5(gen_random_uuid(),840250701,15,now()-interval '3 minutes',true,0,jsonb_build_array(jsonb_build_object('producto_id',840211401,'almacen_id',840211501,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL,jsonb_build_array(jsonb_build_object('number',1,'amount',15,'due_date',to_char(now()+interval '14 days','YYYY-MM-DD'))))->>'venta_id')::bigint,
expense_id=public.registrar_gasto_mixto(840211601,'Tienda',100,'Proveedor A',now(),'[]'::jsonb) WHERE label='A';
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
UPDATE _debt SET sale_id=(public.process_sale_credit_v5(gen_random_uuid(),840250702,15,now()-interval '3 minutes',true,0,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL,jsonb_build_array(jsonb_build_object('number',1,'amount',15,'due_date',to_char(now()+interval '14 days','YYYY-MM-DD'))))->>'venta_id')::bigint,
expense_id=public.registrar_gasto_mixto(840211602,'Tienda',100,'Proveedor B',now(),'[]'::jsonb) WHERE label='B';
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT ok((SELECT sale_id FROM _debt WHERE label='A') IS NOT NULL AND (SELECT expense_id FROM _debt WHERE label='A') IS NOT NULL,'A creates canonical sale and expense');
SELECT throws_ok($d$SELECT public.procesar_pago_deuda_v2(gen_random_uuid(),true,(SELECT sale_id FROM _debt WHERE label='B'),5,'transferencia',(SELECT pay_at FROM _debt WHERE label='A'),false)$d$,'P0002',NULL,'A foreign credit sale denied');
SELECT throws_ok($d$SELECT public.procesar_pago_deuda_v2(gen_random_uuid(),false,(SELECT expense_id FROM _debt WHERE label='B'),30,'transferencia',(SELECT pay_at FROM _debt WHERE label='A'),false)$d$,'P0002',NULL,'A foreign supplier debt denied');
SELECT throws_ok($d$SELECT public.procesar_pago_deuda_v2(NULL::uuid,true,(SELECT sale_id FROM _debt WHERE label='A'),5,'transferencia',(SELECT pay_at FROM _debt WHERE label='A'),false)$d$,'22023',NULL,'A debt payment requires UUID');
SELECT throws_ok($d$SELECT public.procesar_pago_deuda_v2(gen_random_uuid(),true,(SELECT sale_id FROM _debt WHERE label='A'),-1,'transferencia',(SELECT pay_at FROM _debt WHERE label='A'),false)$d$,'22023',NULL,'A negative amount denied');
UPDATE _debt SET bank_result=public.procesar_pago_deuda_v2((SELECT bank_req FROM _debt WHERE label='A'),true,(SELECT sale_id FROM _debt WHERE label='A'),5,'transferencia',(SELECT pay_at FROM _debt WHERE label='A'),false) WHERE label='A';
SELECT ok(((SELECT bank_result FROM _debt WHERE label='A')->>'success')::boolean,'A canonical bank payment succeeds');
SELECT is(((SELECT bank_result FROM _debt WHERE label='A')->>'saldo')::numeric,10::numeric,'A after bank owes 10');
SELECT is((public.procesar_pago_deuda_v2((SELECT bank_req FROM _debt WHERE label='A'),true,(SELECT sale_id FROM _debt WHERE label='A'),5,'transferencia',(SELECT pay_at FROM _debt WHERE label='A'),false)->>'idempotent')::boolean,true,'A bank replay idempotent');
SELECT throws_ok($d$SELECT public.procesar_pago_deuda_v2((SELECT bank_req FROM _debt WHERE label='A'),true,(SELECT sale_id FROM _debt WHERE label='A'),6,'transferencia',(SELECT pay_at FROM _debt WHERE label='A'),false)$d$,'23505',NULL,'A changed amount with same bank UUID denied');
SELECT throws_ok($d$SELECT public.procesar_pago_deuda_v2(gen_random_uuid(),true,(SELECT sale_id FROM _debt WHERE label='A'),15,'transferencia',(SELECT pay_at FROM _debt WHERE label='A'),false)$d$,'23514',NULL,'A overpayment refused');
SELECT throws_ok($d$SELECT public.procesar_pago_deuda_v2(gen_random_uuid(),true,(SELECT sale_id FROM _debt WHERE label='A'),1,'tarjeta',(SELECT pay_at FROM _debt WHERE label='A'),false)$d$,'23514',NULL,'A unsupported canonical method denied');
UPDATE _debt SET cash_result=public.procesar_pago_deuda_v2((SELECT cash_req FROM _debt WHERE label='A'),true,(SELECT sale_id FROM _debt WHERE label='A'),5,'efectivo',(SELECT cash_at FROM _debt WHERE label='A'),false) WHERE label='A';
SELECT ok(((SELECT cash_result FROM _debt WHERE label='A')->>'success')::boolean,'A canonical cash payment succeeds');
SELECT is(((SELECT cash_result FROM _debt WHERE label='A')->>'saldo')::numeric,5::numeric,'A after bank and cash owes 5');
SELECT is(((SELECT cash_result FROM _debt WHERE label='A')->>'cash_session_id')::uuid,(SELECT session_id FROM _debt WHERE label='A'),'A cash payment bound to A own session');
SELECT is((public.procesar_pago_deuda_v2((SELECT cash_req FROM _debt WHERE label='A'),true,(SELECT sale_id FROM _debt WHERE label='A'),5,'efectivo',(SELECT cash_at FROM _debt WHERE label='A'),false)->>'idempotent')::boolean,true,'A cash replay idempotent');
SELECT throws_ok($d$SELECT public.procesar_pago_deuda_v2(gen_random_uuid(),true,(SELECT sale_id FROM _debt WHERE label='A'),1,'efectivo',now()-interval '20 minutes',false)$d$,'23514',NULL,'A preopening cash timestamp rejected');
UPDATE _debt SET expense_result=public.procesar_pago_deuda_v2((SELECT expense_req FROM _debt WHERE label='A'),false,(SELECT expense_id FROM _debt WHERE label='A'),30,'transferencia',(SELECT pay_at FROM _debt WHERE label='A'),false) WHERE label='A';
SELECT is(((SELECT expense_result FROM _debt WHERE label='A')->>'saldo')::numeric,70::numeric,'A supplier balance 70');
SELECT is((public.procesar_pago_deuda_v2((SELECT expense_req FROM _debt WHERE label='A'),false,(SELECT expense_id FROM _debt WHERE label='A'),30,'transferencia',(SELECT pay_at FROM _debt WHERE label='A'),false)->>'idempotent')::boolean,true,'A supplier payment replay idempotent');
SELECT throws_ok($d$SELECT public.procesar_pago_deuda_v2((SELECT expense_req FROM _debt WHERE label='A'),false,(SELECT expense_id FROM _debt WHERE label='A'),31,'transferencia',(SELECT pay_at FROM _debt WHERE label='A'),false)$d$,'23505',NULL,'A supplier payment changed UUID payload denied');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT ok((SELECT sale_id FROM _debt WHERE label='B') IS NOT NULL AND (SELECT expense_id FROM _debt WHERE label='B') IS NOT NULL,'B creates own sale and expense');
SELECT throws_ok($d$SELECT public.procesar_pago_deuda_v2(gen_random_uuid(),true,(SELECT sale_id FROM _debt WHERE label='A'),5,'transferencia',(SELECT pay_at FROM _debt WHERE label='B'),false)$d$,'P0002',NULL,'B foreign credit sale denied');
SELECT throws_ok($d$SELECT public.procesar_pago_deuda_v2(gen_random_uuid(),false,(SELECT expense_id FROM _debt WHERE label='A'),30,'transferencia',(SELECT pay_at FROM _debt WHERE label='B'),false)$d$,'P0002',NULL,'B foreign supplier debt denied');
UPDATE _debt SET bank_result=public.procesar_pago_deuda_v2((SELECT bank_req FROM _debt WHERE label='B'),true,(SELECT sale_id FROM _debt WHERE label='B'),5,'transferencia',(SELECT pay_at FROM _debt WHERE label='B'),false) WHERE label='B';
SELECT is(((SELECT bank_result FROM _debt WHERE label='B')->>'saldo')::numeric,10::numeric,'B canonical transfer owes 10');
SELECT isnt((SELECT bank_result FROM _debt WHERE label='B')->>'pago_id',(SELECT bank_result FROM _debt WHERE label='A')->>'pago_id','A and B same UUID different payments');
SELECT is((public.procesar_pago_deuda_v2((SELECT bank_req FROM _debt WHERE label='B'),true,(SELECT sale_id FROM _debt WHERE label='B'),5,'transferencia',(SELECT pay_at FROM _debt WHERE label='B'),false)->>'idempotent')::boolean,true,'B replay own bank payment');
UPDATE _debt SET cash_result=public.procesar_pago_deuda_v2((SELECT cash_req FROM _debt WHERE label='B'),true,(SELECT sale_id FROM _debt WHERE label='B'),5,'efectivo',(SELECT cash_at FROM _debt WHERE label='B'),false) WHERE label='B';
SELECT is(((SELECT cash_result FROM _debt WHERE label='B')->>'saldo')::numeric,5::numeric,'B cash payment owes 5');
SELECT is(((SELECT cash_result FROM _debt WHERE label='B')->>'cash_session_id')::uuid,(SELECT session_id FROM _debt WHERE label='B'),'B cash tied to B own session');
SELECT is((public.procesar_pago_deuda_v2((SELECT cash_req FROM _debt WHERE label='B'),true,(SELECT sale_id FROM _debt WHERE label='B'),5,'efectivo',(SELECT cash_at FROM _debt WHERE label='B'),false)->>'idempotent')::boolean,true,'B replay own cash payment');
UPDATE _debt SET expense_result=public.procesar_pago_deuda_v2((SELECT expense_req FROM _debt WHERE label='B'),false,(SELECT expense_id FROM _debt WHERE label='B'),30,'transferencia',(SELECT pay_at FROM _debt WHERE label='B'),false) WHERE label='B';
SELECT is(((SELECT expense_result FROM _debt WHERE label='B')->>'saldo')::numeric,70::numeric,'B supplier payment owes 70');
SELECT is((public.procesar_pago_deuda_v2((SELECT expense_req FROM _debt WHERE label='B'),false,(SELECT expense_id FROM _debt WHERE label='B'),30,'transferencia',(SELECT pay_at FROM _debt WHERE label='B'),false)->>'idempotent')::boolean,true,'B replay own supplier payment');
RESET ROLE;
SELECT ok((SELECT count(*)=2 FROM public.pagos_deuda_requests r JOIN _debt d ON r.request_id=d.bank_req JOIN _fx f ON f.org=r.organization_id AND f.label=d.label WHERE r.es_cliente),'Shared bank request UUID partitioned by organization');
SELECT ok((SELECT count(*)=2 FROM public.pagos_deuda_requests r JOIN _debt d ON r.request_id=d.cash_req JOIN _fx f ON f.org=r.organization_id AND f.label=d.label WHERE r.es_cliente),'Shared cash UUID partitioned by organization');
SELECT ok((SELECT count(*)=2 FROM public.pagos_deuda_requests r JOIN _debt d ON r.request_id=d.expense_req JOIN _fx f ON f.org=r.organization_id AND f.label=d.label WHERE NOT r.es_cliente),'Shared supplier UUID partitioned by organization');
SELECT ok((SELECT count(*)=4 FROM public.venta_operaciones_financieras op JOIN _debt d ON op.venta_id=d.sale_id JOIN _fx f ON f.org=op.organization_id AND f.label=d.label WHERE op.tipo='cobro' AND op.resultado='aplicado'),'Four canonical audited sale payments');
SELECT ok((SELECT count(*)=4 FROM public.venta_cuota_movimientos m JOIN _debt d ON m.venta_id=d.sale_id JOIN _fx f ON f.org=m.organization_id AND f.label=d.label WHERE m.tipo='cobro' AND m.importe_asignado=5),'Four installments allocations own organization');
SELECT ok((SELECT count(*)=2 FROM public.venta_cuentas_financieras cf JOIN _debt d ON cf.venta_id=d.sale_id JOIN _fx f ON f.org=cf.organization_id AND f.label=d.label WHERE cf.saldo_pendiente=5 AND cf.revision=3),'Both canonical accounts settled at 5 revision 3');
SELECT ok((SELECT count(*)=2 FROM public.gastos g JOIN _debt d ON g.id=d.expense_id JOIN _fx f ON f.org=g.organization_id AND f.label=d.label WHERE g.saldo=70),'Both own supplier balances 70');
SELECT ok((SELECT count(*)=2 FROM public.pagos_venta p JOIN _debt d ON d.session_id=p.cash_session_id JOIN _fx f ON f.org=p.organization_id AND f.label=d.label WHERE p.metodo='efectivo' AND p.monto=5),'Cash payments bound separately to A and B');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _fx WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _fx WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _fx WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT throws_ok($d$SELECT public.procesar_pago_deuda_v2(gen_random_uuid(),true,(SELECT sale_id FROM _debt WHERE label='B'),1,'transferencia',(SELECT pay_at FROM _debt WHERE label='B'),false)$d$,'42501',NULL,'B operator cannot collect customer debt');
SELECT throws_ok($d$SELECT public.procesar_pago_deuda_v2(gen_random_uuid(),false,(SELECT expense_id FROM _debt WHERE label='B'),1,'transferencia',(SELECT pay_at FROM _debt WHERE label='B'),false)$d$,'42501',NULL,'B operator cannot pay supplier debt');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _fx WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($d$SELECT public.procesar_pago_deuda_v2(gen_random_uuid(),true,(SELECT sale_id FROM _debt WHERE label='A'),1,'transferencia',(SELECT pay_at FROM _debt WHERE label='A'),false)$d$,'42501',NULL,'Revoked A cannot collect customer debt');
SELECT throws_ok($d$SELECT public.procesar_pago_deuda_v2(gen_random_uuid(),false,(SELECT expense_id FROM _debt WHERE label='A'),1,'transferencia',(SELECT pay_at FROM _debt WHERE label='A'),false)$d$,'42501',NULL,'Revoked A cannot pay supplier debt');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
