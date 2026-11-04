-- 2D-D E2E: accept financial NC on a provenance-certified v2 schedule,
-- using a synthetic accepted fiscal document. Does not issue SUNAT documents.
-- Real RPC v5 with synthetic stock, seller, tenant and two credit purchases.
-- Only local/DEV, BEGIN...ROLLBACK; no production/customer records are read.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(24);
CREATE TEMP TABLE _2db_fixture(
 org uuid,actor uuid,branch uuid,role_id uuid,
 employee_id bigint,customer_id bigint,product_id bigint,warehouse_id bigint,
 request0 uuid,request20 uuid,request_units uuid,sale_at timestamptz,
 result0 jsonb,result20 jsonb,retry20 jsonb,reader20 jsonb, result_units jsonb,reader_units jsonb
) ON COMMIT DROP;
INSERT INTO _2db_fixture(
 org,actor,branch,role_id,employee_id,customer_id,product_id,warehouse_id,
 request0,request20,request_units,sale_at)
VALUES(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
 840130101,840130102,840130103,840130104,
 gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),now()-interval '1 minute');
GRANT SELECT,UPDATE ON TABLE _2db_fixture TO authenticated;
SET LOCAL session_replication_role=replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org,'2D-B sale E2E synthetic org','PE','PEN','America/Lima' FROM _2db_fixture;
INSERT INTO auth.users(id,aud,role)
SELECT actor,'authenticated','authenticated' FROM _2db_fixture;
INSERT INTO public.app_users(user_id,organization_id,status,base_role)
SELECT actor,org,'active','admin' FROM _2db_fixture;
INSERT INTO public.branches(id,organization_id,code,name,is_main,status)
SELECT branch,org,'MAIN','Test Branch',true,'active' FROM _2db_fixture;
INSERT INTO public.roles(id,organization_id,code,name,is_system,status)
SELECT role_id,org,'admin','Admin',true,'active' FROM _2db_fixture;
INSERT INTO public.empleados(id,organization_id,branch_id,auth_id,app_user_id,nombre,rol,activo,employment_status)
SELECT employee_id,org,branch,actor,actor,'Test seller','admin',true,'active'
FROM _2db_fixture;
INSERT INTO public.employee_roles(organization_id,employee_id,role_id)
SELECT org,employee_id,role_id FROM _2db_fixture;
INSERT INTO public.configuracion_negocio(id,organization_id,facturacion_habilitada)
SELECT 840130105,org,false FROM _2db_fixture;
INSERT INTO public.business_capabilities(organization_id,business_id,credit_sales,electronic_invoicing)
SELECT org,840130105,true,false FROM _2db_fixture;
INSERT INTO public.clientes(id,organization_id,nombre)
SELECT customer_id,org,'Test Customer' FROM _2db_fixture;
INSERT INTO public.productos(id,organization_id,nombre,precio_unidad,precio_caja,tipo_venta,permitir_sin_stock,activo,es_servicio,item_type)
SELECT product_id,org,'Test Item',100,100,'UNIDAD',false,true,false,'stock_product'
FROM _2db_fixture;
-- Configured presentation: one "caja" consists of 2 "unidad" base units.
INSERT INTO public.product_unit_profiles(product_id,organization_id,revision,profile)
SELECT product_id,org,1, '{
 "schema_version":2,"base_code":"unidad",
 "presentations":[
  {"code":"unidad","singular":"Unidad","plural":"Unidades","factor":1,"fractional":false,"precision":0,"fiscal_unit_code":"NIU"},
  {"code":"caja","singular":"Caja","plural":"Cajas","factor":2,"fractional":false,"precision":0,"fiscal_unit_code":"BX"}
 ]
}'::jsonb FROM _2db_fixture;
INSERT INTO public.almacenes(id,organization_id,branch_id,nombre)
SELECT warehouse_id,org,branch,'Test Warehouse' FROM _2db_fixture;
INSERT INTO public.inventario_almacen(organization_id,producto_id,almacen_id,cantidad)
SELECT org,product_id,warehouse_id,15 FROM _2db_fixture;
SET LOCAL session_replication_role=origin;


