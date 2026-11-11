-- 2D-H: authenticated A/B expense deletion with immutable closed cash evidence.
-- It tests scoped creation/replay, foreign IDs, partial/final receipt,
-- cancellation, operator RBAC and employment revocation. Fully rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(29);
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
CREATE TEMP TABLE _ex(label text,expense_id bigint,payment_id bigint) ON COMMIT DROP;
INSERT INTO _ex(label) SELECT label FROM _fx;
GRANT SELECT,UPDATE ON _ex TO authenticated;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
UPDATE _ex SET expense_id=public.registrar_gasto_mixto(840211601,'Operación',100,'Gasto A',now(),'[{"monto":40,"metodo":"Transferencia"},{"monto":20,"metodo":"Transferencia"}]'::jsonb) WHERE label='A';
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
UPDATE _ex SET expense_id=public.registrar_gasto_mixto(840211602,'Operación',100,'Gasto B',now(),'[{"monto":30,"metodo":"Transferencia"}]'::jsonb) WHERE label='B';
RESET ROLE;
UPDATE _ex e SET payment_id=(SELECT id FROM public.pagos_gasto p WHERE p.gasto_id=e.expense_id ORDER BY p.id LIMIT 1);
SELECT ok((SELECT expense_id FROM _ex WHERE label='A') IS NOT NULL,'A creates expense');
SELECT ok((SELECT expense_id FROM _ex WHERE label='B') IS NOT NULL,'B creates expense');
SELECT is((SELECT saldo FROM public.gastos WHERE id=(SELECT expense_id FROM _ex WHERE label='A')),40::numeric,'A expense has 40 balance');
SELECT is((SELECT saldo FROM public.gastos WHERE id=(SELECT expense_id FROM _ex WHERE label='B')),70::numeric,'B expense has 70 balance');
SELECT ok((SELECT count(*)=3 FROM public.pagos_gasto p JOIN _ex e ON p.gasto_id=e.expense_id),'Three initial bank payment rows');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.eliminar_pago_gasto_v1((SELECT payment_id FROM _ex WHERE label='B'),(SELECT expense_id FROM _ex WHERE label='B'))$q$,'P0002',NULL,'A cannot delete B expense payment');
SELECT throws_ok($q$SELECT public.eliminar_pago_gasto_v1((SELECT payment_id FROM _ex WHERE label='B'),(SELECT expense_id FROM _ex WHERE label='A'))$q$,'P0002',NULL,'A cannot attach B payment to A expense');
SELECT throws_ok($q$SELECT public.eliminar_gasto_v1((SELECT expense_id FROM _ex WHERE label='B'))$q$,'P0002',NULL,'A cannot delete B expense');
SELECT is((public.eliminar_pago_gasto_v1((SELECT payment_id FROM _ex WHERE label='A'),(SELECT expense_id FROM _ex WHERE label='A'))->>'saldo')::numeric,80::numeric,'A removes own transfer and balance rises to 80');
SELECT is((SELECT saldo FROM public.gastos WHERE id=(SELECT expense_id FROM _ex WHERE label='A')),80::numeric,'A balance persisted after deletion');
SELECT is((SELECT count(*)::int FROM public.pagos_gasto WHERE gasto_id=(SELECT expense_id FROM _ex WHERE label='A')),1,'Only one A bank payment remains');
SELECT throws_ok($q$SELECT public.eliminar_pago_gasto_v1((SELECT payment_id FROM _ex WHERE label='A'),(SELECT expense_id FROM _ex WHERE label='A'))$q$,'P0002',NULL,'Already removed payment cannot be removed twice');
CREATE TEMP TABLE _closed(session_id uuid,expense_id bigint,payment_id bigint) ON COMMIT DROP;
INSERT INTO _closed(session_id) VALUES(gen_random_uuid());
GRANT SELECT,UPDATE ON _closed TO authenticated;
UPDATE _closed SET expense_id=public.registrar_gasto_mixto(840211601,'Operación',50,'Gasto A',now(),'[]'::jsonb);
RESET ROLE;
SET LOCAL session_replication_role=replica;
INSERT INTO public.sesiones_caja(id,organization_id,branch_id,cash_register_id,usuario_id,estado,monto_apertura,fecha_apertura,fecha_cierre)
SELECT c.session_id,f.org,f.branch,r.id,f.uid,'CERRADA',100,now()-interval '1 day',now()
FROM _closed c JOIN _fx f ON f.label='A' JOIN public.cash_registers r ON r.organization_id=f.org AND r.is_default;
INSERT INTO public.pagos_gasto(organization_id,gasto_id,metodo,monto,fecha,afecta_caja_chica,cash_register_id,cash_session_id)
SELECT f.org,c.expense_id,'EFECTIVO',10,now()-interval '6 hours',true,r.id,c.session_id
FROM _closed c JOIN _fx f ON f.label='A' JOIN public.cash_registers r ON r.organization_id=f.org AND r.is_default;
SET LOCAL session_replication_role=origin;
UPDATE _closed SET payment_id=(SELECT id FROM public.pagos_gasto WHERE cash_session_id=(SELECT session_id FROM _closed));
SELECT ok((SELECT payment_id FROM _closed) IS NOT NULL,'Closed session fixture has a cash expense payment');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.eliminar_pago_gasto_v1((SELECT payment_id FROM _closed),(SELECT expense_id FROM _closed))$q$,'23514',NULL,'Closed cash expense payment cannot be deleted');
SELECT throws_ok($q$SELECT public.eliminar_gasto_v1((SELECT expense_id FROM _closed))$q$,'23514',NULL,'Parent expense cannot cascade-delete closed cash evidence');
SELECT is((public.eliminar_gasto_v1((SELECT expense_id FROM _ex WHERE label='A'))->>'success')::boolean,true,'A deletes own ordinary expense');
RESET ROLE;
SELECT ok(NOT EXISTS(SELECT 1 FROM public.gastos WHERE id=(SELECT expense_id FROM _ex WHERE label='A')),'A ordinary expense removed');
SELECT ok(EXISTS(SELECT 1 FROM public.gastos WHERE id=(SELECT expense_id FROM _closed)),'Closed-session expense preserved');
SELECT ok(EXISTS(SELECT 1 FROM public.pagos_gasto WHERE id=(SELECT payment_id FROM _closed)),'Closed-session payment preserved');
SELECT is((SELECT saldo FROM public.gastos WHERE id=(SELECT expense_id FROM _ex WHERE label='B')),70::numeric,'B expense unaffected by A mutations');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.eliminar_pago_gasto_v1((SELECT payment_id FROM _closed),(SELECT expense_id FROM _closed))$q$,'P0002',NULL,'B cannot remove closed A payment even as foreign ID');
SELECT throws_ok($q$SELECT public.eliminar_gasto_v1((SELECT expense_id FROM _closed))$q$,'P0002',NULL,'B cannot remove closed A expense');
SELECT is((public.eliminar_pago_gasto_v1((SELECT payment_id FROM _ex WHERE label='B'),(SELECT expense_id FROM _ex WHERE label='B'))->>'saldo')::numeric,100::numeric,'B deletes own payment, balance becomes 100');
SELECT is((public.eliminar_gasto_v1((SELECT expense_id FROM _ex WHERE label='B'))->>'success')::boolean,true,'B deletes own ordinary expense');
RESET ROLE;
SELECT ok(NOT EXISTS(SELECT 1 FROM public.gastos WHERE id=(SELECT expense_id FROM _ex WHERE label='B')),'B deletion persisted');
SELECT ok(EXISTS(SELECT 1 FROM public.pagos_gasto WHERE id=(SELECT payment_id FROM _closed)),'A closed cash payment survives B deletions');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _fx WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _fx WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _fx WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT throws_ok($q$SELECT public.eliminar_gasto_v1((SELECT expense_id FROM _closed))$q$,'P0002',NULL,'Operator B cannot delete A expense');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _fx WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($q$SELECT public.eliminar_gasto_v1((SELECT expense_id FROM _closed))$q$,'42501',NULL,'Revoked A cannot delete closed expense');
SELECT throws_ok($q$SELECT public.eliminar_pago_gasto_v1((SELECT payment_id FROM _closed),(SELECT expense_id FROM _closed))$q$,'42501',NULL,'Revoked A cannot delete closed payment');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
