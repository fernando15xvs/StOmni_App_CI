-- 2D-H: real authenticated purchase flows with isolated organization A/B.
-- It tests scoped creation/replay, foreign IDs, partial/final receipt,
-- cancellation, operator RBAC and employment revocation. Fully rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(28);
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
CREATE TEMP TABLE _saleids(
 label text,cash_req uuid,credit_req uuid,sale_at timestamptz,
 cash_id bigint,credit_id bigint,credit_result jsonb
) ON COMMIT DROP;
INSERT INTO _saleids(label,cash_req,credit_req,sale_at)
SELECT label,gen_random_uuid(),gen_random_uuid(),now()-interval '1 minute' FROM _fx;
GRANT SELECT,UPDATE ON _saleids TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.clientes(id,organization_id,nombre)
SELECT CASE label WHEN 'A' THEN 840211701 ELSE 840211702 END,org,'2DH sale customer '||label FROM _fx;
INSERT INTO public.inventario_almacen(organization_id,producto_id,almacen_id,cantidad)
SELECT org,CASE label WHEN 'A' THEN 840211401 ELSE 840211402 END,
 CASE label WHEN 'A' THEN 840211501 ELSE 840211502 END,20 FROM _fx;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.process_sale_v4((SELECT cash_req FROM _saleids WHERE label='A'),840211702,15,(SELECT sale_at FROM _saleids WHERE label='A'),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211401,'almacen_id',840211501,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)$q$,'P0002',NULL,'Cash sale A rejects customer B');