-- Actual sale with bank down payment, using authenticated production writer.
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM _2db_fixture),true);
SET LOCAL ROLE authenticated;
UPDATE _2db_fixture SET result20=public.process_sale_credit_v5(
 request20,customer_id,100,sale_at,true,20,
 jsonb_build_array(jsonb_build_object(
   'producto_id',product_id,'almacen_id',warehouse_id,'cantidad',1,
   'piezas_reales',1,'precio_unitario',100,
   'precio_unitario_comercial',100,'subtotal',100,'tipo_unidad','unidad')),
 '[{"metodo":"transferencia","monto":20}]'::jsonb,
 NULL,NULL,'ticket_interno',0,0,NULL,100,NULL,
 jsonb_build_array(
  jsonb_build_object('number',1,'amount',40,'due_date',to_char(sale_at+interval '14 day','YYYY-MM-DD')),
  jsonb_build_object('number',2,'amount',40,'due_date',to_char(sale_at+interval '28 day','YYYY-MM-DD')))
);
RESET ROLE;
CREATE TEMP TABLE _2dc_results(
 request_id uuid NOT NULL, original_event_id uuid,
 reversed jsonb, retry jsonb, paid jsonb, payment_event_id uuid,
 payment_reversed jsonb
) ON COMMIT DROP;
INSERT INTO _2dc_results(request_id) VALUES(gen_random_uuid());
UPDATE _2dc_results r SET original_event_id=(
 SELECT ev.id FROM public.venta_eventos_financieros ev
 JOIN public.venta_operaciones_financieras op ON op.id=ev.operacion_id
 CROSS JOIN _2db_fixture f
 WHERE ev.organization_id=f.org AND ev.venta_id=(f.result20->>'venta_id')::bigint
 AND op.tipo='apertura' AND ev.tipo='cobro' LIMIT 1
);

UPDATE _2dc_results r SET reversed=private.financial_2dc_reverse_initial_transfer(
 (SELECT org FROM _2db_fixture),
 (SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),
 r.request_id,r.original_event_id,now(),'BANK-REV-TEST-20261104'
);

CREATE TEMP TABLE _2dd_nc (id uuid NOT NULL, comp uuid NOT NULL,preview jsonb,finalized jsonb) ON COMMIT DROP;
INSERT INTO _2dd_nc VALUES(gen_random_uuid(),gen_random_uuid(),NULL,NULL);
SET LOCAL session_replication_role=replica;
INSERT INTO public.comprobantes_electronicos(
 id,organization_id,venta_id,tipo_documento_sunat,serie,correlativo,fecha_emision,estado,total
)
 SELECT x.comp,f.org,(f.result20->>'venta_id')::bigint,'01','F001',1,
 (now() AT TIME ZONE 'America/Lima')::date,'aceptado',100
 FROM _2dd_nc x CROSS JOIN _2db_fixture f;
INSERT INTO public.notas_credito(
 id,request_id,comprobante_id,venta_id,tipo_origen,tipo_doc_afectado,
 serie_afectada,correlativo_afectado,motivo_codigo,motivo_descripcion,
 serie,correlativo,fecha_emision,fecha_emision_ts,
 organization_id,moneda,estado,afecta_dinero,total,aceptado_at
)
 SELECT x.id,gen_random_uuid(),x.comp,(f.result20->>'venta_id')::bigint,
 'venta','01','F001',1,'01','NC synthetic financial fixture',
 'FC01',1,(now() AT TIME ZONE 'America/Lima')::date,
 now()-interval '20 seconds',f.org,'PEN','aceptado',true,30,now()-interval '10 seconds'
 FROM _2dd_nc x CROSS JOIN _2db_fixture f;
SET LOCAL session_replication_role=origin;

-- Preview under administrator identity. Other-tenant access is denied.
SELECT set_config('request.jwt.claim.sub',(SELECT actor::text FROM _2db_fixture),true);
SELECT set_config('request.headers',jsonb_build_object('x-stomni-organization-id',(SELECT org FROM _2db_fixture))::text,true);
UPDATE _2dd_nc t SET preview=private.financial_2c6a_preview_credit_note(
 (SELECT org FROM _2db_fixture),
 (SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),t.id
);
SELECT ok((SELECT (preview->>'saldo_propuesto')::numeric=70
   AND (preview->>'exigible_propuesto')::numeric=70
   AND jsonb_array_length(preview->'reducciones_cuotas')=2
   FROM _2dd_nc),'v2 authenticated NC preview estimates 30 exactly');
SELECT ok((SELECT preview->>'aplicado'='false' AND preview->>'dinero_entregado'='false'
   FROM _2dd_nc),'preview never writes or refunds cash');
SELECT ok((SELECT count(*)=0 FROM public.venta_eventos_financieros e CROSS JOIN _2db_fixture f
   WHERE e.organization_id=f.org AND e.venta_id=(f.result20->>'venta_id')::bigint
   AND e.tipo='nota_credito'),'preview produced no financial adjustment');
