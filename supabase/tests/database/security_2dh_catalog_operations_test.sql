-- 2D-H: exercise API grants and definer bodies as real authenticated callers.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions, pg_catalog;
SELECT plan(71);

CREATE TEMP TABLE actors ON COMMIT DROP AS
SELECT label, base_role, employee_id, product_id, gen_random_uuid() AS org,
       gen_random_uuid() AS actor, gen_random_uuid() AS branch, gen_random_uuid() AS role_id
FROM (VALUES
  ('A','admin',-840180101::bigint,840180401::bigint),
  ('B','operador',-840180102::bigint,840180402::bigint)
) AS fixture(label, base_role, employee_id, product_id);
GRANT SELECT ON actors TO authenticated;

-- Bypass provisioning triggers only while building the two isolated fixtures.
SET LOCAL session_replication_role = replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org,'2DH tenant ' || label,'PE','PEN','America/Lima' FROM actors;
INSERT INTO auth.users(id,aud,role)
SELECT actor,'authenticated','authenticated' FROM actors;
INSERT INTO public.app_users(user_id,organization_id,status,base_role)
SELECT actor,org,'active',base_role FROM actors;
INSERT INTO public.branches(id,organization_id,code,name,is_main,status)
SELECT branch,org,'MAIN','Fixture branch',true,'active' FROM actors;
INSERT INTO public.empleados(id,organization_id,branch_id,auth_id,app_user_id,nombre,rol,activo,employment_status)
SELECT employee_id,org,branch,actor,actor,'Fixture employee',base_role,true,'active' FROM actors;
INSERT INTO public.roles(id,organization_id,code,name,is_system,status)
SELECT role_id,org,CASE label WHEN 'A' THEN 'admin' ELSE 'operator' END,'Fixture role',true,'active' FROM actors;
INSERT INTO public.employee_roles(organization_id,employee_id,role_id)
SELECT org,employee_id,role_id FROM actors;
INSERT INTO public.productos(id,organization_id,nombre,precio_unidad,precio_caja,tipo_venta,
                             permitir_sin_stock,activo,es_servicio,item_type)
SELECT product_id,org,'Fixture product',10,10,'UNIDAD',false,true,false,'stock_product' FROM actors;

