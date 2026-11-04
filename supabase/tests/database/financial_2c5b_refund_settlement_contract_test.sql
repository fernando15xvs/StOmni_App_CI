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

CREATE TEMP TABLE _rf(bank_id uuid,case_id uuid,reservation_id uuid,req uuid,payload jsonb) ON COMMIT DROP;
INSERT INTO _rf VALUES(gen_random_uuid(),NULL,NULL,gen_random_uuid(),NULL);
CREATE TEMP TABLE _checks(label text) ON COMMIT DROP;
CREATE FUNCTION pg_temp.check_rf(p_ok boolean,p_label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF p_ok IS DISTINCT FROM true THEN RAISE EXCEPTION '2C5B-B: %',p_label; END IF; INSERT INTO _checks VALUES(p_label); END $$;
CREATE FUNCTION pg_temp.fail_rf(p_sql text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN EXECUTE p_sql; RETURN false; EXCEPTION WHEN OTHERS THEN RETURN true; END $$;
CREATE FUNCTION pg_temp.cmd(p_action text,p_data jsonb) RETURNS jsonb LANGUAGE sql AS $$
SELECT private.financial_refund_command((SELECT org_a FROM _fin2c2_f),gen_random_uuid(),p_action,p_data) $$;
SELECT set_config('request.headers',jsonb_build_object('x-stomni-organization-id',(SELECT org_a FROM _fin2c2_f))::text,true);
SELECT public.nota_credito_finalizar((SELECT nc_ok FROM _refund_fixture),NULL,'aceptado','{}');
UPDATE _rf SET case_id=(SELECT (private.financial_2c5b_open_refund_case(f.org_a,f.sale_a,x.nc_ok,gen_random_uuid(),10,'Devolucion documentada por NC')->>'caso_id')::uuid FROM _fin2c2_f f CROSS JOIN _refund_fixture x);
SELECT pg_temp.check_rf(pg_temp.fail_rf($q$SELECT pg_temp.cmd('reserve',jsonb_build_object('case_id',case_id,'amount',10.001)) FROM _rf$q$),'fracciones de centavo rechazadas');
SELECT pg_temp.check_rf(pg_temp.fail_rf($q$SELECT pg_temp.cmd('reserve',jsonb_build_object('case_id',case_id,'amount',11)) FROM _rf$q$),'reserva no supera excedente ni expediente');
UPDATE _rf SET payload=jsonb_build_object('case_id',case_id,'amount',8);
UPDATE _rf SET reservation_id=(SELECT (private.financial_refund_command(f.org_a,r.req,'reserve',r.payload)->>'reservation_id')::uuid FROM _fin2c2_f f CROSS JOIN _rf r);
SELECT pg_temp.check_rf((SELECT (private.financial_refund_command(f.org_a,r.req,'reserve',r.payload)->>'idempotent')::boolean FROM _fin2c2_f f CROSS JOIN _rf r),'reserva idempotente');
SELECT pg_temp.check_rf(pg_temp.fail_rf($q$SELECT private.financial_refund_command(f.org_a,r.req,'reserve',r.payload||'{"amount":7}') FROM _fin2c2_f f CROSS JOIN _rf r$q$),'request distinto rechazado');
SELECT pg_temp.check_rf(pg_temp.fail_rf($q$SELECT pg_temp.cmd('reserve',jsonb_build_object('case_id',case_id,'amount',1)) FROM _rf$q$),'expediente no admite doble reserva activa');
SELECT pg_temp.check_rf((SELECT (private.financial_refund_status(org_a,sale_a)->>'available')::numeric=2 FROM _fin2c2_f),'lectura distingue excedente reservado y disponible');
SELECT pg_temp.check_rf((SELECT excedente=10 AND cobros_netos=40 FROM public.venta_cuentas_financieras WHERE organization_id=(SELECT org_a FROM _fin2c2_f)),'reservar no entrega dinero');
CREATE TEMP TABLE _baja(id uuid, solicitud uuid) ON COMMIT DROP;
INSERT INTO _baja VALUES(gen_random_uuid(),gen_random_uuid());
INSERT INTO public.procesos_tributarios(id,organization_id,request_id,tipo_proceso,fecha_referencia,fecha_comunicacion,correlativo,identificador)
SELECT b.id,f.org_a,gen_random_uuid(),'comunicacion_baja',current_date,current_date,1,'RA-fixture' FROM _baja b CROSS JOIN _fin2c2_f f;
INSERT INTO public.solicitudes_baja_tributaria(id,organization_id,request_id,tipo_origen,nota_credito_id,venta_id,tipo_proceso,tipo_doc,serie,correlativo,fecha_documento,motivo,proceso_id)
SELECT b.solicitud,f.org_a,gen_random_uuid(),'nota_credito',x.nc_ok,f.sale_a,'comunicacion_baja','07','FC01',1,current_date,'Fixture baja',b.id FROM _baja b CROSS JOIN _fin2c2_f f CROSS JOIN _refund_fixture x;
INSERT INTO public.procesos_tributarios_detalles(organization_id,proceso_id,solicitud_id,tipo_origen,nota_credito_id,venta_id,tipo_doc,serie,correlativo,serie_numero,motivo)
SELECT f.org_a,b.id,b.solicitud,'nota_credito',x.nc_ok,f.sale_a,'07','FC01',1,'FC01-1','Fixture baja' FROM _baja b CROSS JOIN _fin2c2_f f CROSS JOIN _refund_fixture x;


SELECT pg_temp.check_rf(pg_temp.fail_rf($q$SELECT public.tributario_finalizar_proceso((SELECT id FROM _baja),NULL,'aceptado','{}')$q$),'baja no consume excedente reservado');
SELECT pg_temp.check_rf((SELECT estado='pendiente_envio' FROM public.procesos_tributarios WHERE id=(SELECT id FROM _baja)),'baja bloqueada restaura estado fiscal');
SELECT pg_temp.check_rf(pg_temp.fail_rf($q$SELECT pg_temp.cmd('settle',jsonb_build_object('reservation_id',reservation_id,'bank_id',bank_id,'effective_at',clock_timestamp(),'evidence_ref','pago-sin-prueba')) FROM _rf$q$),'no liquida sin evidencia');
SELECT pg_temp.check_rf(pg_temp.fail_rf($q$SELECT pg_temp.cmd('settle',jsonb_build_object('reservation_id',reservation_id,'bank_id',bank_id,'effective_at',clock_timestamp(),'evidence_ref','pago-sin-fondos','evidence_sha256',repeat('a',64))) FROM _rf$q$),'no liquida banco no conciliado');
SELECT pg_temp.cmd('bank_reconcile',jsonb_build_object('bank_id',bank_id,'balance',5,'effective_at',clock_timestamp(),'evidence_ref','extracto-001','evidence_sha256',repeat('a',64))) FROM _rf;
SELECT pg_temp.check_rf(pg_temp.fail_rf($q$SELECT pg_temp.cmd('settle',jsonb_build_object('reservation_id',reservation_id,'bank_id',bank_id,'effective_at',clock_timestamp(),'evidence_ref','pago-insuficiente','evidence_sha256',repeat('b',64))) FROM _rf$q$),'fondos insuficientes sin egreso');
SELECT pg_temp.check_rf((SELECT balance=5 FROM private.refund_bank_accounts WHERE id=(SELECT bank_id FROM _rf)),'fallo no cambia saldo bancario');
SELECT pg_temp.cmd('bank_reconcile',jsonb_build_object('bank_id',bank_id,'balance',50,'effective_at',clock_timestamp(),'evidence_ref','extracto-002','evidence_sha256',repeat('a',64))) FROM _rf;
SELECT pg_temp.check_rf(pg_temp.fail_rf($q$SELECT pg_temp.cmd('settle',jsonb_build_object('reservation_id',reservation_id,'bank_id',bank_id,'effective_at',clock_timestamp(),'evidence_ref','extracto-002','evidence_sha256',repeat('b',64))) FROM _rf$q$),'evidencia ya usada revierte liquidación tras crear evento');
SELECT pg_temp.check_rf((SELECT count(*)=0 FROM public.venta_eventos_financieros WHERE tipo='devolucion' AND organization_id=(SELECT org_a FROM _fin2c2_f)),'fallo tardío no deja evento financiero');
SELECT pg_temp.check_rf((SELECT state='held' FROM private.refund_reservations WHERE id=(SELECT reservation_id FROM _rf)),'fallo tardío conserva reserva');
SELECT pg_temp.check_rf((SELECT balance=50 FROM private.refund_bank_accounts WHERE id=(SELECT bank_id FROM _rf)),'fallo tardío conserva fondos');
UPDATE _rf SET req=gen_random_uuid(),payload=jsonb_build_object('reservation_id',reservation_id,'bank_id',bank_id,'effective_at',clock_timestamp(),'evidence_ref','transferencia-001','evidence_sha256',repeat('b',64));
SELECT private.financial_refund_command(f.org_a,r.req,'settle',r.payload) FROM _fin2c2_f f CROSS JOIN _rf r;
SELECT pg_temp.check_rf((SELECT balance=42 FROM private.refund_bank_accounts WHERE id=(SELECT bank_id FROM _rf)),'liquidación registra egreso bancario exacto');
SELECT pg_temp.check_rf((SELECT exigible=30 AND cobros_netos=32 AND saldo_pendiente=0 AND excedente=2 FROM public.venta_cuentas_financieras WHERE organization_id=(SELECT org_a FROM _fin2c2_f)),'liquidación reduce excedente y cobros netos');
SELECT pg_temp.check_rf((SELECT sum(monto)=40 FROM public.pagos_venta WHERE organization_id=(SELECT org_a FROM _fin2c2_f)),'no borra pagos originales');
SELECT pg_temp.check_rf((SELECT (private.financial_refund_command(f.org_a,r.req,'settle',r.payload)->>'idempotent')::boolean FROM _fin2c2_f f CROSS JOIN _rf r),'liquidación repetida no desembolsa dos veces');
SELECT pg_temp.check_rf(pg_temp.fail_rf($q$SELECT pg_temp.cmd('settle',payload) FROM _rf$q$),'otra solicitud no duplica liquidación');
SELECT public.tributario_finalizar_proceso((SELECT id FROM _baja),NULL,'aceptado','{}');
SELECT pg_temp.check_rf((SELECT exigible=100 AND cobros_netos=32 AND saldo_pendiente=68 FROM public.venta_cuentas_financieras WHERE organization_id=(SELECT org_a FROM _fin2c2_f)),'baja posterior a devolución genera deuda real');
UPDATE _rf SET req=gen_random_uuid(),payload=jsonb_build_object('reservation_id',reservation_id,'effective_at',clock_timestamp(),'evidence_ref','retorno-001','evidence_sha256',repeat('c',64));
SELECT private.financial_refund_command(f.org_a,r.req,'reverse',r.payload) FROM _fin2c2_f f CROSS JOIN _rf r;
SELECT pg_temp.check_rf((SELECT balance=50 FROM private.refund_bank_accounts WHERE id=(SELECT bank_id FROM _rf)),'retorno acreditado compensa egreso');
SELECT pg_temp.check_rf((SELECT cobros_netos=40 AND saldo_pendiente=60 AND excedente=0 FROM public.venta_cuentas_financieras WHERE organization_id=(SELECT org_a FROM _fin2c2_f)),'retorno compensa deuda reabierta');
SELECT pg_temp.check_rf((SELECT sum(saldo_pendiente)=60 FROM private.financial_2c4_installments((SELECT org_a FROM _fin2c2_f),(SELECT sale_a FROM _fin2c2_f),NULL)),'retorno reasigna cuotas tras baja');
SELECT pg_temp.check_rf((SELECT (private.financial_refund_command(f.org_a,r.req,'reverse',r.payload)->>'idempotent')::boolean FROM _fin2c2_f f CROSS JOIN _rf r),'retorno idempotente');
SELECT pg_temp.check_rf(pg_temp.fail_rf($q$SELECT pg_temp.cmd('reverse',payload) FROM _rf$q$),'no duplica retorno con otro request');
SELECT pg_temp.check_rf((SELECT apta_para_motor FROM private.financial_2c_audit_sale((SELECT org_a FROM _fin2c2_f),(SELECT sale_a FROM _fin2c2_f))),'auditoría financiera incluye devoluciones y retornos');
SELECT pg_temp.check_rf(pg_temp.fail_rf($q$UPDATE private.refund_fund_movements SET delta=1$q$),'historial de fondos inmutable');
SELECT pg_temp.check_rf((SELECT bool_and(NOT has_function_privilege(r,'private.financial_refund_command(uuid,uuid,text,jsonb)','EXECUTE')) FROM unnest(ARRAY['anon','authenticated','service_role']) r),'sin acceso API de cliente o servicio');
SELECT pg_temp.check_rf((SELECT count(*)=0 FROM private.refund_write_intents),'sin intención de escritura residual');
SELECT '1..'||count(*) FROM _checks;
SELECT 'ok '||row_number() OVER()||' - '||label FROM _checks;
ROLLBACK;
