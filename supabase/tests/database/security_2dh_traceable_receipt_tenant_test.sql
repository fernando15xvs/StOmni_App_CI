-- 2D-H: real authenticated purchase flows with isolated organization A/B.
-- It tests scoped creation/replay, foreign IDs, partial/final receipt,
-- cancellation, operator RBAC and employment revocation. Fully rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(19);
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
CREATE TEMP TABLE _trace(label text,uuid uuid,result jsonb) ON COMMIT DROP;
INSERT INTO _trace(label,uuid) SELECT label,gen_random_uuid() FROM _fx;
UPDATE _trace SET uuid=(SELECT uuid FROM _trace WHERE label='A') WHERE label='B';
GRANT SELECT,UPDATE ON _trace TO authenticated;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT public.update_business_capabilities_v1((public.get_business_profile_v1()->>'revision')::bigint,'{"lot_tracking":true}'::jsonb);
SELECT public.save_product_traceability_config_v1(840211401,0,'lot',false);
UPDATE _trace SET result=public.register_traceable_merchandise_receipt_v1((SELECT uuid FROM _trace WHERE label='A'),840211401,840211501,2,now(),'Compra','DEV',NULL,'Test lote',5,15,15,15,jsonb_build_array(jsonb_build_object('lot_code','LOT-A','base_quantity',2))) WHERE label='A';
SELECT is((SELECT (result->>'idempotent')::boolean FROM _trace WHERE label='A'),false,'A creates valid lot receipt');
SELECT is((public.register_traceable_merchandise_receipt_v1((SELECT uuid FROM _trace WHERE label='A'),840211401,840211501,2,now(),'Compra','DEV',NULL,'Test lote',5,15,15,15,jsonb_build_array(jsonb_build_object('lot_code','LOT-A','base_quantity',2)))->>'idempotent')::boolean,true,'A repeat receipt idempotent');
SELECT is((public.register_traceable_merchandise_receipt_v1((SELECT uuid FROM _trace WHERE label='A'),840211401,840211501,2,now(),'Compra','DEV',NULL,'Test lote',5,15,15,15,jsonb_build_array(jsonb_build_object('lot_code','LOT-A','base_quantity',2)))->>'inventory_request_id')::uuid,(SELECT (result->>'inventory_request_id')::uuid FROM _trace WHERE label='A'),'A repeat returns identical inventory request');
SELECT throws_ok($q$SELECT public.register_traceable_merchandise_receipt_v1(gen_random_uuid(),840211402,840211502,2,now(),'Compra','DEV',NULL,'Test lote',5,15,15,15,jsonb_build_array(jsonb_build_object('lot_code','LOT-A','base_quantity',2)))$q$,'P0002',NULL,'A cannot receive B product');
SELECT throws_ok($q$SELECT public.register_traceable_merchandise_receipt_v1(gen_random_uuid(),840211401,840211502,2,now(),'Compra','DEV',NULL,'Test lote',5,15,15,15,jsonb_build_array(jsonb_build_object('lot_code','LOT-A','base_quantity',2)))$q$,'P0002',NULL,'A cannot receive in B warehouse');
SELECT throws_ok($q$SELECT public.register_traceable_merchandise_receipt_v1(gen_random_uuid(),840211401,840211501,2,now(),'Compra','DEV',840211602,'Test lote',5,15,15,15,jsonb_build_array(jsonb_build_object('lot_code','LOT-A','base_quantity',2)))$q$,'P0002',NULL,'A cannot receive from B supplier');
SELECT throws_ok($q$SELECT public.register_traceable_merchandise_receipt_v1(gen_random_uuid(),840211401,840211501,2,now(),'Compra','DEV',NULL,'Test',5,15,15,15,'[]'::jsonb)$q$,'22023',NULL,'Empty lot allocations rejected');
SELECT throws_ok($q$SELECT public.registrar_ingreso_mercaderia_scaled_v2(gen_random_uuid(),840211401,now(),'Compra','DEV',NULL,NULL,'[{"almacen_id":840211501,"cantidad_base":1}]'::jsonb,5,15,15,15)$q$,'23514',NULL,'Public general receiver still rejects traceable items');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT public.update_business_capabilities_v1((public.get_business_profile_v1()->>'revision')::bigint,'{"lot_tracking":true}'::jsonb);
SELECT public.save_product_traceability_config_v1(840211402,0,'lot',false);
UPDATE _trace SET result=public.register_traceable_merchandise_receipt_v1((SELECT uuid FROM _trace WHERE label='B'),840211402,840211502,2,now(),'Compra','DEV',NULL,'Test lote',5,15,15,15,jsonb_build_array(jsonb_build_object('lot_code','LOT-B','base_quantity',2))) WHERE label='B';
SELECT is((SELECT (result->>'idempotent')::boolean FROM _trace WHERE label='B'),false,'B creates valid lot receipt with same UUID');
SELECT isnt((SELECT result->>'inventory_request_id' FROM _trace WHERE label='A'),(SELECT result->>'inventory_request_id' FROM _trace WHERE label='B'),'Derived internal inventory UUID isolates A/B');
SELECT is((public.register_traceable_merchandise_receipt_v1((SELECT uuid FROM _trace WHERE label='B'),840211402,840211502,2,now(),'Compra','DEV',NULL,'Test lote',5,15,15,15,jsonb_build_array(jsonb_build_object('lot_code','LOT-B','base_quantity',2)))->>'idempotent')::boolean,true,'B duplicate receipt idempotent');
SELECT throws_ok($q$SELECT public.register_traceable_merchandise_receipt_v1(gen_random_uuid(),840211401,840211501,2,now(),'Compra','DEV',NULL,'Test lote',5,15,15,15,jsonb_build_array(jsonb_build_object('lot_code','LOT-B','base_quantity',2)))$q$,'P0002',NULL,'B cannot receive A product');
RESET ROLE;
SELECT ok((SELECT count(*)=2 FROM public.inventory_traceability_receipts r JOIN _fx f ON f.org=r.organization_id WHERE r.product_id=CASE f.label WHEN 'A' THEN 840211401 ELSE 840211402 END AND r.total_base_quantity=2),'Two tenant-owned traceability receipts');
SELECT ok((SELECT count(*)=2 FROM public.inventory_lots l JOIN _fx f ON f.org=l.organization_id WHERE l.product_id=CASE f.label WHEN 'A' THEN 840211401 ELSE 840211402 END AND l.base_quantity=2),'Two own-tenant lot allocations');
SELECT ok((SELECT count(*)=2 FROM public.inventario_almacen ia JOIN _fx f ON f.org=ia.organization_id WHERE ia.producto_id=CASE f.label WHEN 'A' THEN 840211401 ELSE 840211402 END AND ia.cantidad=2),'Each tenant receives precisely two units');
SELECT ok((SELECT count(*)=2 FROM public.inventario_movimientos m JOIN _fx f ON f.org=m.organization_id WHERE m.producto_id=CASE f.label WHEN 'A' THEN 840211401 ELSE 840211402 END AND m.ingreso_cant=2),'No double stock movements after retry');
SELECT ok(NOT has_function_privilege('authenticated','public._legacy_register_traceable_merchandise_receipt_v1(uuid,bigint,bigint,numeric,timestamptz,text,text,bigint,text,numeric,numeric,numeric,numeric,jsonb)','EXECUTE') AND NOT has_function_privilege('authenticated','public.registrar_ingreso_mercaderia_scaled_v1(uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric)','EXECUTE'),'Legacy helpers remain unreachable to clients');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _fx WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _fx WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _fx WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.register_traceable_merchandise_receipt_v1(gen_random_uuid(),840211402,840211502,2,now(),'Compra','DEV',NULL,'Test lote',5,15,15,15,jsonb_build_array(jsonb_build_object('lot_code','LOT-B','base_quantity',2)))$q$,'42501',NULL,'Operator cannot receive traceable stock');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _fx WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.register_traceable_merchandise_receipt_v1(gen_random_uuid(),840211401,840211501,2,now(),'Compra','DEV',NULL,'Test lote',5,15,15,15,jsonb_build_array(jsonb_build_object('lot_code','LOT-A','base_quantity',2)))$q$,'42501',NULL,'Revoked A cannot receive traceable stock');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