INSERT INTO public.productos(id,organization_id,nombre,precio_unidad,precio_caja,tipo_venta,permitir_sin_stock,activo,es_servicio,item_type)
SELECT product_id+o.delta,org,'Fixture extra ' || o.delta,10,10,'UNIDAD',false,true,false,o.kind
FROM actors CROSS JOIN (VALUES (10,'stock_product'),(20,'bundle'),(30,'stock_product')) o(delta,kind);
INSERT INTO public.business_capabilities(business_id,organization_id,variants,services)
SELECT product_id,org,true,true FROM actors;
INSERT INTO public.product_variant_groups(id,organization_id,name,attribute_names,created_by)
SELECT product_id,org,'Fixture variants','["color"]',actor FROM actors;
INSERT INTO public.product_variant_members(group_id,product_id,organization_id,attributes)
SELECT product_id,product_id,org,'{"color":"red"}'::jsonb FROM actors
UNION ALL SELECT product_id,product_id+10,org,'{"color":"blue"}'::jsonb FROM actors;
INSERT INTO public.sale_price_rules(id,organization_id,name,product_id,fixed_price)
SELECT product_id,org,'Fixture price',product_id,8 FROM actors;
INSERT INTO public.bundle_components(organization_id,bundle_product_id,component_product_id,quantity)
SELECT org,product_id+20,product_id,1 FROM actors;
INSERT INTO public.almacenes(id,organization_id,branch_id,nombre)
SELECT product_id,org,branch,'2DH fixture warehouse' FROM actors;
SET LOCAL session_replication_role = origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.get_bundle_components_v1(840180422)$q$,'P0002',NULL,'A cannot read B bundle');
SELECT throws_ok($q$SELECT public.set_bundle_components_v1(840180422,'[{"product_id":840180401,"quantity":2}]')$q$,'P0002',NULL,'A cannot replace B bundle');
SELECT throws_ok($q$SELECT public.set_bundle_components_v1(840180421,'[{"product_id":840180401,"quantity":2},{"product_id":840180402,"quantity":3}]')$q$,'P0002',NULL,'Mixed bundle rejects foreign component atomically');
SELECT ok(public.get_bundle_components_v1(840180421) @> '[{"product_id":840180401,"quantity":1}]'::jsonb,'Failed mixed bundle retains original component');
SELECT throws_ok($q$SELECT public.set_catalog_item_type_v1(840180402,'service')$q$,'P0002',NULL,'A cannot convert B product');
SELECT throws_ok($q$SELECT public.save_product_variant_group_v1(840180402,'Updated','["color"]','[{"product_id":840180401,"attributes":{"color":"red"}},{"product_id":840180411,"attributes":{"color":"blue"}}]')$q$,'P0002',NULL,'A cannot update B variant group');
SELECT throws_ok($q$SELECT public.save_product_variant_group_v1(840180401,'Updated','["color"]','[{"product_id":840180401,"attributes":{"color":"red"}},{"product_id":840180402,"attributes":{"color":"blue"}}]')$q$,'42501',NULL,'A cannot add B variant member');
SELECT throws_ok($q$SELECT public.delete_product_variant_group_v1(840180402)$q$,'P0002',NULL,'A cannot delete B variants');
SELECT throws_ok($q$SELECT public.save_sale_price_rule_v1(840180402,'Updated',840180401,NULL,1,7,NULL,0,NULL,NULL,true)$q$,'P0002',NULL,'A cannot repoint B price rule');
SELECT throws_ok($q$SELECT public.save_sale_price_rule_v1(840180401,'Updated',840180402,NULL,1,7,NULL,0,NULL,NULL,true)$q$,'P0002',NULL,'A cannot price B product using own rule');
SELECT throws_ok($q$SELECT public.delete_sale_price_rule_v1(840180402)$q$,'P0002',NULL,'A cannot delete B price rule');
SELECT ok((SELECT array_agg((r->>'id')::bigint) FROM public.list_product_variant_groups_v1() r)=ARRAY[840180401]::bigint[],'A variant list contains only own group');
SELECT ok((SELECT array_agg((r->>'id')::bigint) FROM jsonb_array_elements(public.list_sale_price_rules_v1()) r)=ARRAY[840180401]::bigint[],'A price list contains only own rule');
SELECT lives_ok($q$SELECT public.set_bundle_components_v1(840180421,'[{"product_id":840180411,"quantity":2}]')$q$,'A replaces its own bundle components');
SELECT ok(public.get_bundle_components_v1(840180421) @> '[{"product_id":840180411,"quantity":2}]'::jsonb,'Bundle replacement returns local product and quantity');
SELECT lives_ok($q$SELECT public.set_catalog_item_type_v1(840180431,'non_stock_product')$q$,'A converts its unused local product');
SELECT lives_ok($q$SELECT public.save_product_variant_group_v1(840180401,'Updated','["color"]','[{"product_id":840180401,"attributes":{"color":"red"}},{"product_id":840180411,"attributes":{"color":"blue"}}]')$q$,'A updates own variant group');
SELECT lives_ok($q$SELECT public.save_sale_price_rule_v1(840180401,'Updated',840180401,NULL,1,7,NULL,0,NULL,NULL,true)$q$,'A updates own price rule');
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.get_bundle_components_v1(840180421)$q$,'P0002',NULL,'B cannot read A bundle');
SELECT ok(public.get_bundle_components_v1(840180422) @> '[{"product_id":840180402,"quantity":1}]'::jsonb,'B can read its own bundle');
SELECT throws_ok($q$SELECT public.set_bundle_components_v1(840180422,'[{"product_id":840180412,"quantity":2}]')$q$,'42501',NULL,'Operator denied bundle replacement');
SELECT throws_ok($q$SELECT public.set_catalog_item_type_v1(840180432,'service')$q$,'42501',NULL,'Operator denied catalog conversion');
SELECT throws_ok($q$SELECT public.save_product_variant_group_v1(840180402,'Updated','["color"]','[{"product_id":840180402,"attributes":{"color":"red"}},{"product_id":840180412,"attributes":{"color":"blue"}}]')$q$,'42501',NULL,'Operator denied variant update');
SELECT throws_ok($q$SELECT public.delete_product_variant_group_v1(840180402)$q$,'42501',NULL,'Operator denied variant deletion');
SELECT throws_ok($q$SELECT public.list_product_variant_groups_v1()$q$,'42501',NULL,'Operator denied variant listing');
SELECT throws_ok($q$SELECT public.save_sale_price_rule_v1(840180402,'Updated',840180402,NULL,1,7,NULL,0,NULL,NULL,true)$q$,'42501',NULL,'Operator denied price update');
SELECT throws_ok($q$SELECT public.delete_sale_price_rule_v1(840180402)$q$,'42501',NULL,'Operator denied price deletion');
SELECT throws_ok($q$SELECT public.list_sale_price_rules_v1()$q$,'42501',NULL,'Operator denied price listing');
RESET ROLE;
SELECT ok((SELECT name='Fixture variants' FROM public.product_variant_groups WHERE id=840180402),'B variant group remains intact');
SELECT ok((SELECT count(*)=2 FROM public.product_variant_members WHERE group_id=840180402),'B variant members remain intact');
SELECT ok((SELECT fixed_price=8 AND name='Fixture price' FROM public.sale_price_rules WHERE id=840180402),'B price rule remains intact');
SELECT ok((SELECT quantity=1 AND component_product_id=840180402 FROM public.bundle_components WHERE bundle_product_id=840180422),'B bundle remains intact');
SELECT ok((SELECT item_type='stock_product' FROM public.productos WHERE id=840180432),'B catalog type remains intact');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
SELECT lives_ok($q$SELECT public.delete_product_variant_group_v1(840180401)$q$,'A deletes its own variant group');
SELECT lives_ok($q$SELECT public.delete_sale_price_rule_v1(840180401)$q$,'A deletes its own price rule');
RESET ROLE;
SELECT ok(NOT EXISTS(SELECT 1 FROM public.product_variant_groups WHERE id=840180401) AND NOT EXISTS(SELECT 1 FROM public.product_variant_members WHERE group_id=840180401),'Own variant deletion removes group and members');
SELECT ok(NOT EXISTS(SELECT 1 FROM public.sale_price_rules WHERE id=840180401) AND EXISTS(SELECT 1 FROM public.sale_price_rules WHERE id=840180402),'Own price deletion preserves foreign rule');
SELECT ok(NOT has_function_privilege('authenticated','public._delete_product_variant_group_v1_internal(bigint)','EXECUTE') AND NOT has_function_privilege('anon','public._delete_product_variant_group_v1_internal(bigint)','EXECUTE'),'Client roles cannot bypass wrappers through _delete_product_variant_group_v1_internal');
SELECT ok(NOT has_function_privilege('authenticated','public._legacy_delete_product_variant_group_v1(bigint)','EXECUTE') AND NOT has_function_privilege('anon','public._legacy_delete_product_variant_group_v1(bigint)','EXECUTE'),'Client roles cannot bypass wrappers through _legacy_delete_product_variant_group_v1');
SELECT ok(NOT has_function_privilege('authenticated','public._legacy_delete_sale_price_rule_v1(bigint)','EXECUTE') AND NOT has_function_privilege('anon','public._legacy_delete_sale_price_rule_v1(bigint)','EXECUTE'),'Client roles cannot bypass wrappers through _legacy_delete_sale_price_rule_v1');
SELECT ok(NOT has_function_privilege('authenticated','public._legacy_save_product_variant_group_v1(bigint,text,jsonb,jsonb)','EXECUTE') AND NOT has_function_privilege('anon','public._legacy_save_product_variant_group_v1(bigint,text,jsonb,jsonb)','EXECUTE'),'Client roles cannot bypass wrappers through _legacy_save_product_variant_group_v1');
SELECT ok(NOT has_function_privilege('authenticated','public._legacy_save_sale_price_rule_v1(bigint,text,bigint,text,numeric,numeric,numeric,integer,timestamp with time zone,timestamp with time zone,boolean)','EXECUTE') AND NOT has_function_privilege('anon','public._legacy_save_sale_price_rule_v1(bigint,text,bigint,text,numeric,numeric,numeric,integer,timestamp with time zone,timestamp with time zone,boolean)','EXECUTE'),'Client roles cannot bypass wrappers through _legacy_save_sale_price_rule_v1');
SELECT ok(NOT has_function_privilege('authenticated','public._product_variant_group_json(bigint)','EXECUTE') AND NOT has_function_privilege('anon','public._product_variant_group_json(bigint)','EXECUTE'),'Client roles cannot bypass wrappers through _product_variant_group_json');
SELECT ok(NOT has_function_privilege('authenticated','public._save_product_variant_group_v1_internal(bigint,text,jsonb,jsonb)','EXECUTE') AND NOT has_function_privilege('anon','public._save_product_variant_group_v1_internal(bigint,text,jsonb,jsonb)','EXECUTE'),'Client roles cannot bypass wrappers through _save_product_variant_group_v1_internal');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
SELECT throws_ok($q$SELECT public.get_bundle_components_v1(840180421)$q$,'42501',NULL,'No membership rejected by public.get_bundle_components_v1');
SELECT throws_ok($q$SELECT public.set_bundle_components_v1(840180421,'[{"product_id":840180401,"quantity":1}]')$q$,'42501',NULL,'No membership rejected by public.set_bundle_components_v1');
SELECT throws_ok($q$SELECT public.set_catalog_item_type_v1(840180431,'service')$q$,'42501',NULL,'No membership rejected by public.set_catalog_item_type_v1');
SELECT throws_ok($q$SELECT public.save_product_variant_group_v1(NULL,'No member','["color"]','[]')$q$,'42501',NULL,'No membership rejected by public.save_product_variant_group_v1');
SELECT throws_ok($q$SELECT public.delete_product_variant_group_v1(840180401)$q$,'42501',NULL,'No membership rejected by public.delete_product_variant_group_v1');
SELECT throws_ok($q$SELECT public.list_product_variant_groups_v1()$q$,'42501',NULL,'No membership rejected by public.list_product_variant_groups_v1');
SELECT throws_ok($q$SELECT public.save_sale_price_rule_v1(NULL,'No member',840180401,NULL,1,7,NULL,0,NULL,NULL,true)$q$,'42501',NULL,'No membership rejected by public.save_sale_price_rule_v1');
SELECT throws_ok($q$SELECT public.delete_sale_price_rule_v1(840180401)$q$,'42501',NULL,'No membership rejected by public.delete_sale_price_rule_v1');
SELECT throws_ok($q$SELECT public.list_sale_price_rules_v1()$q$,'42501',NULL,'No membership rejected by public.list_sale_price_rules_v1');
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
SELECT lives_ok($q$SELECT public.save_product_variant_group_v1(NULL,'Created variants','["color"]','[{"product_id":840180401,"attributes":{"color":"red"}},{"product_id":840180411,"attributes":{"color":"blue"}}]')$q$,'A creates a new variant group using local products');
SELECT lives_ok($q$SELECT public.save_sale_price_rule_v1(NULL,'Created price',840180401,NULL,1,6,NULL,0,NULL,NULL,true)$q$,'A creates a new price rule for a local product');
RESET ROLE;
SELECT ok((SELECT count(*)=1 FROM public.product_variant_groups WHERE organization_id=(SELECT org FROM actors WHERE label='A') AND name='Created variants'),'Created variant group belongs to A');
SELECT ok((SELECT count(*)=1 FROM public.sale_price_rules WHERE organization_id=(SELECT org FROM actors WHERE label='A') AND name='Created price' AND product_id=840180401),'Created price rule belongs to A');

