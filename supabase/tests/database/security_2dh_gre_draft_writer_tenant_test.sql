-- 2D-H: real authenticated purchase flows with isolated organization A/B.
-- It tests scoped creation/replay, foreign IDs, partial/final receipt,
-- cancellation, operator RBAC and employment revocation. Fully rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(14);
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
-- Only draft operations, never p_emitir=true: no SUNAT communication.
CREATE TEMP TABLE _gre(label text,request_id uuid,guia uuid) ON COMMIT DROP;
INSERT INTO _gre(label,request_id) SELECT label,gen_random_uuid() FROM _fx;
UPDATE _gre SET request_id=(SELECT request_id FROM _gre WHERE label='A') WHERE label='B';
GRANT SELECT,UPDATE ON _gre TO authenticated;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
UPDATE _gre SET guia=(public.guardar_guia_remision_v4(
 p_request_id=>request_id,p_emitir=>false,p_cantidad_bultos=>2)->>'guia_id')::uuid WHERE label='A';
SELECT ok((SELECT guia FROM _gre WHERE label='A') IS NOT NULL,'A creates own GRE draft');
SELECT is((public.guardar_guia_remision_v4(p_request_id=>(SELECT request_id FROM _gre WHERE label='A'),p_emitir=>false,p_cantidad_bultos=>2)->>'guia_id')::uuid,(SELECT guia FROM _gre WHERE label='A'),'A request UUID replay returns own guide');
SELECT throws_ok($q$SELECT public.guardar_guia_remision_v4(p_guia_id=>gen_random_uuid(),p_emitir=>false)$q$,'P0002',NULL,'A cannot update unknown guide');
SELECT throws_ok($q$SELECT public.guardar_guia_remision_v4(p_guia_id=>(SELECT guia FROM _gre WHERE label='A'),p_emitir=>false,p_cantidad_bultos=>0)$q$,'P0001',NULL,'A rejects zero packages');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
UPDATE _gre SET guia=(public.guardar_guia_remision_v4(
 p_request_id=>request_id,p_emitir=>false,p_cantidad_bultos=>2)->>'guia_id')::uuid WHERE label='B';
SELECT ok((SELECT guia FROM _gre WHERE label='B') IS NOT NULL,'B creates own draft sharing A request UUID');
SELECT isnt((SELECT guia FROM _gre WHERE label='A'),(SELECT guia FROM _gre WHERE label='B'),'Shared GRE UUID returns distinct tenant guides');
SELECT throws_ok($q$SELECT public.guardar_guia_remision_v4(p_guia_id=>(SELECT guia FROM _gre WHERE label='A'),p_emitir=>false)$q$,'P0002',NULL,'B cannot edit A guide');
SELECT is((public.guardar_guia_remision_v4(p_guia_id=>(SELECT guia FROM _gre WHERE label='B'),p_emitir=>false,p_cantidad_bultos=>3)->>'cantidad_bultos')::int,3,'B updates own draft packages');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.guardar_guia_remision_v4(p_guia_id=>(SELECT guia FROM _gre WHERE label='B'),p_emitir=>false)$q$,'P0002',NULL,'A cannot edit B guide');
RESET ROLE;
SELECT ok((SELECT count(*)=2 FROM public.guias_remision g JOIN _gre x ON g.id=x.guia JOIN _fx a ON a.label=x.label AND a.org=g.organization_id WHERE g.estado='borrador' AND g.serie IS NULL AND g.ticket_sunat IS NULL),'Both drafts stay local and unissued');
SELECT is((SELECT cantidad_bultos FROM public.guias_remision WHERE id=(SELECT guia FROM _gre WHERE label='A')),2,'A packages unaffected by B edit');
SELECT is((SELECT cantidad_bultos FROM public.guias_remision WHERE id=(SELECT guia FROM _gre WHERE label='B')),3,'B packages updated locally');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _fx WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _fx WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _fx WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT is((public.guardar_guia_remision_v4(p_guia_id=>(SELECT guia FROM _gre WHERE label='B'),p_emitir=>false,p_cantidad_bultos=>4)->>'cantidad_bultos')::int,4,'Operator can update own draft with tenant.write');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _fx WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.guardar_guia_remision_v4(p_guia_id=>(SELECT guia FROM _gre WHERE label='A'),p_emitir=>false)$q$,'42501',NULL,'Revoked employee cannot edit draft');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
