-- 2D-H custom fields, business capabilities and analytics under two real tenants.
-- The test owns no lasting data: all rows/permissions revert with ROLLBACK.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(38);
CREATE TEMP TABLE _owners(
 label text,uid uuid,org uuid,product bigint,customer bigint,supplier bigint,
 customer_definition uuid,product_definition uuid,supplier_definition uuid
) ON COMMIT DROP;
INSERT INTO _owners(label,uid,product,customer,supplier)
SELECT label,gen_random_uuid(),
CASE label WHEN 'A' THEN 840213401 ELSE 840213402 END,
CASE label WHEN 'A' THEN 840213601 ELSE 840213602 END,
CASE label WHEN 'A' THEN 840213701 ELSE 840213702 END
FROM (VALUES('A'),('B')) x(label);
GRANT ALL ON _owners TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO auth.users(id,aud,role,email,email_confirmed_at)
 SELECT uid,'authenticated','authenticated','custom-2dh-'||uid::text||'@example.invalid',now() FROM _owners;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _owners WHERE label='A'),true);
UPDATE _owners SET org=(public.create_my_organization_v1('Custom tenant A','PE','PEN','America/Lima')->>'organization_id')::uuid WHERE label='A';
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _owners WHERE label='B'),true);
UPDATE _owners SET org=(public.create_my_organization_v1('Custom tenant B','PE','PEN','America/Lima')->>'organization_id')::uuid WHERE label='B';
RESET ROLE;
SET LOCAL session_replication_role=replica;
INSERT INTO public.productos(id,organization_id,nombre,codigo,precio_unidad,precio_caja,tipo_venta,cantidad_por_caja,permitir_sin_stock,activo,es_servicio,item_type)
 SELECT product,org,'Product '||label,'CF-'||label,20,20,'UNIDAD',1,false,true,false,'stock_product' FROM _owners;
INSERT INTO public.clientes(id,organization_id,nombre) SELECT customer,org,'Customer '||label FROM _owners;
INSERT INTO public.proveedores(id,organization_id,nombre,estado,activo) SELECT supplier,org,'Supplier '||label,'activo',true FROM _owners;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _owners WHERE label='A'),true);
UPDATE _owners SET customer_definition=(public.upsert_custom_field_definition_v1(NULL,'customer','region','Region','text',false,ARRAY[]::text[],'[]'::jsonb,'{}'::jsonb,1,'active')->>'id')::uuid WHERE label='A';
UPDATE _owners SET product_definition=(public.upsert_custom_field_definition_v1(NULL,'catalog_item','batch','Batch','text',false,ARRAY[]::text[],'[]'::jsonb,'{}'::jsonb,1,'active')->>'id')::uuid WHERE label='A';
UPDATE _owners SET supplier_definition=(public.upsert_custom_field_definition_v1(NULL,'supplier','rank','Rank','text',false,ARRAY[]::text[],'[]'::jsonb,'{}'::jsonb,1,'active')->>'id')::uuid WHERE label='A';
SELECT is(jsonb_array_length(public.list_custom_field_definitions_v1('customer',true)),1,'A lists one customer definition');
SELECT ok((SELECT customer_definition FROM _owners WHERE label='A') IS NOT NULL,'A owns customer definition');
SELECT ok((SELECT product_definition FROM _owners WHERE label='A') IS NOT NULL,'A owns catalog definition');
SELECT ok((SELECT supplier_definition FROM _owners WHERE label='A') IS NOT NULL,'A owns supplier definition');
SELECT is((public.set_entity_custom_fields_v1('customer',840213601,'{"region":"norte"}')->'custom_fields'->>'region'),'norte','A updates its customer custom field');
SELECT is((public.set_entity_custom_fields_v1('catalog_item',840213401,'{"batch":"A1"}')->'custom_fields'->>'batch'),'A1','A updates its own product custom field');
SELECT is((public.set_entity_custom_fields_v1('supplier',840213701,'{"rank":"gold"}')->'custom_fields'->>'rank'),'gold','A updates supplier custom field');
SELECT throws_ok($q$SELECT public.set_entity_custom_fields_v1('customer',840213602,'{"region":"hacked"}')$q$,'P0002',NULL,'A cannot edit B customer custom fields');
SELECT throws_ok($q$SELECT public.set_entity_custom_fields_v1('catalog_item',840213402,'{"batch":"hacked"}')$q$,'P0002',NULL,'A cannot edit B product custom fields');
SELECT throws_ok($q$SELECT public.set_entity_custom_fields_v1('supplier',840213702,'{"rank":"hacked"}')$q$,'P0002',NULL,'A cannot edit B supplier custom fields');
SELECT throws_ok($q$SELECT public.set_entity_custom_fields_v1('unknown',840213601,'{}')$q$,'22023',NULL,'Unsupported entity type rejected');
SELECT throws_ok($q$SELECT public.upsert_custom_field_definition_v1(NULL,'customer','bad-code!','Bad','text',false,ARRAY[]::text[],'[]'::jsonb,'{}'::jsonb,1,'active')$q$,'22023',NULL,'Invalid definition code rejected');
SELECT is((public.upsert_custom_field_definition_v1((SELECT customer_definition FROM _owners WHERE label='A'),'customer','region','Región actualizada','text',false,ARRAY[]::text[],'[]'::jsonb,'{}'::jsonb,1,'active')->>'label'),'Región actualizada','A updates its own definition');
SELECT is((public.update_business_capabilities_v1((public.get_business_profile_v1()->>'revision')::bigint,'{"services":true}')->'capabilities'->>'services')::boolean,true,'A enables local services capability');
SELECT throws_ok($q$SELECT public.update_business_capabilities_v1(0,'{"services":true}')$q$,'40001',NULL,'A rejects outdated capabilities revision');
SELECT throws_ok($q$SELECT public.update_business_capabilities_v1((public.get_business_profile_v1()->>'revision')::bigint,'{"organization_id":"00000000-0000-0000-0000-000000000000"}')$q$,'22023',NULL,'Capability update cannot inject organization ID');
SELECT is((SELECT count(*)::integer FROM public.save_business_metrics_v1('[{"source":"income","label":"Ingresos A","position":1,"enabled":true,"format":"currency"}]'::jsonb)),1,'A saves one business metric');
SELECT ok((SELECT count(*)=1 FROM public.list_business_metrics_v1() WHERE (list_business_metrics_v1->>'label')='Ingresos A'),'A only sees its configured metric');
SELECT throws_ok($q$SELECT * FROM public.save_business_metrics_v1('[{"source":"income","label":"Uno","position":1,"enabled":true,"format":"currency"},{"source":"income","label":"Dos","position":2,"enabled":true,"format":"currency"}]'::jsonb)$q$,'22023',NULL,'Duplicate business metrics rejected');

SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _owners WHERE label='B'),true);
UPDATE _owners SET customer_definition=(public.upsert_custom_field_definition_v1(NULL,'customer','region','Region B','text',false,ARRAY[]::text[],'[]'::jsonb,'{}'::jsonb,1,'active')->>'id')::uuid WHERE label='B';
SELECT is(jsonb_array_length(public.list_custom_field_definitions_v1('customer',true)),1,'B lists only its customer definition');
SELECT is((public.set_entity_custom_fields_v1('customer',840213602,'{"region":"sur"}')->'custom_fields'->>'region'),'sur','B updates its own customer');
SELECT throws_ok($q$SELECT public.upsert_custom_field_definition_v1((SELECT customer_definition FROM _owners WHERE label='A'),'customer','region','Cross-tenant override','text',false,ARRAY[]::text[],'[]'::jsonb,'{}'::jsonb,1,'active')$q$,'P0002',NULL,'B cannot update A field definition');
SELECT throws_ok($q$SELECT public.set_entity_custom_fields_v1('customer',840213601,'{"region":"sur"}')$q$,'P0002',NULL,'B cannot update A customer');
SELECT ok((public.get_business_profile_v1()->'capabilities'->>'services')::boolean IS FALSE,'B services remain disabled after A update');
SELECT is((SELECT count(*)::integer FROM public.save_business_metrics_v1('[{"source":"income","label":"Ingresos B","position":1,"enabled":true,"format":"currency"}]'::jsonb)),1,'B saves its own business metric');
SELECT ok((SELECT count(*)=1 FROM public.list_business_metrics_v1() WHERE (list_business_metrics_v1->>'label')='Ingresos B'),'B sees only its own metric');
SELECT throws_ok($q$SELECT public.get_business_assistant_context_v1('unknown',30,NULL,5)$q$,'42501',NULL,'Assistant gated while disabled or unavailable');
RESET ROLE;
SELECT is((SELECT custom_fields->>'region' FROM public.clientes WHERE id=840213601),'norte','A custom field preserved after B edit');
SELECT is((SELECT custom_fields->>'region' FROM public.clientes WHERE id=840213602),'sur','B custom field persisted separately');
SELECT is((SELECT label FROM public.custom_field_definitions WHERE id=(SELECT customer_definition FROM _owners WHERE label='A')),'Región actualizada','A definition not changed by B');
SELECT is((SELECT label FROM public.custom_field_definitions WHERE id=(SELECT customer_definition FROM _owners WHERE label='B')),'Region B','B definition remains distinct');
SELECT ok((SELECT count(*)=2 FROM public.business_metric_definitions WHERE source_key='income' AND organization_id IN (SELECT org FROM _owners)),'Business metrics scoped to two tenants');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _owners WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _owners WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _owners WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _owners WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.upsert_custom_field_definition_v1(NULL,'customer','another','Another','text',false,ARRAY[]::text[],'[]'::jsonb,'{}'::jsonb,1,'active')$q$,'42501',NULL,'B operator cannot define fields');
SELECT throws_ok($q$SELECT public.update_business_capabilities_v1((public.get_business_profile_v1()->>'revision')::bigint,'{"services":true}')$q$,'42501',NULL,'B operator cannot update capabilities');
SELECT throws_ok($q$SELECT * FROM public.save_business_metrics_v1('[]'::jsonb)$q$,'42501',NULL,'B operator cannot configure metrics');
SELECT is((public.set_entity_custom_fields_v1('customer',840213602,'{"region":"centro"}')->'custom_fields'->>'region'),'centro','Operator with tenant.write can edit own customer custom field');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _owners WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _owners WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.set_entity_custom_fields_v1('customer',840213601,'{"region":"revoked"}')$q$,'42501',NULL,'Revoked owner cannot change entity fields');
SELECT throws_ok($q$SELECT public.update_business_capabilities_v1(1,'{"services":true}')$q$,'42501',NULL,'Revoked owner cannot update capabilities');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
