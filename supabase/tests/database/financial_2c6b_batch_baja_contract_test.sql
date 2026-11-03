-- 2C6B: aceptación y baja atómicas; fixtures sintéticos, todo termina en ROLLBACK.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
CREATE TEMP TABLE _fin2c2_f (
  org_a uuid, org_b uuid,
  sale_a bigint, sale_b bigint,
  request_a uuid, request_b uuid,
  payment_at timestamptz,
  payment_a bigint,
  op_a uuid
) ON COMMIT DROP;
INSERT INTO _fin2c2_f(org_a,org_b,sale_a,sale_b,request_a,request_b,payment_at)
 VALUES (gen_random_uuid(),gen_random_uuid(),-840030001,-840030002,
 gen_random_uuid(),gen_random_uuid(),now()-interval '1 hour');
SET LOCAL session_replication_role=replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org_a,'2C2 org A','PE','PEN','America/Lima' FROM _fin2c2_f
UNION ALL SELECT org_b,'2C2 org B','PE','PEN','America/Lima' FROM _fin2c2_f;
INSERT INTO public.ventas(id,organization_id,total,saldo,estado,fecha,monto_notas_credito)
SELECT sale_a,org_a,100,100,'pendiente',now()-interval '1 day',0 FROM _fin2c2_f
UNION ALL SELECT sale_b,org_b,50,50,'pendiente',now()-interval '1 day',0 FROM _fin2c2_f;
SET LOCAL session_replication_role=origin;
INSERT INTO public.venta_cuentas_financieras(
 organization_id,venta_id,moneda,estado_conciliacion,
 exigible,cobros_netos,saldo_pendiente,revision)
SELECT org_a,sale_a,'PEN','conciliada',100,0,100,1 FROM _fin2c2_f
UNION ALL SELECT org_b,sale_b,'PEN','conciliada',50,0,50,1 FROM _fin2c2_f;
WITH ins AS (
 INSERT INTO public.venta_operaciones_financieras(
  organization_id,venta_id,tipo,request_id,payload_hash,resultado,metadata_apertura)
 SELECT org_a,sale_a,'apertura',gen_random_uuid(),'fixture-open-a','aplicado',
   '{"cobertura":"historico_auditado"}'::jsonb FROM _fin2c2_f
 UNION ALL
 SELECT org_b,sale_b,'apertura',gen_random_uuid(),'fixture-open-b','aplicado',
   '{"cobertura":"historico_auditado"}'::jsonb FROM _fin2c2_f
 RETURNING id,organization_id,venta_id
)
INSERT INTO public.venta_eventos_financieros(
 organization_id,venta_id,operacion_id,secuencia,tipo,delta_exigible,delta_cobros,efectivo_at)
 SELECT o.organization_id,o.venta_id,o.id,1,'apertura',
        CASE WHEN o.venta_id=-840030001 THEN 100 ELSE 50 END,
        0,now()-interval '1 day'
 FROM ins o;


CREATE TEMP TABLE _refund_fixture(actor_admin uuid,actor_operator uuid,actor_other uuid,
 nc_ok uuid,nc_pending uuid,nc_over uuid,req uuid) ON COMMIT DROP;
INSERT INTO _refund_fixture VALUES(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid());
SET LOCAL session_replication_role=replica;
INSERT INTO auth.users(id,aud,role)
SELECT actor_admin,'authenticated','authenticated' FROM _refund_fixture
UNION ALL SELECT actor_operator,'authenticated','authenticated' FROM _refund_fixture
UNION ALL SELECT actor_other,'authenticated','authenticated' FROM _refund_fixture;
INSERT INTO public.app_users(user_id,organization_id,status,base_role)
SELECT x.actor_admin,f.org_a,'active','admin' FROM _refund_fixture x CROSS JOIN _fin2c2_f f
UNION ALL SELECT x.actor_operator,f.org_a,'active','operador' FROM _refund_fixture x CROSS JOIN _fin2c2_f f
UNION ALL SELECT x.actor_other,f.org_b,'active','admin' FROM _refund_fixture x CROSS JOIN _fin2c2_f f;
SET LOCAL session_replication_role=origin;
CREATE TEMP TABLE _nc_schedule(id uuid) ON COMMIT DROP;
INSERT INTO _nc_schedule VALUES(gen_random_uuid());
INSERT INTO public.venta_cronogramas(id,organization_id,venta_id,version,estado,origen_evento_id)
SELECT s.id,f.org_a,f.sale_a,1,'vigente',ev.id FROM _nc_schedule s CROSS JOIN _fin2c2_f f
JOIN public.venta_eventos_financieros ev ON ev.organization_id=f.org_a AND ev.venta_id=f.sale_a AND ev.tipo='apertura';
INSERT INTO public.venta_cuotas(organization_id,venta_id,cronograma_id,numero,vencimiento,importe_original,importe_vigente)
SELECT f.org_a,f.sale_a,s.id,n,(now() AT TIME ZONE 'America/Lima')::date+10,
CASE WHEN n=3 THEN 33.34 ELSE 33.33 END,CASE WHEN n=3 THEN 33.34 ELSE 33.33 END
FROM _fin2c2_f f CROSS JOIN _nc_schedule s CROSS JOIN generate_series(1,3) n;

