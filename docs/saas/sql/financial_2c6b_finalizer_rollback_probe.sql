-- Diagnostic regression, synthetic data only, full ROLLBACK.
-- Documents current blocked behavior; NOT acceptance criteria for completed 2C6B.
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

CREATE TEMP TABLE _finalizer_checks(name text,passed boolean);
DO $test$
DECLARE f _fin2c2_f%ROWTYPE; x _refund_fixture%ROWTYPE; r jsonb;
BEGIN
 SELECT * INTO f FROM _fin2c2_f; SELECT * INTO x FROM _refund_fixture;
 PERFORM set_config('request.headers',jsonb_build_object('x-stomni-organization-id',f.org_a)::text,true);
 r:=public.nota_credito_finalizar(x.nc_ok,gen_random_uuid(),'aceptado','{}');
 INSERT INTO _finalizer_checks VALUES('accepted retry preserves result',r->>'idempotent'='true');
 BEGIN
 PERFORM public.nota_credito_finalizar(x.nc_pending,NULL,'aceptado','{}');
 INSERT INTO _finalizer_checks VALUES('canonical guard blocks legacy finalization',false);
 EXCEPTION WHEN SQLSTATE '55000' THEN
 INSERT INTO _finalizer_checks VALUES('canonical guard blocks legacy finalization',true);
 END;
 INSERT INTO _finalizer_checks SELECT 'NC state rolls back',
 estado='pendiente_envio' AND aceptado_at IS NULL FROM public.notas_credito WHERE id=x.nc_pending;
 INSERT INTO _finalizer_checks SELECT 'account unchanged',
 exigible=100 AND cobros_netos=40 AND saldo_pendiente=60 AND excedente=0
 FROM public.venta_cuentas_financieras WHERE organization_id=f.org_a AND venta_id=f.sale_a;
 INSERT INTO _finalizer_checks SELECT 'no NC event leaked',NOT EXISTS(
 SELECT 1 FROM public.venta_eventos_financieros WHERE organization_id=f.org_a AND venta_id=f.sale_a AND tipo='nota_credito');
 PERFORM set_config('request.headers',jsonb_build_object('x-stomni-organization-id',f.org_b)::text,true);
 BEGIN
 PERFORM public.nota_credito_finalizar(x.nc_ok,gen_random_uuid(),'aceptado','{}');
 INSERT INTO _finalizer_checks VALUES('other tenant rejected',false);
 EXCEPTION WHEN raise_exception THEN
 INSERT INTO _finalizer_checks VALUES('other tenant rejected',SQLERRM='Nota de crédito no encontrada');
 END;
 IF (SELECT count(*) FROM _finalizer_checks)<>6 OR EXISTS(SELECT 1 FROM _finalizer_checks WHERE passed IS NOT TRUE)
 THEN RAISE EXCEPTION 'Finalizer regression failed: %',(SELECT jsonb_agg(to_jsonb(c)) FROM _finalizer_checks c);
 END IF;
END $test$;
SELECT plan(6);
SELECT ok(passed,name) FROM _finalizer_checks ORDER BY name;
SELECT * FROM finish();
ROLLBACK;
