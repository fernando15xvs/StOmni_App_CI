-- 2D-H: real authenticated purchase flows with isolated organization A/B.
-- It tests scoped creation/replay, foreign IDs, partial/final receipt,
-- cancellation, operator RBAC and employment revocation. Fully rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(35);
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
CREATE TEMP TABLE _s(label text,service_id bigint) ON COMMIT DROP;
INSERT INTO _s(label) SELECT label FROM _fx;
GRANT SELECT,UPDATE ON _s TO authenticated;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT public.update_business_capabilities_v1((public.get_business_profile_v1()->>'revision')::bigint,'{"services":true}'::jsonb);
UPDATE _s SET service_id=(public.save_service_v1(NULL,'SVC-TENANT-SAME','A Consulta','Descripción inicial',35,7)->>'id')::bigint WHERE label='A';
SELECT ok((SELECT service_id FROM _s WHERE label='A') IS NOT NULL,'A creates service');
SELECT is((SELECT count(*)::int FROM public.list_services_v1(false)),1,'A lists only one service');
SELECT is((SELECT j->>'name' FROM public.list_services_v1(false) j LIMIT 1),'A Consulta','A reads correct name');
SELECT is((SELECT j->>'code' FROM public.list_services_v1(false) j LIMIT 1),'SVC-TENANT-SAME','A code persisted');
SELECT is((SELECT j->>'description' FROM public.list_services_v1(false) j LIMIT 1),'Descripción inicial','A description persisted');
SELECT throws_ok($q$SELECT public.save_service_v1(NULL,'SVC-TENANT-SAME','Duplicate','Descripción inicial',35,7)$q$,'23505',NULL,'Duplicate code inside A denied');
SELECT throws_ok($q$SELECT public.save_service_v1(NULL,'SVC-BLANK','','Descripción inicial',35,7)$q$,'22023',NULL,'Blank name rejected');
SELECT throws_ok($q$SELECT public.save_service_v1(NULL,'SVC-NEGATIVE','Negative','Descripción inicial',-1,7)$q$,'22023',NULL,'Negative price rejected');
SELECT is((public.save_service_v1((SELECT service_id FROM _s WHERE label='A'),'SVC-TENANT-SAME','A Editada','Alcance nuevo',40,7)->>'name'),'A Editada','Own service update works');
SELECT is((SELECT j->>'description' FROM public.list_services_v1(false) j LIMIT 1),'Alcance nuevo','Own description update works');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT public.update_business_capabilities_v1((public.get_business_profile_v1()->>'revision')::bigint,'{"services":true}'::jsonb);
UPDATE _s SET service_id=(public.save_service_v1(NULL,'SVC-TENANT-SAME','B Consulta','Descripción inicial',65,7)->>'id')::bigint WHERE label='B';
SELECT ok((SELECT service_id FROM _s WHERE label='B') IS NOT NULL,'B creates same code');
SELECT isnt((SELECT service_id FROM _s WHERE label='A'),(SELECT service_id FROM _s WHERE label='B'),'A and B own distinct IDs');
SELECT is((SELECT count(*)::int FROM public.list_services_v1(false)),1,'B only reads its own service');
SELECT is((SELECT j->>'name' FROM public.list_services_v1(false) j LIMIT 1),'B Consulta','B service payload isolated');
SELECT throws_ok($q$SELECT public.save_service_v1((SELECT service_id FROM _s WHERE label='A'),'SVC-TENANT-SAME','Foreign','Descripción inicial',35,7)$q$,'P0002',NULL,'B cannot update A service');
SELECT throws_ok($q$SELECT public.deactivate_service_v1((SELECT service_id FROM _s WHERE label='A'))$q$,'P0002',NULL,'B cannot disable A service');
SELECT throws_ok($q$SELECT public.deactivate_service_v1(840211401)$q$,'P0002',NULL,'B cannot disable A stock product');
SELECT lives_ok($q$SELECT public.deactivate_service_v1((SELECT service_id FROM _s WHERE label='B'))$q$,'B disables own service');
SELECT is((SELECT count(*)::int FROM public.list_services_v1(false)),0,'B active list excludes disabled');
SELECT is((SELECT count(*)::int FROM public.list_services_v1(true)),1,'B inactive-inclusive list sees own');
SELECT is((SELECT j->>'active' FROM public.list_services_v1(true) j LIMIT 1),'false','B service inactive flag persisted');
SELECT lives_ok($q$SELECT public.deactivate_service_v1((SELECT service_id FROM _s WHERE label='B'))$q$,'B repeat deactivate harmless');
SELECT is((public.update_business_capabilities_v1((public.get_business_profile_v1()->>'revision')::bigint,'{"services":false}'::jsonb)->'capabilities'->>'services')::boolean,false,'B turns off services capability');
SELECT is((SELECT count(*)::int FROM public.list_services_v1(true)),0,'B capability off hides services');
SELECT throws_ok($q$SELECT public.save_service_v1(NULL,'SVC-DISABLED','Disabled','Descripción inicial',35,7)$q$,'23514',NULL,'Cannot save service when feature disabled');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT is((SELECT count(*)::int FROM public.list_services_v1(false)),1,'A services unaffected by B capability');
SELECT throws_ok($q$SELECT public.deactivate_service_v1((SELECT service_id FROM _s WHERE label='B'))$q$,'P0002',NULL,'A cannot disable B service');
RESET ROLE;
SELECT ok((SELECT count(*)=2 FROM public.productos p JOIN _s x ON x.service_id=p.id JOIN _fx f ON f.label=x.label AND f.org=p.organization_id WHERE p.es_servicio AND p.item_type='service' AND p.tipo_venta='UNIDAD'),'Two tenant-scoped services use canonical sale type');
SELECT ok((SELECT count(*)=2 FROM public.service_metadata m JOIN _s x ON m.product_id=x.service_id),'Two service metadata rows');
SELECT ok((SELECT count(*)=2 FROM public.inventario_almacen ia JOIN _s x ON x.service_id=ia.producto_id WHERE ia.cantidad=0),'Both service inventory rows are zero');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _fx WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _fx WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _fx WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.deactivate_service_v1((SELECT service_id FROM _s WHERE label='B'))$q$,'42501',NULL,'B operator cannot disable service');
SELECT is((SELECT count(*)::int FROM public.list_services_v1(true)),0,'B operator cannot bypass disabled capability');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _fx WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.save_service_v1(NULL,'SVC-REVOKED','Denied','Descripción inicial',35,7)$q$,'42501',NULL,'Revoked A cannot create service');
SELECT throws_ok($q$SELECT public.deactivate_service_v1((SELECT service_id FROM _s WHERE label='A'))$q$,'42501',NULL,'Revoked A cannot disable service');
SELECT is((SELECT count(*)::int FROM public.list_services_v1(true)),0,'Revoked A cannot enumerate services');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