SELECT ok((SELECT count(*)=1 FROM public.venta_cronogramas cr CROSS JOIN _2db_fixture f
   WHERE cr.organization_id=f.org AND cr.venta_id=(f.result20->>'venta_id')::bigint
   AND cr.version=1 AND cr.estado='sustituido'),'certified origin keeps v1 historical');

-- Disallowed reads and tampered lineage must fail closed, without
-- committing the modified test row. Every negative probe uses a subtransaction.
CREATE FUNCTION pg_temp._2dd_preview_fails(p_org uuid,p_sale bigint,p_nc uuid)
RETURNS boolean LANGUAGE plpgsql AS $fn$
BEGIN
 PERFORM private.financial_2c6a_preview_credit_note(p_org,p_sale,p_nc);
 RETURN false;
EXCEPTION WHEN OTHERS THEN
 RETURN true;
END $fn$;
CREATE FUNCTION pg_temp._2dd_tampered_lineage_fails()
RETURNS boolean LANGUAGE plpgsql AS $fn$
BEGIN
 UPDATE public.venta_operaciones_financieras
 SET metadata_apertura=metadata_apertura-'origen'
 WHERE id=(SELECT e.operacion_id FROM public.venta_eventos_financieros e
 JOIN _2dc_results r ON e.id=(r.reversed->>'reversal_event_id')::uuid);
 PERFORM private.financial_2c6a_preview_credit_note(
  (SELECT org FROM _2db_fixture),
  (SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),
  (SELECT id FROM _2dd_nc));
 RETURN false;
EXCEPTION WHEN OTHERS THEN RETURN true;
END $fn$;
CREATE FUNCTION pg_temp._2dd_unsupported_v3_fails()
RETURNS boolean LANGUAGE plpgsql AS $fn$
BEGIN
 UPDATE public.venta_cronogramas
 SET version=3 WHERE id=(SELECT (reversed->>'schedule_id')::uuid FROM _2dc_results);
 PERFORM private.financial_2c6a_preview_credit_note(
  (SELECT org FROM _2db_fixture),
  (SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),
  (SELECT id FROM _2dd_nc));
 RETURN false;
EXCEPTION WHEN OTHERS THEN RETURN true;
END $fn$;
SELECT ok(pg_temp._2dd_preview_fails(gen_random_uuid(),
  (SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),
  (SELECT id FROM _2dd_nc)),
  'preview rejects wrong tenant');
SELECT ok(pg_temp._2dd_preview_fails(
  (SELECT org FROM _2db_fixture),840139999,(SELECT id FROM _2dd_nc)),
  'preview rejects incorrect sale ID');
SELECT ok(pg_temp._2dd_tampered_lineage_fails(),
  'tampered certified v2 operation origin fails closed');
SELECT ok(pg_temp._2dd_unsupported_v3_fails(),
  'unsupported schedule version 3 stays blocked');
SELECT ok((SELECT version=2 AND estado='vigente' FROM public.venta_cronogramas
  WHERE id=(SELECT (reversed->>'schedule_id')::uuid FROM _2dc_results)),
  'negative probes do not persist tampered schedule data');

-- Change synthetic NC to pending without invoking fiscal transition,
-- then exercise the real atomic finalizer under the trusted fixture.
SET LOCAL session_replication_role=replica;
UPDATE public.notas_credito SET estado='pendiente_envio',aceptado_at=NULL
WHERE id=(SELECT id FROM _2dd_nc);
SET LOCAL session_replication_role=origin;
UPDATE _2dd_nc t SET finalized=public.nota_credito_finalizar(t.id,NULL,'aceptado','{}'::jsonb);
SELECT ok((SELECT estado='aceptado' FROM public.notas_credito WHERE id=(SELECT id FROM _2dd_nc)),
 'NC accepted through real finalizer, not manual accounting');
SELECT ok((SELECT cf.exigible=70 AND cf.cobros_netos=0 AND cf.saldo_pendiente=70
 FROM public.venta_cuentas_financieras cf CROSS JOIN _2db_fixture f
 WHERE cf.organization_id=f.org AND cf.venta_id=(f.result20->>'venta_id')::bigint),
 'v2 finalizer moves the canonical ledger from 100 to 70');
SELECT ok((SELECT COUNT(*)=3 AND SUM(c.importe_vigente)=70
 FROM public.venta_cuotas c CROSS JOIN _2dc_results r
 WHERE c.cronograma_id=(r.reversed->>'schedule_id')::uuid),
 'NC reduces only active version-2 installment principal');
