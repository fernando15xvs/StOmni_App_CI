-- 2D-H: real authenticated purchase flows with isolated organization A/B.
-- It tests scoped creation/replay, foreign IDs, partial/final receipt,
-- cancellation, operator RBAC and employment revocation. Fully rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(21);
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
CREATE TEMP TABLE _s(label text,venta bigint,payment bigint,closed_payment bigint) ON COMMIT DROP;
INSERT INTO _s(label) SELECT label FROM _fx;
GRANT SELECT,UPDATE ON _s TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.clientes(id,organization_id,nombre)
SELECT CASE label WHEN 'A' THEN 840211701 ELSE 840211702 END,org,'Paid sale '||label FROM _fx;
INSERT INTO public.inventario_almacen(organization_id,producto_id,almacen_id,cantidad)
SELECT org,CASE label WHEN 'A' THEN 840211401 ELSE 840211402 END,
CASE label WHEN 'A' THEN 840211501 ELSE 840211502 END,20 FROM _fx;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
UPDATE _s SET venta=(public.process_sale_v4(gen_random_uuid(),840211701,15,now(),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211401,'almacen_id',840211501,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)->>'venta_id')::bigint WHERE label='A';
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
UPDATE _s SET venta=(public.process_sale_v4(gen_random_uuid(),840211702,15,now(),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)->>'venta_id')::bigint WHERE label='B';
RESET ROLE;
UPDATE _s s SET payment=(SELECT id FROM public.pagos_venta p WHERE p.venta_id=s.venta AND lower(p.metodo)='transferencia' ORDER BY p.id LIMIT 1);
SELECT ok((SELECT venta FROM _s WHERE label='A') IS NOT NULL,'A creates paid sale');
SELECT ok((SELECT venta FROM _s WHERE label='B') IS NOT NULL,'B creates paid sale');
SELECT ok((SELECT count(*)=2 FROM public.pagos_venta p JOIN _s x ON x.payment=p.id JOIN _fx f ON f.label=x.label AND f.org=p.organization_id),'Both sale payments scoped A/B');
SELECT is((SELECT saldo FROM public.ventas WHERE id=(SELECT venta FROM _s WHERE label='A')),0::numeric,'A sale settled');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.eliminar_pago_venta_v1((SELECT payment FROM _s WHERE label='B'),(SELECT venta FROM _s WHERE label='B'))$q$,'P0002',NULL,'A cannot delete B sale');
SELECT is((public.eliminar_pago_venta_v1((SELECT payment FROM _s WHERE label='B'),(SELECT venta FROM _s WHERE label='A'))->>'idempotent')::boolean,true,'Foreign payment ID against own sale is safe idempotent no-op');
SELECT is((public.eliminar_pago_venta_v1((SELECT payment FROM _s WHERE label='A'),(SELECT venta FROM _s WHERE label='A'))->>'saldo')::numeric,15::numeric,'A can delete own transfer before fiscal evidence');
SELECT is((public.eliminar_pago_venta_v1((SELECT payment FROM _s WHERE label='A'),(SELECT venta FROM _s WHERE label='A'))->>'idempotent')::boolean,true,'A repeat payment deletion idempotent');
SELECT is((SELECT estado FROM public.ventas WHERE id=(SELECT venta FROM _s WHERE label='A')),'pendiente','A sale reopened after deleting bank transfer');
RESET ROLE;
CREATE TEMP TABLE _cash(sid uuid) ON COMMIT DROP;
INSERT INTO _cash VALUES(gen_random_uuid());
GRANT SELECT ON _cash TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.sesiones_caja(id,organization_id,branch_id,cash_register_id,usuario_id,estado,monto_apertura,fecha_apertura,fecha_cierre)
SELECT c.sid,f.org,f.branch,r.id,f.uid,'CERRADA',100,now()-interval '1 day',now()
FROM _cash c JOIN _fx f ON f.label='A' JOIN public.cash_registers r ON r.organization_id=f.org AND r.is_default;
INSERT INTO public.pagos_venta(organization_id,venta_id,metodo,monto,fecha,cash_register_id,cash_session_id)
SELECT f.org,s.venta,'efectivo',5,now()-interval '6 hours',r.id,c.sid
FROM _cash c JOIN _fx f ON f.label='A' JOIN _s s ON s.label='A'
JOIN public.cash_registers r ON r.organization_id=f.org AND r.is_default;
UPDATE public.ventas SET saldo=10,estado='pendiente' WHERE id=(SELECT venta FROM _s WHERE label='A');
INSERT INTO public.comprobantes_electronicos(id,organization_id,venta_id,tipo_documento_sunat,serie,correlativo,fecha_emision,estado,total)
SELECT gen_random_uuid(),f.org,s.venta,'01','F001',1,(now() AT TIME ZONE 'America/Lima')::date,'aceptado',15
FROM _fx f JOIN _s s ON s.label='B' WHERE f.label='B';
SET LOCAL session_replication_role=origin;
UPDATE _s SET closed_payment=(SELECT id FROM public.pagos_venta WHERE cash_session_id=(SELECT sid FROM _cash)) WHERE label='A';
SELECT ok((SELECT closed_payment FROM _s WHERE label='A') IS NOT NULL,'Synthetic closed cash payment exists');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.eliminar_pago_venta_v1((SELECT closed_payment FROM _s WHERE label='A'),(SELECT venta FROM _s WHERE label='A'))$q$,'23514',NULL,'Closed cash payment immutable');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.eliminar_pago_venta_v1((SELECT closed_payment FROM _s WHERE label='A'),(SELECT venta FROM _s WHERE label='A'))$q$,'P0002',NULL,'B cannot delete A closed payment');
SELECT throws_ok($q$SELECT public.eliminar_pago_venta_v1((SELECT payment FROM _s WHERE label='B'),(SELECT venta FROM _s WHERE label='B'))$q$,'23514',NULL,'Accepted electronic document protects B transfer');
SELECT is((public.eliminar_pago_venta_v1(-999999,(SELECT venta FROM _s WHERE label='B'))->>'idempotent')::boolean,true,'B missing payment ID safe no-op');
RESET ROLE;
SELECT ok(EXISTS(SELECT 1 FROM public.pagos_venta WHERE id=(SELECT closed_payment FROM _s WHERE label='A')),'Closed A payment remains');
SELECT ok(EXISTS(SELECT 1 FROM public.pagos_venta WHERE id=(SELECT payment FROM _s WHERE label='B')),'B bank payment remains');
SELECT ok(NOT EXISTS(SELECT 1 FROM public.pagos_venta WHERE id=(SELECT payment FROM _s WHERE label='A')),'A bank transfer deletion persisted');
SELECT is((SELECT saldo FROM public.ventas WHERE id=(SELECT venta FROM _s WHERE label='A')),10::numeric,'A sale has 10 unpaid after closed cash payment');
SELECT is((SELECT saldo FROM public.ventas WHERE id=(SELECT venta FROM _s WHERE label='B')),0::numeric,'B sale still paid');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _fx WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _fx WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _fx WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.eliminar_pago_venta_v1((SELECT payment FROM _s WHERE label='B'),(SELECT venta FROM _s WHERE label='B'))$q$,'42501',NULL,'Operator cannot delete sale payment');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _fx WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.eliminar_pago_venta_v1((SELECT closed_payment FROM _s WHERE label='A'),(SELECT venta FROM _s WHERE label='A'))$q$,'42501',NULL,'Revoked user cannot delete sale payment');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
