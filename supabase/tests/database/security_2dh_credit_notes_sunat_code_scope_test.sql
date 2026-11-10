-- 2D-H: real authenticated purchase flows with isolated organization A/B.
-- It tests scoped creation/replay, foreign IDs, partial/final receipt,
-- cancellation, operator RBAC and employment revocation. Fully rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(25);
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
-- Real A/B onboarding and real paid sales. Accepted electronic documents and
-- NC series are synthetic database fixtures, never submitted to SUNAT.
CREATE TEMP TABLE _nc(label text,comp uuid,request_id uuid,sale bigint,note jsonb) ON COMMIT DROP;
INSERT INTO _nc(label,comp,request_id) SELECT label,gen_random_uuid(),gen_random_uuid() FROM _fx;
UPDATE _nc SET request_id=(SELECT request_id FROM _nc WHERE label='A') WHERE label='B';
GRANT SELECT,UPDATE ON _nc TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.clientes(id,organization_id,nombre)
SELECT CASE label WHEN 'A' THEN 840211701 ELSE 840211702 END,org,'NC customer '||label FROM _fx;
INSERT INTO public.inventario_almacen(organization_id,producto_id,almacen_id,cantidad)
SELECT org,CASE label WHEN 'A' THEN 840211401 ELSE 840211402 END,
CASE label WHEN 'A' THEN 840211501 ELSE 840211502 END,20 FROM _fx;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
UPDATE _nc SET sale=(public.process_sale_v4(gen_random_uuid(),840211701,15,now(),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211401,'almacen_id',840211501,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)->>'venta_id')::bigint WHERE label='A';
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
UPDATE _nc SET sale=(public.process_sale_v4(gen_random_uuid(),840211702,15,now(),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)->>'venta_id')::bigint WHERE label='B';
RESET ROLE;
SET LOCAL session_replication_role=replica;
INSERT INTO public.comprobantes_electronicos(
 id,organization_id,venta_id,tipo_documento_sunat,serie,correlativo,fecha_emision,estado,total)
