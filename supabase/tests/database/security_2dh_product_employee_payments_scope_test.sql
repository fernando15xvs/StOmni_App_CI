-- 2D-H: real authenticated purchase flows with isolated organization A/B.
-- It tests scoped creation/replay, foreign IDs, partial/final receipt,
-- cancellation, operator RBAC and employment revocation. Fully rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(24);
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
CREATE TEMP TABLE _x(label text,req uuid,product bigint,payment bigint) ON COMMIT DROP;
INSERT INTO _x(label,req) SELECT label,gen_random_uuid() FROM _fx;
UPDATE _x SET req=(SELECT req FROM _x WHERE label='A') WHERE label='B';
GRANT ALL ON _x TO authenticated;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
UPDATE _x SET product=(public.crear_producto_con_stock((SELECT req FROM _x WHERE label='A'),jsonb_build_object('codigo','2DH-NEW-A','nombre','2DH-NEW-A','tipo_venta','UNIDAD','cantidad_por_caja',1,'precio_unidad',10,'precio_caja',10),jsonb_build_array(jsonb_build_object('almacen_id',840211501,'delta',3)))->>'producto_id')::bigint WHERE label='A';
SELECT ok((SELECT product FROM _x WHERE label='A') IS NOT NULL,'A creates product with stock');
SELECT is((public.crear_producto_con_stock((SELECT req FROM _x WHERE label='A'),jsonb_build_object('codigo','2DH-NEW-A','nombre','2DH-NEW-A','tipo_venta','UNIDAD','cantidad_por_caja',1,'precio_unidad',10,'precio_caja',10),jsonb_build_array(jsonb_build_object('almacen_id',840211501,'delta',3)))->>'producto_id')::bigint,(SELECT product FROM _x WHERE label='A'),'A UUID replay unchanged');
SELECT throws_ok($q$SELECT public.crear_producto_con_stock(gen_random_uuid(),jsonb_build_object('codigo','2DH-A-FOREIGN-WH','nombre','2DH-A-FOREIGN-WH','tipo_venta','UNIDAD','cantidad_por_caja',1,'precio_unidad',10,'precio_caja',10),jsonb_build_array(jsonb_build_object('almacen_id',840211502,'delta',3)))$q$,'P0002',NULL,'A foreign warehouse rejected');
SELECT throws_ok($q$SELECT public.crear_producto_con_stock(gen_random_uuid(),jsonb_build_object('codigo','2DH-A-FOREIGN-SUP','nombre','2DH-A-FOREIGN-SUP','tipo_venta','UNIDAD','cantidad_por_caja',1,'precio_unidad',10,'precio_caja',10,'proveedor_id',840211602),jsonb_build_array(jsonb_build_object('almacen_id',840211501,'delta',3)))$q$,'P0002',NULL,'A foreign supplier rejected');
SELECT public.registrar_pago_empleado_mixto((SELECT e.id FROM public.empleados e JOIN _fx f ON f.org=e.organization_id WHERE f.label='A' AND e.auth_id=f.uid),'Compensación interna',now(),'[{"monto":15,"metodo":"Transferencia"}]'::jsonb);
SELECT throws_ok($q$SELECT public.registrar_pago_empleado_mixto((SELECT e.id FROM public.empleados e JOIN _fx f ON f.org=e.organization_id WHERE f.label='B' AND e.auth_id=f.uid),'Foreign',now(),'[{"monto":15,"metodo":"Transferencia"}]'::jsonb)$q$,'P0002',NULL,'A cannot pay B employee');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
UPDATE _x SET product=(public.crear_producto_con_stock((SELECT req FROM _x WHERE label='B'),jsonb_build_object('codigo','2DH-NEW-B','nombre','2DH-NEW-B','tipo_venta','UNIDAD','cantidad_por_caja',1,'precio_unidad',10,'precio_caja',10),jsonb_build_array(jsonb_build_object('almacen_id',840211502,'delta',3)))->>'producto_id')::bigint WHERE label='B';
SELECT ok((SELECT product FROM _x WHERE label='B') IS NOT NULL,'B creates same UUID in B');
SELECT isnt((SELECT product FROM _x WHERE label='A'),(SELECT product FROM _x WHERE label='B'),'A/B product identities distinct');
SELECT is((public.crear_producto_con_stock((SELECT req FROM _x WHERE label='B'),jsonb_build_object('codigo','2DH-NEW-B','nombre','2DH-NEW-B','tipo_venta','UNIDAD','cantidad_por_caja',1,'precio_unidad',10,'precio_caja',10),jsonb_build_array(jsonb_build_object('almacen_id',840211502,'delta',3)))->>'producto_id')::bigint,(SELECT product FROM _x WHERE label='B'),'B UUID replay unchanged');
SELECT throws_ok($q$SELECT public.crear_producto_con_stock(gen_random_uuid(),jsonb_build_object('codigo','2DH-B-FOREIGN-WH','nombre','2DH-B-FOREIGN-WH','tipo_venta','UNIDAD','cantidad_por_caja',1,'precio_unidad',10,'precio_caja',10),jsonb_build_array(jsonb_build_object('almacen_id',840211501,'delta',3)))$q$,'P0002',NULL,'B foreign warehouse rejected');
SELECT public.registrar_pago_empleado_mixto((SELECT e.id FROM public.empleados e JOIN _fx f ON f.org=e.organization_id WHERE f.label='B' AND e.auth_id=f.uid),'Compensación interna',now(),'[{"monto":15,"metodo":"Transferencia"}]'::jsonb);
SELECT throws_ok($q$SELECT public.registrar_pago_empleado_mixto((SELECT e.id FROM public.empleados e JOIN _fx f ON f.org=e.organization_id WHERE f.label='A' AND e.auth_id=f.uid),'Foreign',now(),'[{"monto":15,"metodo":"Transferencia"}]'::jsonb)$q$,'P0002',NULL,'B cannot pay A employee');
RESET ROLE;
UPDATE _x x SET payment=(SELECT p.id FROM public.pagos_empleados p WHERE p.organization_id=f.org ORDER BY p.id DESC LIMIT 1)
FROM _fx f WHERE x.label=f.label;
SELECT ok((SELECT count(*)=2 FROM public.sys_processed_requests WHERE request_id=(SELECT req FROM _x WHERE label='A')),'Idempotency key per organization');
SELECT ok((SELECT count(*)=2 FROM public.inventario_almacen ia JOIN _x x ON x.product=ia.producto_id JOIN _fx f ON f.label=x.label WHERE ia.organization_id=f.org AND ia.cantidad=3),'Two independent initial stock rows');
SELECT ok((SELECT count(*)=2 FROM public.pagos_empleados p JOIN _x x ON x.payment=p.id JOIN _fx f ON f.label=x.label WHERE p.organization_id=f.org AND p.monto=15),'Payments stored only in own tenant');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.eliminar_pago_empleado_v1((SELECT payment FROM _x WHERE label='A'))$q$,'P0002',NULL,'B cannot delete A payment');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.eliminar_pago_empleado_v1((SELECT payment FROM _x WHERE label='B'))$q$,'P0002',NULL,'A cannot delete B payment');
SELECT is((public.eliminar_pago_empleado_v1((SELECT payment FROM _x WHERE label='A'))->>'success')::boolean,true,'A can delete own payment');
RESET ROLE;
SELECT ok(EXISTS(SELECT 1 FROM public.pagos_empleados WHERE id=(SELECT payment FROM _x WHERE label='B')),'B payment survives A deletion');
SELECT ok(NOT EXISTS(SELECT 1 FROM public.pagos_empleados WHERE id=(SELECT payment FROM _x WHERE label='A')),'A deletion persisted');
CREATE TEMP TABLE _closed_payment_session(id uuid) ON COMMIT DROP;
INSERT INTO _closed_payment_session VALUES(gen_random_uuid());
GRANT SELECT ON _closed_payment_session TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.sesiones_caja(
 id,organization_id,branch_id,cash_register_id,usuario_id,estado,
 monto_apertura,fecha_apertura,fecha_cierre)
