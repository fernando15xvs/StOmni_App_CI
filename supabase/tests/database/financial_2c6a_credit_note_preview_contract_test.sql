-- 2C5B-A: solicitudes pendientes de devolución. Datos reversibles.
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
INSERT INTO public.notas_credito(
 id,request_id,comprobante_id,venta_id,tipo_origen,tipo_doc_afectado,
 serie_afectada,correlativo_afectado,motivo_codigo,motivo_descripcion,
 serie,correlativo,fecha_emision,fecha_emision_ts,
 organization_id,moneda,estado,afecta_dinero,total,aceptado_at
)
SELECT items.id,gen_random_uuid(),gen_random_uuid(),f.sale_a,
 'venta','01','F001',1,'01','NC de fixture',
 'FC01',items.n,(now() AT TIME ZONE 'America/Lima')::date,
 now()-interval '10 minutes',f.org_a,'PEN',
 items.status,true,items.amount,items.accepted
FROM _refund_fixture x CROSS JOIN _fin2c2_f f
CROSS JOIN LATERAL (VALUES
 (x.nc_ok,1::bigint,'aceptado'::text,20::numeric,now()-interval '10 minutes'),
 (x.nc_pending,2::bigint,'pendiente_envio'::text,15::numeric,NULL::timestamptz),
 (x.nc_over,3::bigint,'pendiente_envio'::text,150::numeric,now()-interval '10 minutes')
) items(id,n,status,amount,accepted);
SET LOCAL session_replication_role=origin;

SET LOCAL session_replication_role=replica;
INSERT INTO public.notas_credito(
id,request_id,comprobante_id,venta_id,tipo_origen,tipo_doc_afectado,serie_afectada,correlativo_afectado,
motivo_codigo,motivo_descripcion,serie,correlativo,fecha_emision,fecha_emision_ts,organization_id,
moneda,estado,afecta_dinero,total,aceptado_at)
SELECT x.req,gen_random_uuid(),gen_random_uuid(),f.sale_b,'venta','01','F001',1,'01','NC fixture B',
'FC01',1,(now() AT TIME ZONE 'America/Lima')::date,now()-interval '10 minutes',f.org_b,
'PEN','aceptado',true,20,now()-interval '10 minutes' FROM _refund_fixture x CROSS JOIN _fin2c2_f f;
SET LOCAL session_replication_role=origin;
SELECT set_config('request.jwt.claim.sub',(SELECT actor_admin::text FROM _refund_fixture),true);
CREATE FUNCTION pg_temp.preview_nc() RETURNS jsonb LANGUAGE sql AS $$
 SELECT private.financial_2c6a_preview_credit_note(f.org_a,f.sale_a,x.nc_ok)
 FROM _fin2c2_f f CROSS JOIN _refund_fixture x;
$$;
CREATE FUNCTION pg_temp.preview_error() RETURNS text LANGUAGE plpgsql AS $$
BEGIN
 PERFORM pg_temp.preview_nc(); RETURN 'no_error';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE;
END $$;
CREATE TEMP TABLE _nc_snapshot AS
SELECT 'cuentas' as k,to_jsonb(c) as row FROM public.venta_cuentas_financieras c JOIN _fin2c2_f f ON c.organization_id=f.org_a
UNION ALL SELECT 'eventos',to_jsonb(e) FROM public.venta_eventos_financieros e JOIN _fin2c2_f f ON e.organization_id=f.org_a
UNION ALL SELECT 'movimientos',to_jsonb(m) FROM public.venta_cuota_movimientos m JOIN _fin2c2_f f ON m.organization_id=f.org_a;

CREATE FUNCTION pg_temp.check_mutation(p_sql text,p_check text) RETURNS boolean LANGUAGE plpgsql AS $checkfn$
DECLARE passed boolean;
BEGIN
 BEGIN
  EXECUTE p_sql;
  EXECUTE 'SELECT '||p_check INTO passed;
  RAISE EXCEPTION USING ERRCODE='ZX001', MESSAGE='rollback fixture scenario';
 EXCEPTION WHEN SQLSTATE 'ZX001' THEN NULL;
 END;
 RETURN passed;
END $checkfn$;

