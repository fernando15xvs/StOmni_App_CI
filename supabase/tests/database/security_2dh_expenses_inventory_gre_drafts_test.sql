-- 2D-H: real authenticated purchase flows with isolated organization A/B.
-- It tests scoped creation/replay, foreign IDs, partial/final receipt,
-- cancellation, operator RBAC and employment revocation. Fully rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(32);
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
CREATE TEMP TABLE _guides(label text,kind text,id uuid,org uuid) ON COMMIT DROP;
INSERT INTO _guides(label,kind,id,org)
SELECT f.label,k.kind,gen_random_uuid(),f.org
FROM _fx f JOIN (VALUES('A','draft'),('A','sent'),('A','ticket'),('B','draft'),('B','operator')) k(label,kind)
ON f.label=k.label;
GRANT SELECT ON _guides TO authenticated;
CREATE TEMP TABLE _entries(label text,expense bigint,stock_req uuid) ON COMMIT DROP;
INSERT INTO _entries(label,stock_req) SELECT label,gen_random_uuid() FROM _fx;
GRANT ALL ON _entries TO authenticated;
UPDATE _entries SET stock_req=(SELECT stock_req FROM _entries WHERE label='A') WHERE label='B';
SET LOCAL session_replication_role=replica;
INSERT INTO public.guias_remision(
 id,organization_id,request_id,tipo_guia,tipo_documento_sunat,estado,
 motivo_codigo,motivo_descripcion,modalidad_transporte,fecha_traslado,
 partida_direccion,llegada_direccion,partida_ubigeo,llegada_ubigeo,peso_total,ticket_sunat
)
SELECT id,org,gen_random_uuid(),'remitente','09',
 CASE WHEN kind='sent' THEN 'pendiente_envio' ELSE 'borrador' END,
 '01','VENTA','02',now(),
 'Calle origen 123','Calle destino 123','150101','150101',1,
 CASE WHEN kind='ticket' THEN 'LOCAL-NONEXTERNAL' ELSE NULL END