SELECT ok((SELECT COUNT(*)=2 AND SUM(c.importe_vigente)=80
 FROM public.venta_cuotas c CROSS JOIN _2dc_results r
 WHERE c.cronograma_id=(r.reversed->>'previous_schedule_id')::uuid),
 'historic version-1 installments are not mutated');
SELECT ok((SELECT COUNT(*)=1 FROM public.venta_eventos_financieros e CROSS JOIN _2db_fixture f
 WHERE e.organization_id=f.org AND e.venta_id=(f.result20->>'venta_id')::bigint
 AND e.tipo='nota_credito' AND e.delta_exigible=-30),
 'financial NC event registered exactly once');
SELECT ok((SELECT a.saldo_calculado=70 AND a.apta_para_motor
 FROM private.financial_2c_audit_sale(
   (SELECT org FROM _2db_fixture),
   (SELECT (result20->>'venta_id')::bigint FROM _2db_fixture)) a),
 'full canonical audit remains good after version-2 NC');
SELECT ok((SELECT cr.version=2 AND cr.estado='vigente' FROM public.venta_cronogramas cr
 JOIN _2dc_results r ON cr.id=(r.reversed->>'schedule_id')::uuid),
 'NC does not silently create an unrelated schedule version');
SELECT ok((SELECT count(*)=0 FROM private.financial_nc_intents),
 'no stale NC writing intents');
SELECT ok((SELECT sum(importe_vigente)=70 FROM private.financial_2c4_installments(
 (SELECT org FROM _2db_fixture),
 (SELECT (result20->>'venta_id')::bigint FROM _2db_fixture),NULL)),
 'active schedule reader remains 70 PEN');

-- Simulate the *internal financial transition* of an already accepted
-- fiscal baja using the same private write-intent protocol as the real fiscal
-- finalizer. This fixture does NOT call SUNAT and is not fiscal approval.
INSERT INTO private.financial_nc_intents(organization_id,venta_id,nota_credito_id,tx_id)
SELECT f.org,(f.result20->>'venta_id')::bigint,n.id,pg_catalog.pg_current_xact_id()
FROM _2db_fixture f CROSS JOIN _2dd_nc n;
UPDATE public.notas_credito SET estado_baja_tributaria='aceptada',
 baja_aceptada_at=clock_timestamp()
WHERE id=(SELECT id FROM _2dd_nc);
DELETE FROM private.financial_nc_intents WHERE nota_credito_id=(SELECT id FROM _2dd_nc)
 AND tx_id=pg_catalog.pg_current_xact_id();
SELECT ok((SELECT cf.exigible=100 AND cf.cobros_netos=0 AND cf.saldo_pendiente=100
 FROM public.venta_cuentas_financieras cf CROSS JOIN _2db_fixture f
 WHERE cf.organization_id=f.org AND cf.venta_id=(f.result20->>'venta_id')::bigint),
 'internal fiscal baja compensation restores canonical 100 PEN');
SELECT ok((SELECT count(*)=1 AND SUM(e.delta_exigible)=30
 FROM public.venta_eventos_financieros e CROSS JOIN _2db_fixture f
 WHERE e.organization_id=f.org AND e.venta_id=(f.result20->>'venta_id')::bigint
 AND e.tipo='reversion_ajuste' AND e.nota_credito_id=(SELECT id FROM _2dd_nc)),
 'baja compensation is exactly one +30 audited event');
SELECT ok((SELECT COUNT(*)=3 AND SUM(c.importe_vigente)=100
 FROM public.venta_cuotas c CROSS JOIN _2dc_results r
 WHERE c.cronograma_id=(r.reversed->>'schedule_id')::uuid),
 'baja restores exact certified v2 quota principal');
SELECT ok((SELECT COUNT(*)=2 AND SUM(c.importe_vigente)=80
 FROM public.venta_cuotas c CROSS JOIN _2dc_results r
 WHERE c.cronograma_id=(r.reversed->>'previous_schedule_id')::uuid),
 'baja never alters v1 historical installments');
SELECT ok((SELECT a.apta_para_motor AND a.saldo_calculado=100
 FROM private.financial_2c_audit_sale(
   (SELECT org FROM _2db_fixture),
   (SELECT (result20->>'venta_id')::bigint FROM _2db_fixture)) a),
 'baja canonical audit remains reconciled');
SELECT ok((SELECT count(*)=1 FROM public.venta_cronogramas cr CROSS JOIN _2db_fixture f
 WHERE cr.organization_id=f.org AND cr.venta_id=(f.result20->>'venta_id')::bigint
 AND cr.version=2 AND cr.estado='vigente'),
 'baja retains one certified active v2 schedule');
SELECT * FROM finish();
ROLLBACK;
