-- 2D-H: real authenticated purchase flows with isolated organization A/B.
-- It tests scoped creation/replay, foreign IDs, partial/final receipt,
-- cancellation, operator RBAC and employment revocation. Fully rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(64);
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
CREATE TEMP TABLE _requests(label text,waste uuid,transfer uuid,waste_result jsonb,transfer_result jsonb) ON COMMIT DROP;
INSERT INTO _requests(label,waste,transfer) SELECT label,gen_random_uuid(),gen_random_uuid() FROM _fx;
GRANT SELECT,UPDATE ON _requests TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.almacenes(id,organization_id,branch_id,nombre,activo)
SELECT CASE label WHEN 'A' THEN 840245503 ELSE 840245504 END,org,branch,'Warehouse secondary '||label,true FROM _fx;
INSERT INTO public.inventario_almacen(organization_id,producto_id,almacen_id,cantidad)
SELECT org,CASE label WHEN 'A' THEN 840211401 ELSE 840211402 END,
CASE label WHEN 'A' THEN 840211501 ELSE 840211502 END,20 FROM _fx;
INSERT INTO public.productos(id,organization_id,codigo,nombre,precio_unidad,precio_caja,precio_compra,tipo_venta,cantidad_por_caja,permitir_sin_stock,activo,es_servicio,item_type)
SELECT CASE label WHEN 'A' THEN 840245405 ELSE 840245406 END,org,'DELETE-'||label,'Pristine '||label,10,10,2,'UNIDAD',1,false,true,false,'stock_product' FROM _fx
UNION ALL
SELECT CASE label WHEN 'A' THEN 840245407 ELSE 840245408 END,org,'TRACE-'||label,'Traceability '||label,10,10,2,'UNIDAD',1,false,true,false,'stock_product' FROM _fx
UNION ALL
SELECT CASE label WHEN 'A' THEN 840245409 ELSE 840245410 END,org,'UNIT-'||label,'Units '||label,10,10,2,'UNIDAD',1,false,true,false,'stock_product' FROM _fx;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT is((public.evaluar_eliminacion_producto_v1(840245405)->>'puede_eliminar')::boolean,true,'A pristine product evaluable after FK introspection fix');
SELECT throws_ok($q$SELECT public.evaluar_eliminacion_producto_v1(840245406)$q$,'P0002',NULL,'A cannot evaluate foreign product');
SELECT throws_ok($q$SELECT public.eliminar_producto_seguro_v1(840245406)$q$,'P0002',NULL,'A cannot delete foreign product');
SELECT is((public.eliminar_producto_seguro_v1(840245405)->>'success')::boolean,true,'A deletes pristine own product');
SELECT throws_ok($q$SELECT public.eliminar_producto_seguro_v1(840245405)$q$,'P0002',NULL,'A cannot delete missing product twice');
SELECT is((public.actualizar_producto_seguro_v1(840211401,'{"nombre":"Edited A","precio_unidad":22,"stock_minimo":5,"proveedor_id":840211601}'::jsonb,false)->'producto'->>'nombre'),'Edited A','A updates own product and supplier');
SELECT throws_ok($q$SELECT public.actualizar_producto_seguro_v1(840211401,'{"proveedor_id":840211602}'::jsonb,false)$q$,'P0002',NULL,'A cannot update to foreign supplier');
SELECT throws_ok($q$SELECT public.actualizar_producto_seguro_v1(840211401,'{"organization_id":"00000000-0000-0000-0000-000000000000"}'::jsonb,false)$q$,'22023',NULL,'A product organization injection denied');
SELECT is((public.resolve_sale_price_v1(840211401,'unidad',1,now())->>'price')::numeric,22::numeric,'A resolves own updated sale price');
SELECT throws_ok($q$SELECT public.resolve_sale_price_v1(840211402,'unidad',1,now())$q$,'P0002',NULL,'A cannot read foreign sale price');
SELECT is((public.save_product_unit_profile_v6(840245409,0,'{"schema_version":2,"base_code":"unidad","presentations":[{"code":"unidad","singular":"Unidad","plural":"Unidades","factor":1,"fractional":false,"precision":0,"fiscal_unit_code":"NIU"}]}'::jsonb)->>'revision')::bigint,1::bigint,'A creates own unit profile');
SELECT throws_ok($q$SELECT public.save_product_unit_profile_v6(840245410,0,'{"schema_version":2,"base_code":"unidad","presentations":[{"code":"unidad","singular":"Unidad","plural":"Unidades","factor":1,"fractional":false,"precision":0,"fiscal_unit_code":"NIU"}]}'::jsonb)$q$,'P0002',NULL,'A cannot edit foreign unit profile');
SELECT throws_ok($q$SELECT public.save_product_unit_profile_v6(840245409,0,'{"schema_version":2,"base_code":"unidad","presentations":[{"code":"unidad","singular":"Unidad","plural":"Unidades","factor":1,"fractional":false,"precision":0,"fiscal_unit_code":"NIU"}]}'::jsonb)$q$,'40001',NULL,'A unit profile optimistic revision enforced');
SELECT is((public.update_business_capabilities_v1((public.get_business_profile_v1()->>'revision')::bigint,'{"lot_tracking":true}'::jsonb)->'capabilities'->>'lot_tracking')::boolean,true,'A enables own lot feature');
SELECT is((public.save_product_traceability_config_v1(840245407,0,'lot',false)->>'revision')::bigint,1::bigint,'A configures own traceability');
SELECT throws_ok($q$SELECT public.save_product_traceability_config_v1(840245408,0,'lot',false)$q$,'P0002',NULL,'A cannot configure foreign traceability');
SELECT lives_ok($q$SELECT public.ajustar_stock_scaled_v2(840211401,840211501,3,'INGRESO','2DH CATALOG',5,22,22,22)$q$,'A adds own inventory');
SELECT throws_ok($q$SELECT public.ajustar_stock_scaled_v2(840211402,840211502,1,'INGRESO','2DH CATALOG',5,22,22,22)$q$,'P0002',NULL,'A cannot adjust foreign product/warehouse');
UPDATE _requests SET waste_result=public.registrar_merma_scaled_v4((SELECT waste FROM _requests WHERE label='A'),840211401,840211501,2,'2DH waste',now(),NULL) WHERE label='A';
SELECT is((SELECT (waste_result->>'success')::boolean FROM _requests WHERE label='A'),true,'A waste operation succeeds');
SELECT throws_ok($q$SELECT public.registrar_merma_scaled_v4(gen_random_uuid(),840211402,840211501,2,'2DH waste',now(),NULL)$q$,'P0002',NULL,'A cannot waste foreign product');
UPDATE _requests SET transfer_result=public.trasladar_stock_scaled_v4((SELECT transfer FROM _requests WHERE label='A'),840211401,840211501,840245503,2,'2DH relocate',now(),NULL) WHERE label='A';
SELECT is((SELECT (transfer_result->>'success')::boolean FROM _requests WHERE label='A'),true,'A scaled stock transfer succeeds');
SELECT throws_ok($q$SELECT public.trasladar_stock_scaled_v4(gen_random_uuid(),840211401,840211501,840211502,2,'2DH relocate',now(),NULL)$q$,'P0002',NULL,'A cannot transfer stock to foreign warehouse');
SELECT lives_ok($q$SELECT public.trasladar_stock(840211401,840211501,840245503,1,'2DH legacy','Unidad')$q$,'A legacy stock transfer delegates to secured v2');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT is((public.evaluar_eliminacion_producto_v1(840245406)->>'puede_eliminar')::boolean,true,'B pristine product evaluable after FK introspection fix');
SELECT throws_ok($q$SELECT public.evaluar_eliminacion_producto_v1(840245405)$q$,'P0002',NULL,'B cannot evaluate foreign product');
SELECT throws_ok($q$SELECT public.eliminar_producto_seguro_v1(840245405)$q$,'P0002',NULL,'B cannot delete foreign product');
SELECT is((public.eliminar_producto_seguro_v1(840245406)->>'success')::boolean,true,'B deletes pristine own product');
SELECT throws_ok($q$SELECT public.eliminar_producto_seguro_v1(840245406)$q$,'P0002',NULL,'B cannot delete missing product twice');
SELECT is((public.actualizar_producto_seguro_v1(840211402,'{"nombre":"Edited B","precio_unidad":24,"stock_minimo":5,"proveedor_id":840211602}'::jsonb,false)->'producto'->>'nombre'),'Edited B','B updates own product and supplier');
SELECT throws_ok($q$SELECT public.actualizar_producto_seguro_v1(840211402,'{"proveedor_id":840211601}'::jsonb,false)$q$,'P0002',NULL,'B cannot update to foreign supplier');
SELECT throws_ok($q$SELECT public.actualizar_producto_seguro_v1(840211402,'{"organization_id":"00000000-0000-0000-0000-000000000000"}'::jsonb,false)$q$,'22023',NULL,'B product organization injection denied');
SELECT is((public.resolve_sale_price_v1(840211402,'unidad',1,now())->>'price')::numeric,24::numeric,'B resolves own updated sale price');
SELECT throws_ok($q$SELECT public.resolve_sale_price_v1(840211401,'unidad',1,now())$q$,'P0002',NULL,'B cannot read foreign sale price');
SELECT is((public.save_product_unit_profile_v6(840245410,0,'{"schema_version":2,"base_code":"unidad","presentations":[{"code":"unidad","singular":"Unidad","plural":"Unidades","factor":1,"fractional":false,"precision":0,"fiscal_unit_code":"NIU"}]}'::jsonb)->>'revision')::bigint,1::bigint,'B creates own unit profile');
SELECT throws_ok($q$SELECT public.save_product_unit_profile_v6(840245409,0,'{"schema_version":2,"base_code":"unidad","presentations":[{"code":"unidad","singular":"Unidad","plural":"Unidades","factor":1,"fractional":false,"precision":0,"fiscal_unit_code":"NIU"}]}'::jsonb)$q$,'P0002',NULL,'B cannot edit foreign unit profile');
SELECT throws_ok($q$SELECT public.save_product_unit_profile_v6(840245410,0,'{"schema_version":2,"base_code":"unidad","presentations":[{"code":"unidad","singular":"Unidad","plural":"Unidades","factor":1,"fractional":false,"precision":0,"fiscal_unit_code":"NIU"}]}'::jsonb)$q$,'40001',NULL,'B unit profile optimistic revision enforced');
SELECT is((public.update_business_capabilities_v1((public.get_business_profile_v1()->>'revision')::bigint,'{"lot_tracking":true}'::jsonb)->'capabilities'->>'lot_tracking')::boolean,true,'B enables own lot feature');
SELECT is((public.save_product_traceability_config_v1(840245408,0,'lot',false)->>'revision')::bigint,1::bigint,'B configures own traceability');
SELECT throws_ok($q$SELECT public.save_product_traceability_config_v1(840245407,0,'lot',false)$q$,'P0002',NULL,'B cannot configure foreign traceability');
SELECT lives_ok($q$SELECT public.ajustar_stock_scaled_v2(840211402,840211502,4,'INGRESO','2DH CATALOG',5,22,22,22)$q$,'B adds own inventory');
SELECT throws_ok($q$SELECT public.ajustar_stock_scaled_v2(840211401,840211501,1,'INGRESO','2DH CATALOG',5,22,22,22)$q$,'P0002',NULL,'B cannot adjust foreign product/warehouse');
UPDATE _requests SET waste_result=public.registrar_merma_scaled_v4((SELECT waste FROM _requests WHERE label='B'),840211402,840211502,1,'2DH waste',now(),NULL) WHERE label='B';
SELECT is((SELECT (waste_result->>'success')::boolean FROM _requests WHERE label='B'),true,'B waste operation succeeds');
SELECT throws_ok($q$SELECT public.registrar_merma_scaled_v4(gen_random_uuid(),840211401,840211502,1,'2DH waste',now(),NULL)$q$,'P0002',NULL,'B cannot waste foreign product');
UPDATE _requests SET transfer_result=public.trasladar_stock_scaled_v4((SELECT transfer FROM _requests WHERE label='B'),840211402,840211502,840245504,2,'2DH relocate',now(),NULL) WHERE label='B';
SELECT is((SELECT (transfer_result->>'success')::boolean FROM _requests WHERE label='B'),true,'B scaled stock transfer succeeds');
SELECT throws_ok($q$SELECT public.trasladar_stock_scaled_v4(gen_random_uuid(),840211402,840211502,840211501,2,'2DH relocate',now(),NULL)$q$,'P0002',NULL,'B cannot transfer stock to foreign warehouse');
SELECT lives_ok($q$SELECT public.trasladar_stock(840211402,840211502,840245504,1,'2DH legacy','Unidad')$q$,'B legacy stock transfer delegates to secured v2');
RESET ROLE;
SELECT is((SELECT ia.cantidad FROM public.inventario_almacen ia JOIN _fx f ON ia.organization_id=f.org WHERE f.label='A' AND ia.producto_id=840211401 AND ia.almacen_id=840211501),18::integer,'A exact stock after adjustment waste and two transfers');
SELECT is((SELECT ia.cantidad FROM public.inventario_almacen ia JOIN _fx f ON ia.organization_id=f.org WHERE f.label='A' AND ia.producto_id=840211401 AND ia.almacen_id=840245503),3::integer,'A destination warehouse received 3');
SELECT ok(NOT EXISTS(SELECT 1 FROM public.productos WHERE id=840245405),'A deleted product truly gone');
SELECT ok((SELECT count(*)=1 FROM public.product_unit_profiles WHERE organization_id=(SELECT org FROM _fx WHERE label='A') AND product_id=840245409),'A unit profile persisted in own tenant');
SELECT ok((SELECT count(*)=1 FROM public.product_traceability_configs WHERE organization_id=(SELECT org FROM _fx WHERE label='A') AND product_id=840245407),'A traceability persisted in own tenant');
SELECT is((SELECT ia.cantidad FROM public.inventario_almacen ia JOIN _fx f ON ia.organization_id=f.org WHERE f.label='B' AND ia.producto_id=840211402 AND ia.almacen_id=840211502),20::integer,'B exact stock after adjustment waste and two transfers');
SELECT is((SELECT ia.cantidad FROM public.inventario_almacen ia JOIN _fx f ON ia.organization_id=f.org WHERE f.label='B' AND ia.producto_id=840211402 AND ia.almacen_id=840245504),3::integer,'B destination warehouse received 3');
SELECT ok(NOT EXISTS(SELECT 1 FROM public.productos WHERE id=840245406),'B deleted product truly gone');
SELECT ok((SELECT count(*)=1 FROM public.product_unit_profiles WHERE organization_id=(SELECT org FROM _fx WHERE label='B') AND product_id=840245410),'B unit profile persisted in own tenant');
SELECT ok((SELECT count(*)=1 FROM public.product_traceability_configs WHERE organization_id=(SELECT org FROM _fx WHERE label='B') AND product_id=840245408),'B traceability persisted in own tenant');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _fx WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _fx WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _fx WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.evaluar_eliminacion_producto_v1(840211402)$q$,'42501',NULL,'B operator cannot preview product deletion');
SELECT throws_ok($q$SELECT public.eliminar_producto_seguro_v1(840211402)$q$,'42501',NULL,'B operator cannot delete product');
SELECT throws_ok($q$SELECT public.ajustar_stock_scaled_v2(840211402,840211502,1,'INGRESO','2DH CATALOG',5,22,22,22)$q$,'42501',NULL,'B operator cannot adjust stock');
SELECT throws_ok($q$SELECT public.actualizar_producto_seguro_v1(840211402,'{"nombre":"Operator tamper"}'::jsonb,false)$q$,'42501',NULL,'B operator cannot update product');
SELECT is((public.resolve_sale_price_v1(840211402,'unidad',1,now())->>'price')::numeric,24::numeric,'B operator reads only own sale price');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _fx WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.evaluar_eliminacion_producto_v1(840211401)$q$,'42501',NULL,'Revoked A cannot evaluate product');
SELECT throws_ok($q$SELECT public.ajustar_stock_scaled_v2(840211401,840211501,1,'INGRESO','2DH CATALOG',5,22,22,22)$q$,'42501',NULL,'Revoked A cannot adjust stock');
SELECT throws_ok($q$SELECT public.resolve_sale_price_v1(840211401,'unidad',1,now())$q$,'42501',NULL,'Revoked A cannot resolve price');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
