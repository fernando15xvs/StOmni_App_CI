-- 2D-H: real authenticated purchase flows with isolated organization A/B.
-- It tests scoped creation/replay, foreign IDs, partial/final receipt,
-- cancellation, operator RBAC and employment revocation. Fully rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(43);
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
SELECT ok((SELECT order_id FROM _fx WHERE label='A') IS NOT NULL,'A creates its own order');
SELECT ok((SELECT line_id FROM _fx WHERE label='A') IS NOT NULL,'A order has line');
SELECT is((public.create_purchase_order_v1((SELECT req FROM _fx WHERE label='A'),840211601,840211501,now(),NULL,'2DH A','[{"product_id":840211401,"base_quantity":2,"unit_cost":5}]')->>'id')::bigint,(SELECT order_id FROM _fx WHERE label='A'),'A own UUID replay idempotent');
SELECT is((SELECT count(*)::int FROM public.list_purchase_orders_v1(NULL,10)),1,'A listing contains own order');
SELECT throws_ok($q$SELECT public.create_purchase_order_v1(gen_random_uuid(),840211602,840211501,now(),NULL,'2DH A','[{"product_id":840211401,"base_quantity":2,"unit_cost":5}]')$q$,'P0002',NULL,'A blocked from B supplier');
SELECT throws_ok($q$SELECT public.create_purchase_order_v1(gen_random_uuid(),840211601,840211502,now(),NULL,'2DH A','[{"product_id":840211401,"base_quantity":2,"unit_cost":5}]')$q$,'P0002',NULL,'A blocked from B warehouse');
SELECT throws_ok($q$SELECT public.create_purchase_order_v1(gen_random_uuid(),840211601,840211501,now(),NULL,'2DH A','[{"product_id":840211402,"base_quantity":2,"unit_cost":5}]')$q$,'P0002',NULL,'A blocked from B product');
SELECT throws_ok($q$SELECT public.create_purchase_order_v1(NULL::uuid,840211601,840211501,now(),NULL,'2DH A','[{"product_id":840211401,"base_quantity":2,"unit_cost":5}]')$q$,'22023',NULL,'Missing purchase UUID denied');
SELECT throws_ok($q$SELECT public.receive_purchase_order_v2(gen_random_uuid(),NULL,now(),NULL,NULL,'[]'::jsonb)$q$,'22023',NULL,'Empty purchase receipt denied');

SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
UPDATE _fx SET req=(SELECT req FROM _fx WHERE label='A') WHERE label='B';
UPDATE _fx SET order_id=(public.create_purchase_order_v1((SELECT req FROM _fx WHERE label='B'),840211602,840211502,now(),NULL,'2DH B','[{"product_id":840211402,"base_quantity":2,"unit_cost":5}]')->>'id')::bigint WHERE label='B';
UPDATE _fx SET line_id=(SELECT (j->>'id')::bigint
FROM public.list_purchase_orders_v1(NULL,10) o CROSS JOIN LATERAL jsonb_array_elements(o->'lines') j LIMIT 1)
WHERE label='B';
SELECT ok((SELECT order_id FROM _fx WHERE label='B') IS NOT NULL,'B creates own order sharing request UUID');
SELECT isnt((SELECT order_id FROM _fx WHERE label='A'),(SELECT order_id FROM _fx WHERE label='B'),'Shared UUID resolves separate tenant orders');
SELECT is((SELECT count(*)::int FROM public.list_purchase_orders_v1(NULL,10)),1,'B sees only its order');
SELECT is((public.create_purchase_order_v1((SELECT req FROM _fx WHERE label='B'),840211602,840211502,now(),NULL,'2DH B','[{"product_id":840211402,"base_quantity":2,"unit_cost":5}]')->>'id')::bigint,(SELECT order_id FROM _fx WHERE label='B'),'B same UUID replay idempotent');
SELECT throws_ok($q$SELECT public.cancel_purchase_order_v1((SELECT order_id FROM _fx WHERE label='A'),'foreign')$q$,'P0002',NULL,'B cannot cancel A order');
SELECT throws_ok($q$SELECT public.receive_purchase_order_v2(gen_random_uuid(),(SELECT order_id FROM _fx WHERE label='A'),now(),'TEST','Purchase receipt',jsonb_build_array(jsonb_build_object('purchase_order_line_id',(SELECT line_id FROM _fx WHERE label='A'),'base_quantity',1,'allocations','[]'::jsonb)))$q$,'P0002',NULL,'B cannot receive A order');
SELECT throws_ok($q$SELECT public.create_purchase_order_v1(gen_random_uuid(),840211601,840211502,now(),NULL,'2DH B','[{"product_id":840211402,"base_quantity":2,"unit_cost":5}]')$q$,'P0002',NULL,'B cannot use A supplier');
SELECT is((public.cancel_purchase_order_v1((SELECT order_id FROM _fx WHERE label='B'),'2DH cancel')->>'status'),'cancelled','B cancels its own order');
SELECT is((public.cancel_purchase_order_v1((SELECT order_id FROM _fx WHERE label='B'),'repeat')->>'status'),'cancelled','B cancellation idempotent');
SELECT throws_ok($q$SELECT public.receive_purchase_order_v2(gen_random_uuid(),(SELECT order_id FROM _fx WHERE label='B'),now(),'TEST','Purchase receipt',jsonb_build_array(jsonb_build_object('purchase_order_line_id',(SELECT line_id FROM _fx WHERE label='B'),'base_quantity',1,'allocations','[]'::jsonb)))$q$,'23514',NULL,'B cancelled order cannot receive');

SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT is((SELECT count(*)::int FROM public.list_purchase_orders_v1('ordered',10)),1,'A order remains active after B cancellation');
SELECT is((public.receive_purchase_order_v2((SELECT receipt_req FROM _fx WHERE label='A'),(SELECT order_id FROM _fx WHERE label='A'),now(),'TEST','Purchase receipt',jsonb_build_array(jsonb_build_object('purchase_order_line_id',(SELECT line_id FROM _fx WHERE label='A'),'base_quantity',1,'allocations','[]'::jsonb)))->>'status'),'partially_received','A receives partial order');
SELECT is((public.receive_purchase_order_v2((SELECT receipt_req FROM _fx WHERE label='A'),(SELECT order_id FROM _fx WHERE label='A'),now(),'TEST','Purchase receipt',jsonb_build_array(jsonb_build_object('purchase_order_line_id',(SELECT line_id FROM _fx WHERE label='A'),'base_quantity',1,'allocations','[]'::jsonb)))->'lines'->0->>'received_base_quantity')::numeric,1::numeric,'A receipt replay does not double stock');
SELECT throws_ok($q$SELECT public.cancel_purchase_order_v1((SELECT order_id FROM _fx WHERE label='A'),'late')$q$,'23514',NULL,'Cannot cancel partially received order');
SELECT throws_ok($q$SELECT public.receive_purchase_order_v2(gen_random_uuid(),(SELECT order_id FROM _fx WHERE label='A'),now(),'TEST','Purchase receipt',jsonb_build_array(jsonb_build_object('purchase_order_line_id',(SELECT line_id FROM _fx WHERE label='A'),'base_quantity',2,'allocations','[]'::jsonb)))$q$,'23514',NULL,'Cannot receive more than pending quantity');
SELECT is((public.receive_purchase_order_v2(gen_random_uuid(),(SELECT order_id FROM _fx WHERE label='A'),now(),'TEST','Purchase receipt',jsonb_build_array(jsonb_build_object('purchase_order_line_id',(SELECT line_id FROM _fx WHERE label='A'),'base_quantity',1,'allocations','[]'::jsonb)))->>'status'),'received','Final A receipt completes order');
SELECT is((SELECT count(*)::int FROM public.list_purchase_orders_v1('received',10)),1,'A sees completed own order');
SELECT throws_ok($q$SELECT public.receive_purchase_order_v2(gen_random_uuid(),(SELECT order_id FROM _fx WHERE label='A'),now(),'TEST','Purchase receipt',jsonb_build_array(jsonb_build_object('purchase_order_line_id',(SELECT line_id FROM _fx WHERE label='A'),'base_quantity',1,'allocations','[]'::jsonb)))$q$,'23514',NULL,'Fully received order cannot receive again');
SELECT throws_ok($q$SELECT public.cancel_purchase_order_v1((SELECT order_id FROM _fx WHERE label='B'),'foreign')$q$,'P0002',NULL,'A cannot cancel B order');
RESET ROLE;
SET LOCAL session_replication_role=replica;
-- An RBAC demotion must remove the admin employee_roles grant as well as
-- the two legacy/base-role fields. Leaving employee_roles admin is NOT
-- equivalent to a real operator in app_tiene_permiso().
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _fx WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _fx WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _fx WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT is(public.get_user_role(),'operador','B is an operator after full RBAC demotion');
SELECT ok(NOT public.app_tiene_permiso('purchases.manage'),'B operator lacks purchases.manage');
SELECT throws_ok($q$SELECT public.create_purchase_order_v1(gen_random_uuid(),840211602,840211502,now(),NULL,'2DH B','[{"product_id":840211402,"base_quantity":2,"unit_cost":5}]')$q$,'42501',NULL,'Operator cannot create purchases');
SELECT throws_ok($q$SELECT public.list_purchase_orders_v1(NULL,10)$q$,'42501',NULL,'Operator cannot list purchases');
SELECT throws_ok($q$SELECT public.cancel_purchase_order_v1((SELECT order_id FROM _fx WHERE label='B'),'operator')$q$,'42501',NULL,'Operator cannot cancel purchases');
SELECT throws_ok($q$SELECT public.receive_purchase_order_v2(gen_random_uuid(),(SELECT order_id FROM _fx WHERE label='B'),now(),'TEST','Purchase receipt',jsonb_build_array(jsonb_build_object('purchase_order_line_id',(SELECT line_id FROM _fx WHERE label='B'),'base_quantity',1,'allocations','[]'::jsonb)))$q$,'42501',NULL,'Operator cannot receive purchases');
RESET ROLE;
SELECT is((SELECT status FROM public.purchase_orders WHERE id=(SELECT order_id FROM _fx WHERE label='A')),'received','A order persisted received');
SELECT is((SELECT status FROM public.purchase_orders WHERE id=(SELECT order_id FROM _fx WHERE label='B')),'cancelled','B order persisted cancelled');
SELECT is((SELECT received_base_quantity FROM public.purchase_order_lines WHERE id=(SELECT line_id FROM _fx WHERE label='A')),2::numeric,'A has exactly two received units');
SELECT is((SELECT received_base_quantity FROM public.purchase_order_lines WHERE id=(SELECT line_id FROM _fx WHERE label='B')),0::numeric,'B has no received units');
SELECT ok((SELECT count(*)=2 FROM public.purchase_orders WHERE request_id=(SELECT req FROM _fx WHERE label='A')),'Shared UUID isolated by organization');
SELECT ok((SELECT count(*)=2 FROM public.purchase_receipt_lines WHERE organization_id=(SELECT org FROM _fx WHERE label='A')),'Receipt replay did not produce duplicate detail lines');
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _fx WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.list_purchase_orders_v1(NULL,10)$q$,'42501',NULL,'Revoked admin cannot read order list');
SELECT throws_ok($q$SELECT public.create_purchase_order_v1(gen_random_uuid(),840211601,840211501,now(),NULL,'2DH A','[{"product_id":840211401,"base_quantity":2,"unit_cost":5}]')$q$,'42501',NULL,'Revoked admin cannot create purchase');
SELECT throws_ok($q$SELECT public.cancel_purchase_order_v1((SELECT order_id FROM _fx WHERE label='A'),'revoked')$q$,'42501',NULL,'Revoked admin cannot cancel');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
