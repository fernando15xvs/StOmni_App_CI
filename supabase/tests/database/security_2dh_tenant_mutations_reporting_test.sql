-- 2D-H real A/B tenant authorization, product/profile writes and quotation expiry.
-- The two companies and all fiscal/inventory records are synthetic. ROLLBACK.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(25);
CREATE TEMP TABLE _actors(label text,uid uuid,org uuid,product_id bigint,old_quote bigint,new_quote bigint,receipt bigint) ON COMMIT DROP;
INSERT INTO _actors(label,uid,product_id,old_quote,new_quote,receipt)
SELECT label,gen_random_uuid(),p,old_id,new_id,receipt_id
FROM (VALUES ('A',840202401::bigint,840202101::bigint,840202103::bigint,840202301::bigint),
             ('B',840202402::bigint,840202102::bigint,840202104::bigint,840202302::bigint)) f(label,p,old_id,new_id,receipt_id);
GRANT SELECT,UPDATE ON _actors TO authenticated;
CREATE TEMP TABLE _checks(msg text) ON COMMIT DROP;
GRANT INSERT,SELECT ON _checks TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO auth.users(id,aud,role,email,email_confirmed_at)
SELECT uid,'authenticated','authenticated','2dh-scope-'||uid||'@example.invalid',now() FROM _actors;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _actors WHERE label='A'),true);
UPDATE _actors SET org=(public.create_my_organization_v1('Scope A','PE','PEN','America/Lima')->>'organization_id')::uuid WHERE label='A';
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _actors WHERE label='B'),true);
UPDATE _actors SET org=(public.create_my_organization_v1('Scope B','PE','PEN','America/Lima')->>'organization_id')::uuid WHERE label='B';
RESET ROLE;
SET LOCAL session_replication_role=replica;
INSERT INTO public.productos(id,organization_id,codigo,nombre,precio_unidad,precio_caja,precio_compra,tipo_venta,cantidad_por_caja,permitir_sin_stock,activo,es_servicio,item_type)
SELECT product_id,org,'SCOPE-'||label,'Product '||label,15,15,5,'UNIDAD',1,false,true,false,'stock_product' FROM _actors;
INSERT INTO public.cotizaciones(id,organization_id,request_id,fecha,total,estado,validez_dias)
SELECT old_quote,org,gen_random_uuid(),now()-interval '30 days',20,'pendiente',15 FROM _actors
UNION ALL SELECT new_quote,org,gen_random_uuid(),now(),20,'pendiente',15 FROM _actors;
INSERT INTO public.pagos_venta(id,organization_id,metodo,monto,fecha)
SELECT receipt,org,'transferencia',CASE WHEN label='A' THEN 11 ELSE 99 END,now() FROM _actors;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _actors WHERE label='A'),true);
INSERT INTO _checks SELECT is((public.actualizar_configuracion_negocio_v1('{"razon_social":"SCOPE A SAC","ruc":"20100070970","ubigeo":"150101","direccion":"Calle A 1","departamento":"LIMA","provincia":"LIMA","distrito":"LIMA","cod_local":"0000"}')->>'razon_social'),'SCOPE A SAC','A updates own fiscal profile');
INSERT INTO _checks SELECT is((SELECT razon_social FROM public.configuracion_negocio WHERE organization_id=(SELECT org FROM _actors WHERE label='A')),'SCOPE A SAC','A profile persisted');
INSERT INTO _checks SELECT isnt((SELECT razon_social FROM public.configuracion_negocio WHERE organization_id=(SELECT org FROM _actors WHERE label='B')),'SCOPE A SAC','A cannot inspect B profile');
INSERT INTO _checks SELECT throws_ok($q$SELECT public.actualizar_configuracion_negocio_v1('{"organization_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}')$q$,'22023',NULL,'Profile tenant injection forbidden');
INSERT INTO _checks SELECT throws_ok($q$SELECT public.actualizar_configuracion_negocio_v1('{"ruc":"123"}')$q$,'22023',NULL,'Invalid RUC denied');
INSERT INTO _checks SELECT is((public.actualizar_producto_seguro_v1(840202401,'{"nombre":"Product A updated"}',false)->'producto'->>'nombre'),'Product A updated','A updates local product');
INSERT INTO _checks SELECT is((SELECT nombre FROM public.productos WHERE id=840202401),'Product A updated','Product A state persisted');
INSERT INTO _checks SELECT is((SELECT nombre FROM public.productos WHERE id=840202402),NULL::text,'A cannot directly read B product');
INSERT INTO _checks SELECT throws_ok($q$SELECT public.actualizar_producto_seguro_v1(840202402,'{"nombre":"Tampered"}',false)$q$,'P0002',NULL,'A cannot mutate B product');
INSERT INTO _checks SELECT throws_ok($q$SELECT public.actualizar_producto_seguro_v1(840202401,'{"organization_id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}',false)$q$,'22023',NULL,'Product tenant injection forbidden');
INSERT INTO _checks SELECT lives_ok($q$SELECT public.actualizar_cotizaciones_vencidas()$q$,'A expiration RPC works');
INSERT INTO _checks SELECT is((SELECT estado FROM public.cotizaciones WHERE id=840202101),'vencida','A old quotation expires');
INSERT INTO _checks SELECT is((SELECT estado FROM public.cotizaciones WHERE id=840202102),NULL::text,'A cannot directly read B quotation');
INSERT INTO _checks SELECT is((SELECT estado FROM public.cotizaciones WHERE id=840202103),'pendiente','A future quotation stays pending');
INSERT INTO _checks SELECT is((SELECT coalesce(sum(total),0) FROM public.obtener_tendencia_movimientos('ingreso',now()-interval '1 day',now()+interval '1 day')),11::numeric,'A movement excludes B amount');
INSERT INTO _checks SELECT is((SELECT count(*)::integer FROM public.listar_documentos_electronicos_v1(now()-interval '1 day',now()+interval '1 day',50,0)),0,'A empty fiscal list');
RESET ROLE;
INSERT INTO _checks SELECT is((SELECT nombre FROM public.productos WHERE id=840202402),'Product B','A mutation preserved B product');
INSERT INTO _checks SELECT is((SELECT estado FROM public.cotizaciones WHERE id=840202102),'pendiente','A expiration preserved B old quotation');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _actors WHERE label='B'),true);
INSERT INTO _checks SELECT lives_ok($q$SELECT public.actualizar_cotizaciones_vencidas()$q$,'B expires its quotations');
INSERT INTO _checks SELECT is((SELECT estado FROM public.cotizaciones WHERE id=840202102),'vencida','B old quotation expires');
INSERT INTO _checks SELECT is((SELECT estado FROM public.cotizaciones WHERE id=840202104),'pendiente','B future quotation stays pending');
INSERT INTO _checks SELECT is((SELECT coalesce(sum(total),0) FROM public.obtener_tendencia_movimientos('ingreso',now()-interval '1 day',now()+interval '1 day')),99::numeric,'B movement excludes A amount');
INSERT INTO _checks SELECT is((SELECT count(*)::integer FROM public.listar_documentos_electronicos_v1(now()-interval '1 day',now()+interval '1 day',50,0)),0,'B empty fiscal list');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive'
WHERE organization_id=(SELECT org FROM _actors WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _actors WHERE label='B'),true);
INSERT INTO _checks SELECT throws_ok($q$SELECT public.actualizar_cotizaciones_vencidas()$q$,'42501',NULL,'Revoked employee cannot expire quotations');
INSERT INTO _checks SELECT throws_ok($q$SELECT public.actualizar_configuracion_negocio_v1('{}')$q$,'42501',NULL,'Revoked employee cannot update profile');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