DO $pay$
DECLARE f _fin2c2_f%ROWTYPE; r jsonb;
BEGIN
 SELECT * INTO f FROM _fin2c2_f;
 r:=private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,f.request_a,'PEN',40,f.payment_at);
 IF (r->>'saldo')::numeric<>60 THEN RAISE EXCEPTION 'Fixture payment failed'; END IF;
PERFORM private.financial_2c2_record_transfer_payment(f.org_b,f.sale_b,f.request_b,'PEN',50,f.payment_at);
END $pay$;
SET LOCAL session_replication_role=replica;
INSERT INTO public.comprobantes_electronicos(id,organization_id,venta_id,tipo_documento_sunat,serie,correlativo,fecha_emision,estado,total)
SELECT request_a,org_a,sale_a,'01','F001',1,current_date,'aceptado',100 FROM _fin2c2_f
UNION ALL SELECT request_b,org_b,sale_b,'01','F001',1,current_date,'aceptado',50 FROM _fin2c2_f;
INSERT INTO public.notas_credito(
 id,request_id,comprobante_id,venta_id,tipo_origen,tipo_doc_afectado,
 serie_afectada,correlativo_afectado,motivo_codigo,motivo_descripcion,
 serie,correlativo,fecha_emision,fecha_emision_ts,
 organization_id,moneda,estado,afecta_dinero,total,aceptado_at
)
SELECT items.id,gen_random_uuid(),f.request_a,f.sale_a,
 'venta','01','F001',1,'01','NC de fixture',
 'FC01',items.n,(now() AT TIME ZONE 'America/Lima')::date,
 now()-interval '10 minutes',f.org_a,'PEN',
 items.status,true,items.amount,items.accepted
FROM _refund_fixture x CROSS JOIN _fin2c2_f f
CROSS JOIN LATERAL (VALUES
 (x.nc_ok,1::bigint,'pendiente_envio'::text,70::numeric,NULL::timestamptz),
 (x.nc_pending,2::bigint,'pendiente_envio'::text,15::numeric,NULL::timestamptz),
 (x.nc_over,3::bigint,'pendiente_envio'::text,150::numeric,now()-interval '10 minutes')
) items(id,n,status,amount,accepted);
SET LOCAL session_replication_role=origin;

SET LOCAL session_replication_role=replica;
INSERT INTO public.notas_credito(
id,request_id,comprobante_id,venta_id,tipo_origen,tipo_doc_afectado,serie_afectada,correlativo_afectado,
motivo_codigo,motivo_descripcion,serie,correlativo,fecha_emision,fecha_emision_ts,organization_id,
moneda,estado,afecta_dinero,total,aceptado_at)
SELECT x.req,gen_random_uuid(),f.request_b,f.sale_b,'venta','01','F001',1,'01','NC fixture B',
'FC01',1,(now() AT TIME ZONE 'America/Lima')::date,now()-interval '10 minutes',f.org_b,
'PEN','pendiente_envio',true,20,NULL::timestamptz FROM _refund_fixture x CROSS JOIN _fin2c2_f f;
SET LOCAL session_replication_role=origin;
SELECT set_config('request.jwt.claim.sub',(SELECT actor_admin::text FROM _refund_fixture),true);