CREATE TEMP TABLE _nc_tap(line text) ON COMMIT DROP;
SELECT plan(32);
INSERT INTO _nc_tap SELECT ok(((pg_temp.preview_nc()->>'saldo_propuesto')::numeric=40 AND (pg_temp.preview_nc()->>'exigible_propuesto')::numeric=80), 'NC 20 reduce deuda 60 a 40');
INSERT INTO _nc_tap SELECT ok((pg_temp.preview_nc()->'reducciones_cuotas'->0->>'numero'='3'), 'empate vencimientos reduce numero mayor');
INSERT INTO _nc_tap SELECT ok(((pg_temp.preview_nc()->'reducciones_cuotas'->0->>'saldo_propuesto')::numeric=13.34), 'centavos exactos ultima cuota');
INSERT INTO _nc_tap SELECT ok((pg_temp.preview_nc()->>'aplicado'='false' AND pg_temp.preview_nc()->>'autoriza_escritura'='false' AND pg_temp.preview_nc()->>'dinero_entregado'='false' AND pg_temp.preview_nc()->>'excedente_reservado'='false'), 'simulacion sin permiso ni fondos');
INSERT INTO _nc_tap SELECT ok((pg_temp.preview_nc()=pg_temp.preview_nc()), 'repetir preview es estable');
INSERT INTO _nc_tap SELECT ok(((SELECT NOT apta_para_motor AND 'nc_pendiente_motor_canonico'=ANY(bloqueos) FROM private.financial_2c_audit_sale((SELECT org_a FROM _fin2c2_f),(SELECT sale_a FROM _fin2c2_f)))), 'guardia compartida NC sigue bloqueada');
SELECT set_config('request.jwt.claim.sub',(SELECT actor_other::text FROM _refund_fixture),true);
INSERT INTO _nc_tap SELECT ok((SELECT (r->>'exigible_propuesto')::numeric=30 AND (r->>'cobros_netos_sin_cambio')::numeric=50
AND (r->>'saldo_propuesto')::numeric=0 AND (r->>'excedente_propuesto')::numeric=20 AND r->>'sin_cronograma'='true'
FROM (SELECT private.financial_2c6a_preview_credit_note(f.org_b,f.sale_b,x.req) r FROM _fin2c2_f f CROSS JOIN _refund_fixture x) q),'venta pagada conserva excedente sin inventar cuotas');
INSERT INTO _nc_tap SELECT is(pg_temp.preview_error(),'42501','admin otra empresa rechazado');
SELECT set_config('request.jwt.claim.sub',(SELECT actor_operator::text FROM _refund_fixture),true);
INSERT INTO _nc_tap SELECT is(pg_temp.preview_error(),'42501','operador rechazado');
SELECT set_config('request.jwt.claim.sub','',true);
INSERT INTO _nc_tap SELECT is(pg_temp.preview_error(),'22023','JWT requerido');
SELECT set_config('request.jwt.claim.sub',(SELECT actor_admin::text FROM _refund_fixture),true);
SET LOCAL session_replication_role=replica;
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.notas_credito SET total=70 WHERE id=(SELECT nc_ok FROM _refund_fixture);$mut$,$check$((pg_temp.preview_nc()->>'saldo_propuesto')::numeric=0 AND (pg_temp.preview_nc()->>'excedente_propuesto')::numeric=10 AND jsonb_array_length(pg_temp.preview_nc()->'reducciones_cuotas')=2)$check$),'NC mayor deuda conserva excedente y pagos');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.notas_credito SET total=100.01 WHERE id=(SELECT nc_ok FROM _refund_fixture);$mut$,$check$pg_temp.preview_error()='23514'$check$),'NC no puede superar exigible por centavo');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.notas_credito SET estado='pendiente_envio' WHERE id=(SELECT nc_ok FROM _refund_fixture);$mut$,$check$pg_temp.preview_error()='23514'$check$),'NC pendiente bloqueada');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.notas_credito SET estado='rechazado' WHERE id=(SELECT nc_ok FROM _refund_fixture);$mut$,$check$pg_temp.preview_error()='23514'$check$),'NC rechazada bloqueada');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.notas_credito SET afecta_dinero=false WHERE id=(SELECT nc_ok FROM _refund_fixture);$mut$,$check$pg_temp.preview_error()='23514'$check$),'NC no monetaria bloqueada');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.notas_credito SET estado_baja_tributaria='aceptada' WHERE id=(SELECT nc_ok FROM _refund_fixture);$mut$,$check$pg_temp.preview_error()='23514'$check$),'NC con baja bloqueada');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.notas_credito SET baja_aceptada_at=now() WHERE id=(SELECT nc_ok FROM _refund_fixture);$mut$,$check$pg_temp.preview_error()='23514'$check$),'baja aceptada inconsistente bloqueada');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.notas_credito SET aceptado_at=NULL WHERE id=(SELECT nc_ok FROM _refund_fixture);$mut$,$check$pg_temp.preview_error()='23514'$check$),'sin fecha aceptacion bloqueada');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.notas_credito SET aceptado_at=now()+interval '1 day' WHERE id=(SELECT nc_ok FROM _refund_fixture);$mut$,$check$pg_temp.preview_error()='23514'$check$),'aceptacion futura bloqueada');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.notas_credito SET moneda='USD' WHERE id=(SELECT nc_ok FROM _refund_fixture);$mut$,$check$pg_temp.preview_error()='23514'$check$),'no convertir moneda');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.notas_credito SET venta_id=(SELECT sale_b FROM _fin2c2_f) WHERE id=(SELECT nc_ok FROM _refund_fixture);$mut$,$check$pg_temp.preview_error()='23514'$check$),'vinculo NC venta empresa incorrecto bloqueado');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.venta_cuentas_financieras SET cobros_netos=41,saldo_pendiente=59 WHERE organization_id=(SELECT org_a FROM _fin2c2_f);$mut$,$check$pg_temp.preview_error()='23514'$check$),'proyeccion divergente bloqueada');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.venta_cronogramas SET version=2 WHERE id=(SELECT id FROM _nc_schedule);$mut$,$check$pg_temp.preview_error()='23514'$check$),'version 2 bloqueada');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.venta_cronogramas SET estado='cancelado' WHERE id=(SELECT id FROM _nc_schedule);$mut$,$check$pg_temp.preview_error()='23514'$check$),'sin cronograma vigente bloqueado');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.venta_cuotas SET importe_vigente=34 WHERE organization_id=(SELECT org_a FROM _fin2c2_f) AND numero=1;$mut$,$check$pg_temp.preview_error()='23514'$check$),'suma cuotas divergente bloqueada');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.venta_cuotas SET importe_vigente=1 WHERE organization_id=(SELECT org_a FROM _fin2c2_f) AND numero=1;$mut$,$check$pg_temp.preview_error()='23514'$check$),'cuota ya pagada tambien se valida');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.notas_credito SET estado='aceptado' WHERE id=(SELECT nc_over FROM _refund_fixture);$mut$,$check$pg_temp.preview_error()='23514'$check$),'multiples NC requieren conciliacion');
INSERT INTO _nc_tap SELECT ok(pg_temp.check_mutation($mut$UPDATE public.venta_operaciones_financieras SET metadata_apertura='{}'::jsonb WHERE organization_id=(SELECT org_a FROM _fin2c2_f) AND tipo='apertura';$mut$,$check$pg_temp.preview_error()='23514'$check$),'no certifica historial automaticamente');
SET LOCAL session_replication_role=origin;
INSERT INTO _nc_tap SELECT ok((NOT EXISTS(
(SELECT * FROM _nc_snapshot EXCEPT
(SELECT 'cuentas',to_jsonb(c) FROM public.venta_cuentas_financieras c JOIN _fin2c2_f f ON c.organization_id=f.org_a
UNION ALL SELECT 'eventos',to_jsonb(e) FROM public.venta_eventos_financieros e JOIN _fin2c2_f f ON e.organization_id=f.org_a
UNION ALL SELECT 'movimientos',to_jsonb(m) FROM public.venta_cuota_movimientos m JOIN _fin2c2_f f ON m.organization_id=f.org_a))
)), 'snapshot conservado');
INSERT INTO _nc_tap SELECT ok((SELECT count(*)=0 FROM private.venta_solicitudes_devolucion WHERE organization_id IN (SELECT org_a FROM _fin2c2_f UNION ALL SELECT org_b FROM _fin2c2_f)),'sin expedientes ni reservas');
INSERT INTO _nc_tap SELECT ok((SELECT bool_and(NOT has_function_privilege(r,'private.financial_2c6a_preview_credit_note(uuid,bigint,uuid)','EXECUTE')) FROM unnest(ARRAY['anon','authenticated','service_role']) r),'sin acceso cliente ni servicio');
INSERT INTO _nc_tap SELECT ok((SELECT NOT prosecdef AND provolatile='s' FROM pg_proc WHERE oid='private.financial_2c6a_preview_credit_note(uuid,bigint,uuid)'::regprocedure),'invoker estable solo lectura');
DO $assert$
BEGIN
 IF (SELECT count(*) FROM _nc_tap)<>32 OR EXISTS (SELECT 1 FROM _nc_tap WHERE line NOT LIKE 'ok %') THEN
 RAISE EXCEPTION '2C6A failures: %',(SELECT string_agg(line,E'\n') FROM _nc_tap WHERE line NOT LIKE 'ok %');
 END IF;
END $assert$;
SELECT line FROM _nc_tap;
SELECT * FROM finish();
ROLLBACK;
