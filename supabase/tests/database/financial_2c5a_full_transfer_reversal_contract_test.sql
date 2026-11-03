-- 2C5A: reversos contables inmutables de transferencias. Fixtures reversibles.
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


CREATE TEMP TABLE _c5(
  req_a uuid,req_b uuid,req_c uuid,req_d uuid,req_wrong uuid,rev_req uuid,
  orig_a uuid,orig_b uuid,orig_c uuid,rev_event uuid
) ON COMMIT DROP;
INSERT INTO _c5(req_a,req_b,req_c,req_d,req_wrong,rev_req)
 VALUES(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid());

WITH cr AS (
 INSERT INTO public.venta_cronogramas(organization_id,venta_id,version,estado)
 SELECT org_a,sale_a,1,'vigente' FROM _fin2c2_f
 RETURNING id,organization_id,venta_id
)
INSERT INTO public.venta_cuotas(organization_id,venta_id,cronograma_id,
 numero,vencimiento,importe_original,importe_vigente)
SELECT cr.organization_id,cr.venta_id,cr.id,q.n,
 (now() AT TIME ZONE 'America/Lima')::date+q.n,q.amount,q.amount
FROM cr CROSS JOIN (VALUES(1,33.33::numeric),(2,33.33::numeric),(3,33.34::numeric)) q(n,amount);

CREATE TEMP TABLE _c5_checks(name text PRIMARY KEY,passed boolean NOT NULL) ON COMMIT DROP;
DO $cases$
DECLARE
 f _fin2c2_f%ROWTYPE;
 k _c5%ROWTYPE;
 r jsonb; again jsonb; tmp uuid;
