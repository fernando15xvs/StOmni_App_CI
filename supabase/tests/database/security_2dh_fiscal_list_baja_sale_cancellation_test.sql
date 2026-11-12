-- 2D-H: real authenticated purchase flows with isolated organization A/B.
-- It tests scoped creation/replay, foreign IDs, partial/final receipt,
-- cancellation, operator RBAC and employment revocation. Fully rolled back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(55);
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
-- No call to SUNAT: accepted documents and notes are synthetic fixtures only.
CREATE TEMP TABLE _tax(
 label text,cancel_sale bigint,doc_sale bigint,note_sale bigint,
 doc_id uuid,note_comp uuid,note_id uuid,guide_id uuid,pending_doc uuid,
 note_req uuid,baja_req uuid,note_baja_req uuid,note_result jsonb,
 baja_result jsonb,note_baja_result jsonb
) ON COMMIT DROP;
INSERT INTO _tax(label,doc_id,note_comp,pending_doc,note_req,baja_req,note_baja_req)
SELECT label,gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid() FROM _fx;
UPDATE _tax b SET baja_req=a.baja_req,note_baja_req=a.note_baja_req,note_req=a.note_req
FROM _tax a WHERE a.label='A' AND b.label='B';
GRANT ALL ON _tax TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.clientes(id,organization_id,nombre)
SELECT CASE label WHEN 'A' THEN 840250701 ELSE 840250702 END,org,'FISCAL TENANT '||label FROM _fx;
INSERT INTO public.inventario_almacen(organization_id,producto_id,almacen_id,cantidad)
SELECT org,CASE label WHEN 'A' THEN 840211401 ELSE 840211402 END,
CASE label WHEN 'A' THEN 840211501 ELSE 840211502 END,30 FROM _fx;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
UPDATE _tax SET cancel_sale=(public.process_sale_v4(gen_random_uuid(),840250701,15,now(),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211401,'almacen_id',840211501,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)->>'venta_id')::bigint,
 doc_sale=(public.process_sale_v4(gen_random_uuid(),840250701,15,now(),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211401,'almacen_id',840211501,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)->>'venta_id')::bigint,note_sale=(public.process_sale_v4(gen_random_uuid(),840250701,15,now(),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211401,'almacen_id',840211501,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)->>'venta_id')::bigint WHERE label='A';
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
UPDATE _tax SET cancel_sale=(public.process_sale_v4(gen_random_uuid(),840250702,15,now(),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)->>'venta_id')::bigint,
 doc_sale=(public.process_sale_v4(gen_random_uuid(),840250702,15,now(),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)->>'venta_id')::bigint,note_sale=(public.process_sale_v4(gen_random_uuid(),840250702,15,now(),false,15,jsonb_build_array(jsonb_build_object('producto_id',840211402,'almacen_id',840211502,'cantidad',1,'piezas_reales',1,'precio_unitario',15,'precio_unitario_comercial',15,'subtotal',15,'tipo_unidad','unidad')),'[{"metodo":"transferencia","monto":15}]'::jsonb,NULL,NULL,'ticket_interno',0,0,NULL,15,NULL)->>'venta_id')::bigint WHERE label='B';
RESET ROLE;
SET LOCAL session_replication_role=replica;
INSERT INTO public.comprobantes_electronicos(
 id,organization_id,venta_id,tipo_documento_sunat,serie,correlativo,fecha_emision,estado,total,pdf_path)
SELECT t.doc_id,f.org,t.doc_sale,
CASE t.label WHEN 'A' THEN '01' ELSE '03' END,
CASE t.label WHEN 'A' THEN 'F001' ELSE 'B001' END,1,
(now() AT TIME ZONE 'America/Lima')::date,'aceptado',15,'test-'||lower(t.label)||'-doc.pdf'
FROM _tax t JOIN _fx f ON f.label=t.label
UNION ALL
SELECT t.note_comp,f.org,t.note_sale,
CASE t.label WHEN 'A' THEN '01' ELSE '03' END,
CASE t.label WHEN 'A' THEN 'F002' ELSE 'B002' END,2,
(now() AT TIME ZONE 'America/Lima')::date,'aceptado',15,'test-'||lower(t.label)||'-note-source.pdf'
FROM _tax t JOIN _fx f ON f.label=t.label;
INSERT INTO public.series_comprobantes(organization_id,tipo_documento_sunat,serie,activo,ultimo_correlativo)
SELECT f.org,CASE t.label WHEN 'A' THEN 'nota_credito_factura' ELSE 'nota_credito_boleta' END,
CASE t.label WHEN 'A' THEN 'FC01' ELSE 'BC01' END,true,0
FROM _tax t JOIN _fx f ON f.label=t.label;
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
UPDATE _tax SET note_result=public.crear_nota_credito_with_units_v3(
 note_req,note_comp,'01','Nota fiscal sintética','[]'::jsonb,NULL,true,now()) WHERE label='A';