SELECT set_config('request.headers',jsonb_build_object('x-stomni-organization-id',(SELECT org_a FROM _fin2c2_f))::text,true);
SELECT public.nota_credito_finalizar((SELECT nc_ok FROM _refund_fixture),NULL,'aceptado','{}');
SELECT public.nota_credito_finalizar((SELECT nc_pending FROM _refund_fixture),NULL,'aceptado','{}');
CREATE TEMP TABLE _baja(id uuid, solicitud uuid) ON COMMIT DROP;
INSERT INTO _baja VALUES(gen_random_uuid(),gen_random_uuid());
INSERT INTO public.procesos_tributarios(id,organization_id,request_id,tipo_proceso,fecha_referencia,fecha_comunicacion,correlativo,identificador)
SELECT b.id,f.org_a,gen_random_uuid(),'comunicacion_baja',current_date,current_date,1,'RA-fixture' FROM _baja b CROSS JOIN _fin2c2_f f;
INSERT INTO public.solicitudes_baja_tributaria(id,organization_id,request_id,tipo_origen,nota_credito_id,venta_id,tipo_proceso,tipo_doc,serie,correlativo,fecha_documento,motivo,proceso_id)
SELECT b.solicitud,f.org_a,gen_random_uuid(),'nota_credito',x.nc_ok,f.sale_a,'comunicacion_baja','07','FC01',1,current_date,'Fixture baja',b.id FROM _baja b CROSS JOIN _fin2c2_f f CROSS JOIN _refund_fixture x;
INSERT INTO public.procesos_tributarios_detalles(organization_id,proceso_id,solicitud_id,tipo_origen,nota_credito_id,venta_id,tipo_doc,serie,correlativo,serie_numero,motivo)
SELECT f.org_a,b.id,b.solicitud,'nota_credito',x.nc_ok,f.sale_a,'07','FC01',1,'FC01-1','Fixture baja' FROM _baja b CROSS JOIN _fin2c2_f f CROSS JOIN _refund_fixture x;


INSERT INTO public.solicitudes_baja_tributaria(organization_id,request_id,tipo_origen,nota_credito_id,venta_id,tipo_proceso,tipo_doc,serie,correlativo,fecha_documento,motivo,proceso_id)
SELECT f.org_a,gen_random_uuid(),'nota_credito',x.nc_pending,f.sale_a,'comunicacion_baja','07','FC01',2,current_date,'Fixture baja batch',b.id FROM _baja b CROSS JOIN _fin2c2_f f CROSS JOIN _refund_fixture x;
INSERT INTO public.procesos_tributarios_detalles(organization_id,proceso_id,solicitud_id,tipo_origen,nota_credito_id,venta_id,tipo_doc,serie,correlativo,serie_numero,motivo)
SELECT s.organization_id,s.proceso_id,s.id,s.tipo_origen,s.nota_credito_id,s.venta_id,s.tipo_doc,s.serie,s.correlativo,'FC01-2',s.motivo FROM public.solicitudes_baja_tributaria s WHERE s.nota_credito_id=(SELECT nc_pending FROM _refund_fixture);
SELECT public.tributario_finalizar_proceso((SELECT id FROM _baja),NULL,'aceptado','{}');
SELECT plan(5);
SELECT ok((SELECT exigible=100 AND cobros_netos=40 AND saldo_pendiente=60 AND excedente=0 FROM public.venta_cuentas_financieras WHERE organization_id=(SELECT org_a FROM _fin2c2_f)),'batch restaura exigible completo');
SELECT ok((SELECT sum(saldo_pendiente)=60 FROM private.financial_2c4_installments((SELECT org_a FROM _fin2c2_f),(SELECT sale_a FROM _fin2c2_f),NULL)),'batch concilia cuotas');
SELECT ok((SELECT count(*)=2 FROM public.venta_eventos_financieros WHERE organization_id=(SELECT org_a FROM _fin2c2_f) AND tipo='reversion_ajuste'),'una compensación por NC del batch');
SELECT ok((SELECT apta_para_motor FROM private.financial_2c_audit_sale((SELECT org_a FROM _fin2c2_f),(SELECT sale_a FROM _fin2c2_f))),'auditoría final del batch');
SELECT ok((SELECT count(*)=0 FROM private.financial_nc_intents),'batch limpia intenciones');
SELECT * FROM finish();
ROLLBACK;