BEGIN
 SELECT * INTO f FROM _fin2c2_f;
 SELECT * INTO k FROM _c5;
 r:=private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,k.req_a,'PEN',50,f.payment_at);
 UPDATE _c5 SET orig_a=(SELECT id FROM public.venta_eventos_financieros
   WHERE organization_id=f.org_a AND venta_id=f.sale_a AND operacion_id=(r->>'operacion_id')::uuid);
 r:=private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,k.req_b,'PEN',30,f.payment_at);
 UPDATE _c5 SET orig_b=(SELECT id FROM public.venta_eventos_financieros
   WHERE organization_id=f.org_a AND venta_id=f.sale_a AND operacion_id=(r->>'operacion_id')::uuid);
 r:=private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,k.req_c,'PEN',20,f.payment_at);
 UPDATE _c5 SET orig_c=(SELECT id FROM public.venta_eventos_financieros
   WHERE organization_id=f.org_a AND venta_id=f.sale_a AND operacion_id=(r->>'operacion_id')::uuid);
 SELECT * INTO k FROM _c5;
 INSERT INTO _c5_checks VALUES('initial_100_paid',
  (SELECT a.apta_para_motor AND a.saldo_calculado=0 AND a.cobros_eventos=100
   FROM private.financial_2c_audit_sale(f.org_a,f.sale_a) a));

 BEGIN
  PERFORM private.financial_2c5a_reverse_transfer_payment(
    f.org_b,f.sale_b,k.req_wrong,k.orig_b,f.payment_at);
  INSERT INTO _c5_checks VALUES('cross_tenant_original_rejected',false);
 EXCEPTION WHEN check_violation THEN
  INSERT INTO _c5_checks VALUES('cross_tenant_original_rejected',true);
 END;
 BEGIN
  PERFORM private.financial_2c5a_reverse_transfer_payment(
    f.org_a,f.sale_a,k.req_wrong,k.orig_b,f.payment_at-interval '1 day');
  INSERT INTO _c5_checks VALUES('reverse_before_payment_rejected',false);
 EXCEPTION WHEN check_violation THEN
  INSERT INTO _c5_checks VALUES('reverse_before_payment_rejected',true);
 END;
 BEGIN
  PERFORM private.financial_2c5a_reverse_transfer_payment(
    f.org_a,f.sale_a,k.req_wrong,k.orig_b,now()+interval '1 day');
  INSERT INTO _c5_checks VALUES('future_reversal_rejected',false);
 EXCEPTION WHEN check_violation THEN
  INSERT INTO _c5_checks VALUES('future_reversal_rejected',true);
 END;

 r:=private.financial_2c5a_reverse_transfer_payment(
    f.org_a,f.sale_a,k.rev_req,k.orig_b,f.payment_at);
 UPDATE _c5 SET rev_event=(r->>'evento_reverso_id')::uuid;
 INSERT INTO _c5_checks VALUES('reversal_30_reopens',
   (r->>'success')::boolean AND NOT (r->>'idempotent')::boolean
   AND (r->>'saldo')::numeric=30 AND (r->>'importe')::numeric=30
   AND (r->>'revision')::bigint=5);
 INSERT INTO _c5_checks VALUES('same_original_payment_retained',
   (SELECT COUNT(*)=3 AND SUM(monto)=100 FROM public.pagos_venta
   WHERE organization_id=f.org_a AND venta_id=f.sale_a));
 INSERT INTO _c5_checks VALUES('net_collections_70',
   (SELECT a.apta_para_motor AND a.cobros_eventos=70 AND a.saldo_calculado=30
     FROM private.financial_2c_audit_sale(f.org_a,f.sale_a) a));
 INSERT INTO _c5_checks VALUES('original_30_assignments_undone',
  (SELECT COUNT(*)=2 AND SUM(importe_asignado)=-30
    FROM public.venta_cuota_movimientos m
   WHERE m.organization_id=f.org_a AND m.venta_id=f.sale_a
     AND m.tipo='reverso' AND m.evento_id=(r->>'evento_reverso_id')::uuid));
 INSERT INTO _c5_checks VALUES('q2_original_amount_reopened',
  (SELECT SUM(m.importe_asignado)=16.67
   FROM public.venta_cuotas c JOIN public.venta_cuota_movimientos m
     ON m.organization_id=c.organization_id AND m.venta_id=c.venta_id AND m.cuota_id=c.id
    WHERE c.organization_id=f.org_a AND c.venta_id=f.sale_a AND c.numero=2));
 INSERT INTO _c5_checks VALUES('q3_original_amount_reopened',
  (SELECT SUM(m.importe_asignado)=20
   FROM public.venta_cuotas c JOIN public.venta_cuota_movimientos m
     ON m.organization_id=c.organization_id AND m.venta_id=c.venta_id AND m.cuota_id=c.id
    WHERE c.organization_id=f.org_a AND c.venta_id=f.sale_a AND c.numero=3));
 INSERT INTO _c5_checks VALUES('reversal_matches_original_event',
   (SELECT rv.delta_cobros=-30 AND rv.reversa_evento_id=k.orig_b AND rv.pago_id=orig.pago_id
     FROM public.venta_eventos_financieros rv
     JOIN public.venta_eventos_financieros orig ON rv.reversa_evento_id=orig.id
     WHERE rv.id=(r->>'evento_reverso_id')::uuid));
 INSERT INTO _c5_checks VALUES('original_events_immutable',
   (SELECT COUNT(*)=3 AND SUM(delta_cobros)=100
     FROM public.venta_eventos_financieros
     WHERE organization_id=f.org_a AND venta_id=f.sale_a AND tipo='cobro'));

 PERFORM set_config('TimeZone','America/Lima',true);
 again:=private.financial_2c5a_reverse_transfer_payment(
   f.org_a,f.sale_a,k.rev_req,k.orig_b,f.payment_at);
 PERFORM set_config('TimeZone','UTC',true);
 INSERT INTO _c5_checks VALUES('idempotent_utc_lima',
   (again->>'idempotent')::boolean
   AND again->>'evento_reverso_id'=r->>'evento_reverso_id');
 INSERT INTO _c5_checks VALUES('no_duplicate_negative_events',
   (SELECT COUNT(*)=1 FROM public.venta_eventos_financieros
     WHERE organization_id=f.org_a AND venta_id=f.sale_a AND tipo='reverso'));
 INSERT INTO _c5_checks VALUES('no_duplicate_negative_allocations',
   (SELECT COUNT(*)=2 FROM public.venta_cuota_movimientos
     WHERE organization_id=f.org_a AND venta_id=f.sale_a AND tipo='reverso'));

 BEGIN
  PERFORM private.financial_2c5a_reverse_transfer_payment(
    f.org_a,f.sale_a,k.rev_req,k.orig_a,f.payment_at);
  INSERT INTO _c5_checks VALUES('request_payload_change_rejected',false);
 EXCEPTION WHEN unique_violation THEN
  INSERT INTO _c5_checks VALUES('request_payload_change_rejected',true);
 END;
 BEGIN
  PERFORM private.financial_2c5a_reverse_transfer_payment(
    f.org_a,f.sale_a,gen_random_uuid(),k.orig_b,f.payment_at);
  INSERT INTO _c5_checks VALUES('double_reversal_different_request',false);
 EXCEPTION WHEN unique_violation THEN
  INSERT INTO _c5_checks VALUES('double_reversal_different_request',true);
 END;

 r:=private.financial_2c2_record_transfer_payment(
   f.org_a,f.sale_a,k.req_d,'PEN',30,f.payment_at);
 INSERT INTO _c5_checks VALUES('repay_after_reversal',
   (r->>'saldo')::numeric=0 AND (r->>'revision')::bigint=6);
 INSERT INTO _c5_checks VALUES('reallocated_fifo_30',
  (SELECT COUNT(*)=2 AND SUM(importe_asignado)=30
   FROM public.venta_cuota_movimientos
   WHERE organization_id=f.org_a AND venta_id=f.sale_a AND tipo='cobro'
     AND evento_id=(SELECT id FROM public.venta_eventos_financieros
       WHERE operacion_id=(r->>'operacion_id')::uuid)));
 INSERT INTO _c5_checks VALUES('all_quotas_paid_again',
   (SELECT COUNT(*)=3 AND COUNT(*) FILTER(WHERE estado='pagada')=3
    FROM private.financial_2c4_installments(f.org_a,f.sale_a,NULL)));
 INSERT INTO _c5_checks VALUES('net_income_100_again',
   (SELECT a.apta_para_motor AND a.cobros_eventos=100 AND a.saldo_calculado=0
   FROM private.financial_2c_audit_sale(f.org_a,f.sale_a) a));