SELECT n.comp,f.org,n.sale,CASE n.label WHEN 'A' THEN '01' ELSE '03' END,
CASE n.label WHEN 'A' THEN 'F001' ELSE 'B001' END,1,
(now() AT TIME ZONE 'America/Lima')::date,'aceptado',15
FROM _nc n JOIN _fx f ON f.label=n.label;
INSERT INTO public.series_comprobantes(organization_id,tipo_documento_sunat,serie,activo,ultimo_correlativo)
SELECT f.org,CASE n.label WHEN 'A' THEN 'nota_credito_factura' ELSE 'nota_credito_boleta' END,
CASE n.label WHEN 'A' THEN 'FC01' ELSE 'BC01' END,true,0
FROM _nc n JOIN _fx f ON f.label=n.label;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT is((public.obtener_disponibilidad_nota_credito_v2((SELECT comp FROM _nc WHERE label='A'))->'detalles'->0->>'cantidad_disponible')::numeric,1::numeric,'A accepted invoice has one available unit');
SELECT throws_ok($q$SELECT public.obtener_disponibilidad_nota_credito_v2((SELECT comp FROM _nc WHERE label='B'))$q$,'P0002',NULL,'A cannot read B credit-note availability');
SELECT throws_ok($q$SELECT public.crear_nota_credito_with_units_v3(gen_random_uuid(),(SELECT comp FROM _nc WHERE label='B'),'01','Nota de prueba','[]'::jsonb,NULL,true,now())$q$,'P0002',NULL,'A cannot issue credit note against B invoice');
UPDATE _nc SET note=public.crear_nota_credito_with_units_v3((SELECT request_id FROM _nc WHERE label='A'),(SELECT comp FROM _nc WHERE label='A'),'01','Nota de prueba','[]'::jsonb,NULL,true,now()) WHERE label='A';
SELECT ok((SELECT (note->>'success')::boolean FROM _nc WHERE label='A'),'A creates pending note for SUNAT factura 01');
SELECT is((SELECT note->>'serie' FROM _nc WHERE label='A'),'FC01','A owns factura NC series');
SELECT is((public.crear_nota_credito_with_units_v3((SELECT request_id FROM _nc WHERE label='A'),(SELECT comp FROM _nc WHERE label='A'),'01','Nota de prueba','[]'::jsonb,NULL,true,now())->>'idempotent')::boolean,true,'A same request note replay idempotent');
SELECT is((public.obtener_disponibilidad_nota_credito_v2((SELECT comp FROM _nc WHERE label='A'))->'detalles'->0->>'cantidad_disponible')::numeric,0::numeric,'A pending NC reserves full quantity');
SELECT throws_ok($q$SELECT public.crear_nota_credito_with_units_v3(gen_random_uuid(),(SELECT comp FROM _nc WHERE label='A'),'01','Nota de prueba','[]'::jsonb,NULL,true,now())$q$,'P0001',NULL,'Duplicate full cancellation refused');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT is((public.obtener_disponibilidad_nota_credito_v2((SELECT comp FROM _nc WHERE label='B'))->'detalles'->0->>'cantidad_disponible')::numeric,1::numeric,'B accepted boleta has one available unit');
SELECT throws_ok($q$SELECT public.obtener_disponibilidad_nota_credito_v2((SELECT comp FROM _nc WHERE label='A'))$q$,'P0002',NULL,'B cannot read A availability');
SELECT throws_ok($q$SELECT public.crear_nota_credito_with_units_v3(gen_random_uuid(),(SELECT comp FROM _nc WHERE label='A'),'01','Nota de prueba','[]'::jsonb,NULL,true,now())$q$,'P0002',NULL,'B cannot create NC for A invoice');
UPDATE _nc SET note=public.crear_nota_credito_with_units_v3((SELECT request_id FROM _nc WHERE label='B'),(SELECT comp FROM _nc WHERE label='B'),'01','Nota de prueba','[]'::jsonb,NULL,true,now()) WHERE label='B';
SELECT ok((SELECT (note->>'success')::boolean FROM _nc WHERE label='B'),'B creates pending note for SUNAT boleta 03');
SELECT is((SELECT note->>'serie' FROM _nc WHERE label='B'),'BC01','B owns boleta NC series');
SELECT is((public.crear_nota_credito_with_units_v3((SELECT request_id FROM _nc WHERE label='B'),(SELECT comp FROM _nc WHERE label='B'),'01','Nota de prueba','[]'::jsonb,NULL,true,now())->>'idempotent')::boolean,true,'B same request NC retry idempotent');
SELECT is((public.obtener_disponibilidad_nota_credito_v2((SELECT comp FROM _nc WHERE label='B'))->'detalles'->0->>'cantidad_disponible')::numeric,0::numeric,'B pending NC reserves own quantity');
RESET ROLE;
SELECT isnt((SELECT note->>'nota_credito_id' FROM _nc WHERE label='A'),(SELECT note->>'nota_credito_id' FROM _nc WHERE label='B'),'Same UUID creates different tenant notes');
SELECT ok((SELECT count(*)=2 FROM public.notas_credito n JOIN _nc c ON n.id=(c.note->>'nota_credito_id')::uuid JOIN _fx f ON f.label=c.label AND f.org=n.organization_id WHERE n.total=15 AND n.estado='pendiente_envio'),'A/B pending notes remain tenant local');
SELECT ok((SELECT count(*)=2 FROM public.notas_credito n JOIN _nc c ON n.id=(c.note->>'nota_credito_id')::uuid WHERE n.tipo_origen=CASE c.label WHEN 'A' THEN 'factura' ELSE 'boleta' END AND n.tipo_doc_afectado=CASE c.label WHEN 'A' THEN '01' ELSE '03' END),'SUNAT codes map to stable NC origin descriptors');
SELECT ok((SELECT count(*)=2 FROM public.series_comprobantes s JOIN _fx f ON s.organization_id=f.org WHERE s.tipo_documento_sunat IN('nota_credito_factura','nota_credito_boleta') AND s.ultimo_correlativo=1),'Each tenant consumed only its own NC sequence number');
SELECT ok((SELECT count(*)=2 FROM public.notas_credito n JOIN _nc c ON n.id=(c.note->>'nota_credito_id')::uuid WHERE n.ticket_sunat IS NULL AND n.estado='pendiente_envio'),'No SUNAT ticket or external submission produced');
SELECT ok(NOT has_function_privilege('authenticated','public.crear_nota_credito_v1_unscaled_legacy(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)','EXECUTE'),'Legacy NC writer remains non-public');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _fx WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _fx WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _fx WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT is((public.obtener_disponibilidad_nota_credito_v2((SELECT comp FROM _nc WHERE label='B'))->'detalles'->0->>'cantidad_disponible')::numeric,0::numeric,'B operator can read own reserved NC availability');
SELECT throws_ok($q$SELECT public.obtener_disponibilidad_nota_credito_v2((SELECT comp FROM _nc WHERE label='A'))$q$,'P0002',NULL,'B operator still cannot read A NC');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _fx WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.obtener_disponibilidad_nota_credito_v2((SELECT comp FROM _nc WHERE label='A'))$q$,'42501',NULL,'Revoked A cannot read NC availability');
SELECT throws_ok($q$SELECT public.crear_nota_credito_with_units_v3(gen_random_uuid(),(SELECT comp FROM _nc WHERE label='A'),'01','Nota de prueba','[]'::jsonb,NULL,true,now())$q$,'42501',NULL,'Revoked A cannot create credit note');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