SELECT throws_ok($q$SELECT public.process_sale_v4((SELECT cash_req FROM _saleids WHERE label='A'),840211701,15,(SELECT sale_at FROM _saleids WHERE label='A'),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)$q$,'P0002',NULL,'Cash sale A rejects product B');
SELECT throws_ok($q$SELECT public.process_sale_with_units_v4(gen_random_uuid(),840211702,15,(SELECT sale_at FROM _saleids WHERE label='A'),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211401,'almacen_id',840211501,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)$q$,'P0002',NULL,'Unit sale A rejects customer B');
SELECT throws_ok($q$SELECT public.process_sale_with_units_v4(gen_random_uuid(),840211701,15,(SELECT sale_at FROM _saleids WHERE label='A'),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)$q$,'P0002',NULL,'Unit sale A rejects product B');
SELECT throws_ok($q$SELECT public.process_sale_credit_v5((SELECT credit_req FROM _saleids WHERE label='A'),840211702,15,(SELECT sale_at FROM _saleids WHERE label='A'),true,0,jsonb_build_array(jsonb_build_object('producto_id',840211401,'almacen_id',840211501,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL,jsonb_build_array(jsonb_build_object('number',1,'amount',15,'due_date',to_char((SELECT sale_at FROM _saleids WHERE label='A')+interval '14 days','YYYY-MM-DD'))))$q$,'P0002',NULL,'Credit A rejects foreign customer');
SELECT throws_ok($q$SELECT public.process_sale_credit_v5((SELECT credit_req FROM _saleids WHERE label='A'),840211701,15,(SELECT sale_at FROM _saleids WHERE label='A'),true,0,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL,jsonb_build_array(jsonb_build_object('number',1,'amount',15,'due_date',to_char((SELECT sale_at FROM _saleids WHERE label='A')+interval '14 days','YYYY-MM-DD'))))$q$,'P0002',NULL,'Credit A rejects foreign product');
SELECT throws_ok($q$SELECT public.process_sale_v4(gen_random_uuid(),840211701,15,(SELECT sale_at FROM _saleids WHERE label='A'),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211401,'almacen_id',840211501,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'invalid',0,0,NULL,15,NULL)$q$,'22023',NULL,'Unsupported sale document denied');
UPDATE _saleids SET cash_id=(public.process_sale_v4((SELECT cash_req FROM _saleids WHERE label='A'),840211701,15,(SELECT sale_at FROM _saleids WHERE label='A'),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211401,'almacen_id',840211501,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)->>'venta_id')::bigint WHERE label='A';
UPDATE _saleids SET credit_result=public.process_sale_credit_v5((SELECT credit_req FROM _saleids WHERE label='A'),840211701,15,(SELECT sale_at FROM _saleids WHERE label='A'),true,0,jsonb_build_array(jsonb_build_object('producto_id',840211401,'almacen_id',840211501,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL,jsonb_build_array(jsonb_build_object('number',1,'amount',15,'due_date',to_char((SELECT sale_at FROM _saleids WHERE label='A')+interval '14 days','YYYY-MM-DD')))) WHERE label='A';
UPDATE _saleids SET credit_id=(credit_result->>'venta_id')::bigint WHERE label='A';
SELECT ok((SELECT cash_id IS NOT NULL FROM _saleids WHERE label='A'),'A creates paid sale');
SELECT ok((SELECT credit_id IS NOT NULL FROM _saleids WHERE label='A'),'A creates credit sale');
SELECT is((SELECT (credit_result->>'balance')::numeric FROM _saleids WHERE label='A'),15::numeric,'A credit balance 15');
SELECT ok((SELECT (credit_result->>'success')::boolean FROM _saleids WHERE label='A'),'A financial v5 succeeds');
SELECT is((public.process_sale_credit_v5((SELECT credit_req FROM _saleids WHERE label='A'),840211701,15,(SELECT sale_at FROM _saleids WHERE label='A'),true,0,jsonb_build_array(jsonb_build_object('producto_id',840211401,'almacen_id',840211501,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL,jsonb_build_array(jsonb_build_object('number',1,'amount',15,'due_date',to_char((SELECT sale_at FROM _saleids WHERE label='A')+interval '14 days','YYYY-MM-DD'))))->>'idempotent')::boolean,true,'A exact credit request retry idempotent');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.process_sale_credit_v5((SELECT credit_req FROM _saleids WHERE label='A'),840211702,15,(SELECT sale_at FROM _saleids WHERE label='B'),true,0,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL,jsonb_build_array(jsonb_build_object('number',1,'amount',15,'due_date',to_char((SELECT sale_at FROM _saleids WHERE label='B')+interval '14 days','YYYY-MM-DD'))))$q$,'23505',NULL,'B cannot replay A credit request UUID');
SELECT throws_ok($q$SELECT public.process_sale_v4((SELECT cash_req FROM _saleids WHERE label='B'),840211701,15,(SELECT sale_at FROM _saleids WHERE label='B'),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)$q$,'P0002',NULL,'Cash sale B rejects A customer');
SELECT throws_ok($q$SELECT public.process_sale_with_units_v4(gen_random_uuid(),840211701,15,(SELECT sale_at FROM _saleids WHERE label='B'),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)$q$,'P0002',NULL,'Units sale B rejects A customer');
SELECT throws_ok($q$SELECT public.process_sale_credit_v5((SELECT credit_req FROM _saleids WHERE label='B'),840211701,15,(SELECT sale_at FROM _saleids WHERE label='B'),true,0,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL,jsonb_build_array(jsonb_build_object('number',1,'amount',15,'due_date',to_char((SELECT sale_at FROM _saleids WHERE label='B')+interval '14 days','YYYY-MM-DD'))))$q$,'P0002',NULL,'Credit B rejects A customer');
UPDATE _saleids SET cash_id=(public.process_sale_v4((SELECT cash_req FROM _saleids WHERE label='B'),840211702,15,(SELECT sale_at FROM _saleids WHERE label='B'),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)->>'venta_id')::bigint WHERE label='B';
UPDATE _saleids SET credit_result=public.process_sale_credit_v5((SELECT credit_req FROM _saleids WHERE label='B'),840211702,15,(SELECT sale_at FROM _saleids WHERE label='B'),true,0,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL,jsonb_build_array(jsonb_build_object('number',1,'amount',15,'due_date',to_char((SELECT sale_at FROM _saleids WHERE label='B')+interval '14 days','YYYY-MM-DD')))) WHERE label='B';
UPDATE _saleids SET credit_id=(credit_result->>'venta_id')::bigint WHERE label='B';
SELECT ok((SELECT cash_id IS NOT NULL FROM _saleids WHERE label='B'),'B creates paid sale');
SELECT ok((SELECT credit_id IS NOT NULL FROM _saleids WHERE label='B'),'B creates credit sale');
SELECT is((SELECT (credit_result->>'balance')::numeric FROM _saleids WHERE label='B'),15::numeric,'B credit balance 15');
SELECT is((public.process_sale_credit_v5((SELECT credit_req FROM _saleids WHERE label='B'),840211702,15,(SELECT sale_at FROM _saleids WHERE label='B'),true,0,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL,jsonb_build_array(jsonb_build_object('number',1,'amount',15,'due_date',to_char((SELECT sale_at FROM _saleids WHERE label='B')+interval '14 days','YYYY-MM-DD'))))->>'idempotent')::boolean,true,'B exact credit retry idempotent');
RESET ROLE;
SELECT ok((SELECT count(*)=4 FROM public.ventas v JOIN _saleids i ON v.id IN (i.cash_id,i.credit_id) JOIN _fx f ON f.label=i.label AND f.org=v.organization_id),'Both tenants retain exactly own four sales');
SELECT ok((SELECT count(*)=2 FROM public.venta_cronogramas s JOIN _saleids i ON s.venta_id=i.credit_id JOIN _fx f ON f.label=i.label AND f.org=s.organization_id),'Two credit schedules scoped to A/B');
SELECT ok((SELECT count(*)=2 FROM public.venta_cuotas c JOIN _saleids i ON c.venta_id=i.credit_id JOIN _fx f ON f.label=i.label AND f.org=c.organization_id AND c.importe_vigente=15),'Both tenant installments amount 15');
SELECT ok((SELECT count(*)=2 FROM public.inventario_almacen ia JOIN _fx f ON f.org=ia.organization_id WHERE ia.producto_id=CASE f.label WHEN 'A' THEN 840211401 ELSE 840211402 END AND ia.cantidad=18),'Each tenant consumed two stock items only');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _fx WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _fx WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _fx WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.process_sale_v4(gen_random_uuid(),840211702,15,(SELECT sale_at FROM _saleids WHERE label='B'),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)$q$,'42501',NULL,'Operator cannot create sale without sales.create');
SELECT throws_ok($q$SELECT public.process_sale_credit_v5(gen_random_uuid(),840211702,15,(SELECT sale_at FROM _saleids WHERE label='B'),true,0,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL,jsonb_build_array(jsonb_build_object('number',1,'amount',15,'due_date',to_char((SELECT sale_at FROM _saleids WHERE label='B')+interval '14 days','YYYY-MM-DD'))))$q$,'42501',NULL,'Operator cannot create credit');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _fx WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.process_sale_v4(gen_random_uuid(),840211701,15,(SELECT sale_at FROM _saleids WHERE label='A'),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211401,'almacen_id',840211501,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)$q$,'42501',NULL,'Revoked A cannot create sale');
SELECT throws_ok($q$SELECT public.process_sale_credit_v5(gen_random_uuid(),840211701,15,(SELECT sale_at FROM _saleids WHERE label='A'),true,0,jsonb_build_array(jsonb_build_object('producto_id',840211401,'almacen_id',840211501,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL,jsonb_build_array(jsonb_build_object('number',1,'amount',15,'due_date',to_char((SELECT sale_at FROM _saleids WHERE label='A')+interval '14 days','YYYY-MM-DD'))))$q$,'42501',NULL,'Revoked A cannot create credit');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