-- 2D-H: additional cross-tenant ownership and operator permission preflight.
-- Stock and service helpers must reject the foreign product before any mutation.
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.deactivate_service_v1(840180402)$q$,'P0002',NULL,'Foreign service deactivation blocked');
SELECT throws_ok($q$SELECT public.save_product_unit_profile_v6(840180402,0,'{}')$q$,'P0002',NULL,'Foreign unit profile write blocked');
SELECT throws_ok($q$SELECT public.evaluar_eliminacion_producto_v1(840180402)$q$,'P0002',NULL,'Foreign product deletion preview blocked');
SELECT throws_ok($q$SELECT public.eliminar_producto_seguro_v1(840180402)$q$,'P0002',NULL,'Foreign product deletion blocked');
SELECT throws_ok($q$SELECT public.ajustar_stock_scaled_v2(840180402,840180401,1,'INGRESO','fixture')$q$,'P0002',NULL,'Foreign stock adjustment blocked');
SELECT throws_ok($q$SELECT public.registrar_merma_scaled_v4(gen_random_uuid(),840180402,840180401,1,'fixture')$q$,'P0002',NULL,'Foreign stock waste blocked');
SELECT throws_ok($q$SELECT public.trasladar_stock(840180402,840180401,840180402,1,'fixture','Unidad')$q$,'P0002',NULL,'Legacy stock transfer blocks foreign product');
SELECT throws_ok($q$SELECT public.resolve_sale_price_v1(840180402,'unidad',1,now())$q$,'P0002',NULL,'Foreign sale price resolver blocked');
SELECT throws_ok($q$SELECT public.save_service_v1(840180402,'SV-A','Service','Fixture',10,0)$q$,'P0002',NULL,'Foreign service writer blocked');
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM actors WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.eliminar_producto_seguro_v1(840180402)$q$,'42501',NULL,'Operator denied product deletion');
SELECT throws_ok($q$SELECT public.evaluar_eliminacion_producto_v1(840180402)$q$,'42501',NULL,'Operator denied product deletion preview');
SELECT throws_ok($q$SELECT public.ajustar_stock_scaled_v2(840180402,840180402,1,'INGRESO','operator')$q$,'42501',NULL,'Operator denied stock adjustment');
SELECT throws_ok($q$SELECT public.save_product_unit_profile_v6(840180401,0,'{}')$q$,'P0002',NULL,'Operator cannot write A unit profile');
RESET ROLE;
SELECT ok(
 (SELECT count(*)=2 FROM public.productos WHERE id IN (840180401,840180402) AND activo),
 'Foreign and operator mutations retain both product rows'
);
SELECT * FROM finish();
ROLLBACK;