END;
$cases$;
DO $verify$
BEGIN
 IF EXISTS(SELECT 1 FROM _c5_checks WHERE NOT passed) THEN
  RAISE EXCEPTION '2C5A failed checks: %',
   (SELECT string_agg(name,', ' ORDER BY name) FROM _c5_checks WHERE NOT passed);
 END IF;
END $verify$;
SELECT plan(29);
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='initial_100_paid')),'initial_100_paid');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='cross_tenant_original_rejected')),'cross_tenant_original_rejected');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='reverse_before_payment_rejected')),'reverse_before_payment_rejected');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='future_reversal_rejected')),'future_reversal_rejected');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='reversal_30_reopens')),'reversal_30_reopens');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='same_original_payment_retained')),'same_original_payment_retained');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='net_collections_70')),'net_collections_70');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='original_30_assignments_undone')),'original_30_assignments_undone');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='q2_original_amount_reopened')),'q2_original_amount_reopened');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='q3_original_amount_reopened')),'q3_original_amount_reopened');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='reversal_matches_original_event')),'reversal_matches_original_event');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='original_events_immutable')),'original_events_immutable');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='idempotent_utc_lima')),'idempotent_utc_lima');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='no_duplicate_negative_events')),'no_duplicate_negative_events');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='no_duplicate_negative_allocations')),'no_duplicate_negative_allocations');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='request_payload_change_rejected')),'request_payload_change_rejected');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='double_reversal_different_request')),'double_reversal_different_request');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='repay_after_reversal')),'repay_after_reversal');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='reallocated_fifo_30')),'reallocated_fifo_30');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='all_quotas_paid_again')),'all_quotas_paid_again');
SELECT ok(((SELECT passed FROM _c5_checks WHERE name='net_income_100_again')),'net_income_100_again');
SELECT ok(((SELECT COUNT(*)=4 AND SUM(monto)=130 FROM public.pagos_venta p JOIN _fin2c2_f f ON p.organization_id=f.org_a AND p.venta_id=f.sale_a)),'originals_still_4_payments');
SELECT ok(((SELECT COUNT(*)=4 FROM public.pagos_venta p JOIN _fin2c2_f f ON p.organization_id=f.org_a AND p.venta_id=f.sale_a WHERE p.cash_session_id IS NULL AND p.cash_register_id IS NULL)),'reversal_no_cash');
SELECT ok((NOT has_function_privilege('authenticated','private.financial_2c5a_reverse_transfer_payment(uuid,bigint,uuid,uuid,timestamptz)','EXECUTE') AND NOT has_function_privilege('service_role','private.financial_2c5a_reverse_transfer_payment(uuid,bigint,uuid,uuid,timestamptz)','EXECUTE')),'reversal_user_roles_denied');
SELECT ok((EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='venta_eventos_financieros' AND indexname='venta_eventos_2c5_unique_full_reversal')),'reversal_index_unique');
SELECT ok((EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND tablename='venta_cuota_movimientos' AND indexname='venta_cuota_mov_2c5_unique_reversal')),'quota_reversal_index_unique');
SELECT ok(((SELECT COUNT(*)=0 FROM private.financial_2c2_write_intents)),'intents_clean');
SELECT ok(((SELECT saldo_pendiente=50 FROM public.venta_cuentas_financieras c JOIN _fin2c2_f f ON c.organization_id=f.org_b AND c.venta_id=f.sale_b)),'origin_other_tenant_untouched');
SELECT ok(((SELECT COUNT(*)=4 FROM public.pagos_venta p JOIN _fin2c2_f f ON p.organization_id=f.org_a AND p.venta_id=f.sale_a WHERE p.monto>0)),'no_legacy_payment_edits');
SELECT * FROM finish();
ROLLBACK;