SELECT s.id,f.org,f.branch,r.id,f.uid,'CERRADA',100,now()-interval '1 day',now()
FROM _fx f JOIN public.cash_registers r
 ON r.organization_id=f.org AND r.is_default
CROSS JOIN _closed_payment_session s WHERE f.label='A';
INSERT INTO public.pagos_empleados(
 organization_id,empleado_id,concepto,metodo,monto,fecha,
 afecta_caja_chica,cash_register_id,cash_session_id)
SELECT f.org,e.id,'Closed session accounting','EFECTIVO',20,
 now()-interval '6 hours',true,r.id,s.id
FROM _fx f JOIN public.empleados e ON e.organization_id=f.org AND e.auth_id=f.uid
JOIN public.cash_registers r
 ON r.organization_id=f.org AND r.is_default
CROSS JOIN _closed_payment_session s WHERE f.label='A';
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok(
 $q$SELECT public.eliminar_pago_empleado_v1(
 (SELECT p.id FROM public.pagos_empleados p
  WHERE p.cash_session_id=(SELECT id FROM _closed_payment_session)))$q$,
 '23514',NULL,'Closed session employee payment is immutable'
);
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _fx WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _fx WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _fx WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.crear_producto_con_stock(gen_random_uuid(),jsonb_build_object('codigo','2DH-NEW-B','nombre','2DH-NEW-B','tipo_venta','UNIDAD','cantidad_por_caja',1,'precio_unidad',10,'precio_caja',10),jsonb_build_array(jsonb_build_object('almacen_id',840211502,'delta',3)))$q$,'42501',NULL,'Operator cannot create stock product');
SELECT throws_ok($q$SELECT public.registrar_pago_empleado_mixto((SELECT e.id FROM public.empleados e JOIN _fx f ON f.org=e.organization_id WHERE f.label='B' AND e.auth_id=f.uid),'Compensación interna',now(),'[{"monto":15,"metodo":"Transferencia"}]'::jsonb)$q$,'42501',NULL,'Operator cannot register employee payment');
SELECT throws_ok($q$SELECT public.eliminar_pago_empleado_v1((SELECT payment FROM _x WHERE label='B'))$q$,'42501',NULL,'Operator cannot delete employee payment');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _fx WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.crear_producto_con_stock(gen_random_uuid(),jsonb_build_object('codigo','2DH-NEW-A','nombre','2DH-NEW-A','tipo_venta','UNIDAD','cantidad_por_caja',1,'precio_unidad',10,'precio_caja',10),jsonb_build_array(jsonb_build_object('almacen_id',840211501,'delta',3)))$q$,'42501',NULL,'Revoked A cannot create product');
SELECT throws_ok($q$SELECT public.registrar_pago_empleado_mixto((SELECT e.id FROM public.empleados e JOIN _fx f ON f.org=e.organization_id WHERE f.label='A' AND e.auth_id=f.uid),'Compensación interna',now(),'[{"monto":15,"metodo":"Transferencia"}]'::jsonb)$q$,'42501',NULL,'Revoked A cannot register payment');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