UPDATE _tax SET note_id=(note_result->>'nota_credito_id')::uuid WHERE label='A';
UPDATE _tax SET guide_id=(public.guardar_guia_remision_v4(p_request_id=>gen_random_uuid(),p_emitir=>false,p_cantidad_bultos=>2)->>'guia_id')::uuid WHERE label='A';
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
UPDATE _tax SET note_result=public.crear_nota_credito_with_units_v3(
 note_req,note_comp,'01','Nota fiscal sintética','[]'::jsonb,NULL,true,now()) WHERE label='B';
UPDATE _tax SET note_id=(note_result->>'nota_credito_id')::uuid WHERE label='B';
UPDATE _tax SET guide_id=(public.guardar_guia_remision_v4(p_request_id=>gen_random_uuid(),p_emitir=>false,p_cantidad_bultos=>2)->>'guia_id')::uuid WHERE label='B';
RESET ROLE;
SET LOCAL session_replication_role=replica;
-- Synthetic accepted status only; NOT an actual SUNAT acceptance.
UPDATE public.notas_credito SET estado='aceptado',aceptado_at=now()
WHERE id IN (SELECT note_id FROM _tax);
INSERT INTO public.comprobantes_electronicos(
 id,organization_id,venta_id,tipo_documento_sunat,serie,correlativo,fecha_emision,estado,total)