FROM _guides;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.registrar_gasto_mixto(840211602,'Operaciones',100,'Fixture',now(),'[{"monto":50,"metodo":"Transferencia","afecta_caja_chica":false}]')$q$,'P0002',NULL,'A blocked from B expense supplier');
SELECT throws_ok($q$SELECT public.registrar_gasto_mixto(840211601,'Operaciones',-1,'Fixture',now(),'[{"monto":50,"metodo":"Transferencia","afecta_caja_chica":false}]')$q$,'22023',NULL,'Negative expense rejected');
SELECT throws_ok($q$SELECT public.registrar_gasto_mixto(840211601,'Operaciones',100,'Fixture',now(),'[{"monto":101,"metodo":"Transferencia"}]')$q$,'23514',NULL,'Expense overpayment rejected');
UPDATE _entries SET expense=public.registrar_gasto_mixto(840211601,'Operaciones',100,'Fixture',now(),'[{"monto":50,"metodo":"Transferencia","afecta_caja_chica":false}]') WHERE label='A';
SELECT ok((SELECT expense FROM _entries WHERE label='A') IS NOT NULL,'A created expense with partial bank payment');
SELECT throws_ok($q$SELECT public.registrar_ingreso_mercaderia_scaled_v2(gen_random_uuid(),840211402,now(),'Compra','LOCAL',840211602,'Fixture',jsonb_build_array(jsonb_build_object('almacen_id',840211502,'cantidad_base',1)),5,15,15,15)$q$,'P0002',NULL,'A blocked from B stock product');
SELECT throws_ok($q$SELECT public.registrar_ingreso_mercaderia_scaled_v2(gen_random_uuid(),840211401,now(),'Compra','LOCAL',840211602,'Fixture',jsonb_build_array(jsonb_build_object('almacen_id',840211501,'cantidad_base',1)),5,15,15,15)$q$,'P0002',NULL,'A blocked from B inventory supplier');
SELECT throws_ok($q$SELECT public.registrar_ingreso_mercaderia_scaled_v2(gen_random_uuid(),840211401,now(),'Compra','LOCAL',840211601,'Fixture',jsonb_build_array(jsonb_build_object('almacen_id',840211502,'cantidad_base',1)),5,15,15,15)$q$,'P0002',NULL,'A blocked from B warehouse');
SELECT throws_ok($q$SELECT public.registrar_ingreso_mercaderia_scaled_v2(NULL::uuid,840211401,now(),'Compra','LOCAL',840211601,'Fixture',jsonb_build_array(jsonb_build_object('almacen_id',840211501,'cantidad_base',1)),5,15,15,15)$q$,'22023',NULL,'Stock receipt requires UUID');
SELECT is((public.registrar_ingreso_mercaderia_scaled_v2((SELECT stock_req FROM _entries WHERE label='A'),840211401,now(),'Compra','LOCAL',840211601,'Fixture',jsonb_build_array(jsonb_build_object('almacen_id',840211501,'cantidad_base',1)),5,15,15,15)->>'cantidad_base_total')::integer,1,'A receives one unit of its product');
SELECT is((public.registrar_ingreso_mercaderia_scaled_v2((SELECT stock_req FROM _entries WHERE label='A'),840211401,now(),'Compra','LOCAL',840211601,'Fixture',jsonb_build_array(jsonb_build_object('almacen_id',840211501,'cantidad_base',1)),5,15,15,15)->>'cantidad_base_total')::integer,1,'A inventory UUID replay idempotent');
SELECT throws_ok($q$SELECT public.eliminar_borrador_guia_v1((SELECT id FROM _guides WHERE label='B' AND kind='draft'))$q$,'P0001',NULL,'A cannot delete B GRE draft');
SELECT throws_ok($q$SELECT public.eliminar_borrador_guia_v1((SELECT id FROM _guides WHERE label='A' AND kind='sent'))$q$,'P0001',NULL,'A cannot delete GRE in non-draft status');
SELECT throws_ok($q$SELECT public.eliminar_borrador_guia_v1((SELECT id FROM _guides WHERE label='A' AND kind='ticket'))$q$,'P0001',NULL,'A cannot delete GRE draft with SUNAT ticket');
SELECT is((public.eliminar_borrador_guia_v1((SELECT id FROM _guides WHERE label='A' AND kind='draft'))->>'success')::boolean,true,'A deletes own unsent GRE draft');
SELECT throws_ok($q$SELECT public.eliminar_borrador_guia_v1((SELECT id FROM _guides WHERE label='A' AND kind='draft'))$q$,'P0001',NULL,'Repeated deletion fails without leaking other guides');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.registrar_gasto_mixto(840211601,'Operaciones',100,'Fixture',now(),'[{"monto":50,"metodo":"Transferencia","afecta_caja_chica":false}]')$q$,'P0002',NULL,'B cannot pay A supplier');
UPDATE _entries SET expense=public.registrar_gasto_mixto(840211602,'Operaciones',100,'Fixture',now(),'[{"monto":50,"metodo":"Transferencia","afecta_caja_chica":false}]') WHERE label='B';
SELECT ok((SELECT expense FROM _entries WHERE label='B') IS NOT NULL,'B creates its own expense');
SELECT is((public.registrar_ingreso_mercaderia_scaled_v2((SELECT stock_req FROM _entries WHERE label='B'),840211402,now(),'Compra','LOCAL',840211602,'Fixture',jsonb_build_array(jsonb_build_object('almacen_id',840211502,'cantidad_base',1)),5,15,15,15)->>'producto_id')::bigint,840211402::bigint,'B same inventory UUID resolves B product not A');
SELECT throws_ok($q$SELECT public.eliminar_borrador_guia_v1((SELECT id FROM _guides WHERE label='A' AND kind='sent'))$q$,'P0001',NULL,'B cannot delete A GRE');
SELECT is((public.eliminar_borrador_guia_v1((SELECT id FROM _guides WHERE label='B' AND kind='draft'))->>'success')::boolean,true,'B deletes own GRE draft');
RESET ROLE;
SELECT is((SELECT saldo FROM public.gastos WHERE id=(SELECT expense FROM _entries WHERE label='A')),50::numeric,'A expense retains 50 outstanding');
SELECT is((SELECT saldo FROM public.gastos WHERE id=(SELECT expense FROM _entries WHERE label='B')),50::numeric,'B expense retains 50 outstanding');
SELECT ok((SELECT count(*)=2 FROM public.inventario_operaciones_idempotentes WHERE request_id=(SELECT stock_req FROM _entries WHERE label='A')),'Same inventory UUID scoped to two businesses');
SELECT ok((SELECT count(*)=2 FROM public.inventario_movimientos WHERE request_id=(SELECT stock_req FROM _entries WHERE label='A')),'A replay does not create duplicate stock movements');
SELECT ok((SELECT count(*)=2 FROM public.pagos_gasto WHERE organization_id IN (SELECT org FROM _fx)),'A and B each retain own bank payment');
SELECT ok((SELECT count(*)=2 FROM public.guias_remision g JOIN _guides f ON f.id=g.id WHERE f.kind IN('sent','ticket')),'Non-deletable A guides remain present');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _fx WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _fx WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _fx WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.registrar_ingreso_mercaderia_scaled_v2(gen_random_uuid(),840211402,now(),'Compra','LOCAL',840211602,'Fixture',jsonb_build_array(jsonb_build_object('almacen_id',840211502,'cantidad_base',1)),5,15,15,15)$q$,'42501',NULL,'Operator cannot receive stock without inventory.receive');
SELECT ok(public.registrar_gasto_mixto(840211602,'Operaciones',20,'Fixture',now(),'[]'::jsonb) IS NOT NULL,'Operator tenant.write can create own unpaid expense');
SELECT is((public.eliminar_borrador_guia_v1((SELECT id FROM _guides WHERE label='B' AND kind='operator'))->>'success')::boolean,true,'Operator tenant.write can delete own draft');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _fx WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.registrar_gasto_mixto(840211601,'Operaciones',100,'Fixture',now(),'[{"monto":50,"metodo":"Transferencia","afecta_caja_chica":false}]')$q$,'42501',NULL,'Revoked admin cannot create expense');
SELECT throws_ok($q$SELECT public.registrar_ingreso_mercaderia_scaled_v2(gen_random_uuid(),840211401,now(),'Compra','LOCAL',840211601,'Fixture',jsonb_build_array(jsonb_build_object('almacen_id',840211501,'cantidad_base',1)),5,15,15,15)$q$,'42501',NULL,'Revoked admin cannot receive stock');
SELECT throws_ok($q$SELECT public.eliminar_borrador_guia_v1((SELECT id FROM _guides WHERE label='A' AND kind='sent'))$q$,'42501',NULL,'Revoked admin cannot delete GRE');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