SELECT t.pending_doc,f.org,t.cancel_sale,'01','F009',9,
(now() AT TIME ZONE 'America/Lima')::date,'pendiente_envio',15
FROM _tax t JOIN _fx f ON f.label=t.label WHERE t.label='A';
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT ok((SELECT cancel_sale FROM _tax WHERE label='A') IS NOT NULL AND (SELECT note_id FROM _tax WHERE label='A') IS NOT NULL AND (SELECT guide_id FROM _tax WHERE label='A') IS NOT NULL,'A creates sales, note and GRE draft');
SELECT throws_ok($x$SELECT public.anular_venta_v2((SELECT cancel_sale FROM _tax WHERE label='B'),'No autorizado')$x$,'P0002',NULL,'A cannot cancel B sale');
SELECT throws_ok($x$SELECT public.anular_venta_v2((SELECT cancel_sale FROM _tax WHERE label='A'),'No')$x$,'P0001',NULL,'Cancellation requires reason length');
SELECT throws_ok($x$SELECT public.anular_venta_v2((SELECT cancel_sale FROM _tax WHERE label='A'),'Comprobante pendiente')$x$,'P0001',NULL,'Pending electronic invoice prevents cancellation');
RESET ROLE;
SET LOCAL session_replication_role=replica;
DELETE FROM public.comprobantes_electronicos WHERE id=(SELECT pending_doc FROM _tax WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT is((public.anular_venta_v2((SELECT cancel_sale FROM _tax WHERE label='A'),'Anulación interna de prueba')->>'success')::boolean,true,'A cancels own sale with no electronic invoice');
SELECT is((public.anular_venta_v2((SELECT cancel_sale FROM _tax WHERE label='A'),'Anulación interna de prueba')->>'idempotent')::boolean,true,'A cancellation replay is idempotent');
SELECT throws_ok($x$SELECT public.anular_venta_v2((SELECT doc_sale FROM _tax WHERE label='A'),'Documento aceptado')$x$,'P0001',NULL,'Accepted electronic invoice forbids direct sale cancellation');
SELECT is((SELECT count(*)::int FROM public.listar_documentos_electronicos_v1(now()-interval '2 days',now()+interval '1 day',50,0)),4,'A fiscal list contains exactly 2 docs, one note, one GRE');
SELECT is((SELECT count(*)::int FROM public.listar_documentos_electronicos_v1(now()-interval '2 days',now()+interval '1 day',50,0) l WHERE l.categoria='factura'),2,'A document type SUNAT 01 maps to factura');
SELECT is((SELECT count(*)::int FROM public.listar_documentos_electronicos_v1(now()-interval '2 days',now()+interval '1 day',50,0) l WHERE l.categoria='nota'),1,'A sees one own credit note');
SELECT is((SELECT count(*)::int FROM public.listar_documentos_electronicos_v1(now()-interval '2 days',now()+interval '1 day',50,0) l WHERE l.categoria='guia'),1,'A sees one own GRE draft');
SELECT is((SELECT count(*)::int FROM public.listar_documentos_electronicos_v1(now()-interval '2 days',now()+interval '1 day',50,0) l WHERE l.id=(SELECT doc_id FROM _tax WHERE label='B')::text),0,'A cannot list B invoice UUID');
SELECT is((SELECT pdf_path FROM public.listar_documentos_electronicos_v1(now()-interval '2 days',now()+interval '1 day',50,0) l WHERE l.id=(SELECT doc_id FROM _tax WHERE label='A')::text),'test-a-doc.pdf','A own fiscal PDF path only');
SELECT is((SELECT count(*)::int FROM public.listar_documentos_electronicos_v1(now()-interval '2 days',now()+interval '1 day',50,1)),3,'A fiscal pagination offset works');
SELECT throws_ok($x$SELECT * FROM public.listar_documentos_electronicos_v1(now(),now()-interval '1 day',50,0)$x$,'P0001',NULL,'A invalid date window denied');
SELECT throws_ok($x$SELECT public.solicitar_baja_tributaria_v1(gen_random_uuid(),'comprobante',(SELECT doc_id FROM _tax WHERE label='B'),'BAJA DEV VALIDADA')$x$,'P0001',NULL,'A cannot request baja for B invoice');
SELECT throws_ok($x$SELECT public.solicitar_baja_tributaria_v1(gen_random_uuid(),'comprobante',(SELECT note_comp FROM _tax WHERE label='A'),'BAJA DEV VALIDADA')$x$,'P0001',NULL,'A cannot baja invoice with active accepted credit note');
UPDATE _tax SET baja_result=public.solicitar_baja_tributaria_v1((SELECT baja_req FROM _tax WHERE label='A'),'comprobante',(SELECT doc_id FROM _tax WHERE label='A'),'BAJA DEV VALIDADA') WHERE label='A';
SELECT is(((SELECT baja_result FROM _tax WHERE label='A')->>'tipo_proceso'),'comunicacion_baja','A factura baja uses comunicación de baja');
SELECT is((public.solicitar_baja_tributaria_v1((SELECT baja_req FROM _tax WHERE label='A'),'comprobante',(SELECT doc_id FROM _tax WHERE label='A'),'BAJA DEV VALIDADA')->>'idempotent')::boolean,true,'A baja exact request replay idempotent');
SELECT throws_ok($x$SELECT public.solicitar_baja_tributaria_v1((SELECT baja_req FROM _tax WHERE label='A'),'comprobante',(SELECT note_comp FROM _tax WHERE label='A'),'BAJA DEV VALIDADA')$x$,'23505',NULL,'A baja UUID cannot be reused for another invoice');
SELECT throws_ok($x$SELECT public.solicitar_baja_tributaria_v1((SELECT baja_req FROM _tax WHERE label='A'),'comprobante',(SELECT doc_id FROM _tax WHERE label='B'),'BAJA DEV VALIDADA')$x$,'23505',NULL,'A baja UUID cannot silently acknowledge foreign invoice');
SELECT throws_ok($x$SELECT public.solicitar_baja_tributaria_v1((SELECT baja_req FROM _tax WHERE label='A'),'comprobante',(SELECT doc_id FROM _tax WHERE label='A'),'MOTIVO DISTINTO')$x$,'23505',NULL,'A baja UUID binds reason');
UPDATE _tax SET note_baja_result=public.solicitar_baja_tributaria_v1((SELECT note_baja_req FROM _tax WHERE label='A'),'nota_credito',(SELECT note_id FROM _tax WHERE label='A'),'BAJA DEV VALIDADA') WHERE label='A';
SELECT is(((SELECT note_baja_result FROM _tax WHERE label='A')->>'tipo_proceso'),'comunicacion_baja','A accepted synthetic NC baja uses comunicación');
SELECT is((public.solicitar_baja_tributaria_v1((SELECT note_baja_req FROM _tax WHERE label='A'),'nota_credito',(SELECT note_id FROM _tax WHERE label='A'),'BAJA DEV VALIDADA')->>'idempotent')::boolean,true,'A note baja replay idempotent');
SELECT throws_ok($x$SELECT public.solicitar_baja_tributaria_v1(gen_random_uuid(),'nota_credito',(SELECT note_id FROM _tax WHERE label='B'),'BAJA DEV VALIDADA')$x$,'P0001',NULL,'A cannot baja B credit note');
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT ok((SELECT cancel_sale FROM _tax WHERE label='B') IS NOT NULL AND (SELECT note_id FROM _tax WHERE label='B') IS NOT NULL AND (SELECT guide_id FROM _tax WHERE label='B') IS NOT NULL,'B creates sales, note and GRE draft');
SELECT throws_ok($x$SELECT public.anular_venta_v2((SELECT doc_sale FROM _tax WHERE label='A'),'No autorizado')$x$,'P0002',NULL,'B cannot cancel A sale');
SELECT is((SELECT count(*)::int FROM public.listar_documentos_electronicos_v1(now()-interval '2 days',now()+interval '1 day',50,0)),4,'B list contains 2 docs one note one guide');
SELECT is((SELECT count(*)::int FROM public.listar_documentos_electronicos_v1(now()-interval '2 days',now()+interval '1 day',50,0) l WHERE l.categoria='boleta'),2,'B SUNAT 03 maps to boleta');
SELECT is((SELECT count(*)::int FROM public.listar_documentos_electronicos_v1(now()-interval '2 days',now()+interval '1 day',50,0) l WHERE l.categoria='nota'),1,'B sees own note only');
SELECT is((SELECT count(*)::int FROM public.listar_documentos_electronicos_v1(now()-interval '2 days',now()+interval '1 day',50,0) l WHERE l.categoria='guia'),1,'B sees own GRE only');
SELECT is((SELECT count(*)::int FROM public.listar_documentos_electronicos_v1(now()-interval '2 days',now()+interval '1 day',50,0) l WHERE l.id=(SELECT doc_id FROM _tax WHERE label='A')::text),0,'B cannot list A invoice');
SELECT is((SELECT pdf_path FROM public.listar_documentos_electronicos_v1(now()-interval '2 days',now()+interval '1 day',50,0) l WHERE l.id=(SELECT doc_id FROM _tax WHERE label='B')::text),'test-b-doc.pdf','B own PDF evidence path only');
SELECT throws_ok($x$SELECT public.solicitar_baja_tributaria_v1(gen_random_uuid(),'comprobante',(SELECT doc_id FROM _tax WHERE label='A'),'BAJA DEV VALIDADA')$x$,'P0001',NULL,'B cannot request baja for A invoice');
UPDATE _tax SET baja_result=public.solicitar_baja_tributaria_v1((SELECT baja_req FROM _tax WHERE label='B'),'comprobante',(SELECT doc_id FROM _tax WHERE label='B'),'BAJA DEV VALIDADA') WHERE label='B';
SELECT is(((SELECT baja_result FROM _tax WHERE label='B')->>'tipo_proceso'),'resumen_boletas','B boleta baja uses resumen de boletas');
SELECT is((public.solicitar_baja_tributaria_v1((SELECT baja_req FROM _tax WHERE label='B'),'comprobante',(SELECT doc_id FROM _tax WHERE label='B'),'BAJA DEV VALIDADA')->>'idempotent')::boolean,true,'B own fiscal baja replay idempotent');
SELECT isnt((SELECT baja_result FROM _tax WHERE label='A')->>'solicitud_id',(SELECT baja_result FROM _tax WHERE label='B')->>'solicitud_id','Same request UUID between companies creates separate solicitudes');
UPDATE _tax SET note_baja_result=public.solicitar_baja_tributaria_v1((SELECT note_baja_req FROM _tax WHERE label='B'),'nota_credito',(SELECT note_id FROM _tax WHERE label='B'),'BAJA DEV VALIDADA') WHERE label='B';
SELECT is(((SELECT note_baja_result FROM _tax WHERE label='B')->>'tipo_proceso'),'resumen_boletas','B accepted synthetic note baja uses boleta summary');
SELECT is((public.solicitar_baja_tributaria_v1((SELECT note_baja_req FROM _tax WHERE label='B'),'nota_credito',(SELECT note_id FROM _tax WHERE label='B'),'BAJA DEV VALIDADA')->>'idempotent')::boolean,true,'B note baja replay idempotent');
SELECT throws_ok($x$SELECT public.solicitar_baja_tributaria_v1(gen_random_uuid(),'nota_credito',(SELECT note_id FROM _tax WHERE label='A'),'BAJA DEV VALIDADA')$x$,'P0001',NULL,'B cannot baja A credit note');
SELECT is((public.anular_venta_v2((SELECT cancel_sale FROM _tax WHERE label='B'),'Venta sin comprobante')->>'success')::boolean,true,'B cancels own sale without fiscal document');
SELECT is((public.anular_venta_v2((SELECT cancel_sale FROM _tax WHERE label='B'),'Venta sin comprobante')->>'idempotent')::boolean,true,'B cancellation replay idempotent');
RESET ROLE;
SELECT ok((SELECT count(*)=4 FROM public.solicitudes_baja_tributaria sb JOIN _tax t ON sb.request_id IN(t.baja_req,t.note_baja_req) JOIN _fx f ON sb.organization_id=f.org AND t.label=f.label),'Four tax-baja request rows belong to A/B');
SELECT ok((SELECT count(*)=2 FROM public.solicitudes_baja_tributaria WHERE tipo_origen='nota_credito' AND estado='pendiente'),'Two synthetic note-baja requests pending only');
SELECT ok((SELECT count(*)=2 FROM public.solicitudes_baja_tributaria WHERE tipo_origen='comprobante' AND estado='pendiente'),'Two synthetic invoice-baja requests pending only');
SELECT ok((SELECT count(*)=2 FROM public.guias_remision g JOIN _tax t ON t.guide_id=g.id JOIN _fx f ON f.org=g.organization_id AND f.label=t.label WHERE g.estado='borrador' AND g.ticket_sunat IS NULL),'GRE drafts remain unissued A/B');
SELECT ok((SELECT count(*)=2 FROM public.notas_credito n JOIN _tax t ON n.id=t.note_id JOIN _fx f ON f.org=n.organization_id AND t.label=f.label WHERE n.estado_baja_tributaria='solicitada'),'Only own synthetic NCs linked to baja request');
SELECT ok((SELECT count(*)=2 FROM public.ventas_requests_anulados a JOIN _tax t ON a.venta_id_original=t.cancel_sale JOIN _fx f ON f.org=a.organization_id AND f.label=t.label),'A/B sale cancellation snapshots preserved');
SELECT ok(NOT EXISTS(SELECT 1 FROM public.ventas v JOIN _tax t ON v.id=t.cancel_sale),'A/B canceled sales no longer active');
SET LOCAL session_replication_role=replica;
UPDATE public.app_users SET base_role='operador' WHERE user_id=(SELECT uid FROM _fx WHERE label='B');
UPDATE public.empleados SET rol='operador' WHERE auth_id=(SELECT uid FROM _fx WHERE label='B');
DELETE FROM public.employee_roles WHERE organization_id=(SELECT org FROM _fx WHERE label='B');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='B'),true);
SELECT is((SELECT count(*)::int FROM public.listar_documentos_electronicos_v1(now()-interval '2 days',now()+interval '1 day',50,0)),4,'B operator may read only B fiscal documents');
SELECT throws_ok($x$SELECT public.solicitar_baja_tributaria_v1(gen_random_uuid(),'comprobante',(SELECT note_comp FROM _tax WHERE label='B'),'BAJA DEV VALIDADA')$x$,'P0001',NULL,'B operator cannot request tax baja');
SELECT throws_ok($x$SELECT public.anular_venta_v2((SELECT note_sale FROM _tax WHERE label='B'),'No permitido')$x$,'42501',NULL,'B operator cannot cancel sale');
RESET ROLE;
SET LOCAL session_replication_role=replica;
UPDATE public.empleados SET activo=false,employment_status='inactive' WHERE organization_id=(SELECT org FROM _fx WHERE label='A');
SET LOCAL session_replication_role=origin;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',(SELECT uid::text FROM _fx WHERE label='A'),true);
SELECT throws_ok($x$SELECT * FROM public.listar_documentos_electronicos_v1(now()-interval '2 days',now()+interval '1 day',50,0)$x$,'42501',NULL,'Revoked A cannot list electronic documents');
SELECT throws_ok($x$SELECT public.solicitar_baja_tributaria_v1(gen_random_uuid(),'comprobante',(SELECT doc_id FROM _tax WHERE label='A'),'BAJA DEV VALIDADA')$x$,'P0001',NULL,'Revoked A cannot request tax baja');
SELECT throws_ok($x$SELECT public.anular_venta_v2((SELECT note_sale FROM _tax WHERE label='A'),'No permitido')$x$,'42501',NULL,'Revoked A cannot cancel sale');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
