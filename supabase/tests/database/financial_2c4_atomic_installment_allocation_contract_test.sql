-- 2C4: aplicación de cobros reales a cuotas. Fixtures totalmente reversibles.
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


WITH cronograma AS (
 INSERT INTO public.venta_cronogramas(organization_id,venta_id,version,estado)
 SELECT org_a,sale_a,1,'vigente' FROM _fin2c2_f
 RETURNING id,organization_id,venta_id
)
INSERT INTO public.venta_cuotas(
 organization_id,venta_id,cronograma_id,numero,vencimiento,
 importe_original,importe_vigente
)
SELECT c.organization_id,c.venta_id,c.id,q.numero,
  (now() AT TIME ZONE 'America/Lima')::date +
    CASE WHEN q.numero<=2 THEN 1 ELSE 2 END,
  q.monto,q.monto
FROM cronograma c
CROSS JOIN (VALUES (1,33.33::numeric),(2,33.33::numeric),(3,33.34::numeric))
 AS q(numero,monto);

CREATE TEMP TABLE _c4_checks(name text PRIMARY KEY,passed boolean NOT NULL)
 ON COMMIT DROP;

DO $scenario$
DECLARE
 f _fin2c2_f%ROWTYPE;
 r jsonb;
 again jsonb;
 req_1 uuid:=gen_random_uuid();
 req_2 uuid:=gen_random_uuid();
 req_3 uuid:=gen_random_uuid();
 req_b uuid:=gen_random_uuid();
 op_count bigint;
 q1 numeric;
 q2 numeric;
 q3 numeric;
BEGIN
 SELECT * INTO f FROM _fin2c2_f;
 INSERT INTO _c4_checks VALUES ('schedule_three_exact',
   (SELECT COUNT(*)=3 AND SUM(importe_vigente)=100
      FROM public.venta_cuotas
      WHERE organization_id=f.org_a AND venta_id=f.sale_a));
 INSERT INTO _c4_checks VALUES ('before_no_movements',
   NOT EXISTS (SELECT 1 FROM public.venta_cuota_movimientos
               WHERE organization_id=f.org_a AND venta_id=f.sale_a));

 r:=private.financial_2c2_record_transfer_payment(
   f.org_a,f.sale_a,req_1,'PEN',50,f.payment_at);
 INSERT INTO _c4_checks VALUES ('first_balance_50',
   (r->>'saldo')::numeric=50 AND (r->>'revision')::bigint=2);

 SELECT COALESCE(SUM(m.importe_asignado),0)
   INTO q1 FROM public.venta_cuota_movimientos m
   JOIN public.venta_cuotas c ON c.id=m.cuota_id
  WHERE c.organization_id=f.org_a AND c.venta_id=f.sale_a AND c.numero=1;
 SELECT COALESCE(SUM(m.importe_asignado),0)
   INTO q2 FROM public.venta_cuota_movimientos m
   JOIN public.venta_cuotas c ON c.id=m.cuota_id
  WHERE c.organization_id=f.org_a AND c.venta_id=f.sale_a AND c.numero=2;
 SELECT COALESCE(SUM(m.importe_asignado),0)
   INTO q3 FROM public.venta_cuota_movimientos m
   JOIN public.venta_cuotas c ON c.id=m.cuota_id
  WHERE c.organization_id=f.org_a AND c.venta_id=f.sale_a AND c.numero=3;
 INSERT INTO _c4_checks VALUES
  ('first_fifo_33_33_16_67',q1=33.33 AND q2=16.67 AND q3=0);
 INSERT INTO _c4_checks VALUES ('first_two_moves',
  (SELECT COUNT(*)=2 AND SUM(importe_asignado)=50
   FROM public.venta_cuota_movimientos
   WHERE organization_id=f.org_a AND venta_id=f.sale_a));
 INSERT INTO _c4_checks VALUES ('not_overdue_on_due_day',
  (SELECT estado='parcial' AND NOT vencida
   FROM private.financial_2c4_installments(
     f.org_a,f.sale_a,(now() AT TIME ZONE 'America/Lima')::date+1)
   WHERE numero=2));
 INSERT INTO _c4_checks VALUES ('partial_overdue_next_day',
  (SELECT estado='parcial' AND vencida
   FROM private.financial_2c4_installments(
     f.org_a,f.sale_a,(now() AT TIME ZONE 'America/Lima')::date+2)
   WHERE numero=2));

 again:=private.financial_2c2_record_transfer_payment(
   f.org_a,f.sale_a,req_1,'PEN',50,f.payment_at);
 INSERT INTO _c4_checks VALUES('retry_same_payment',
  again->>'idempotent'='true' AND again->>'pago_id'=r->>'pago_id');
 INSERT INTO _c4_checks VALUES('retry_no_duplicate_movements',
  (SELECT COUNT(*)=2 FROM public.venta_cuota_movimientos
   WHERE organization_id=f.org_a AND venta_id=f.sale_a));

 r:=private.financial_2c2_record_transfer_payment(
   f.org_a,f.sale_a,req_2,'PEN',30,f.payment_at);
 INSERT INTO _c4_checks VALUES('second_balance_20',
  (r->>'saldo')::numeric=20 AND (r->>'revision')::bigint=3);
 SELECT COALESCE(SUM(m.importe_asignado),0)
   INTO q2 FROM public.venta_cuota_movimientos m
   JOIN public.venta_cuotas c ON c.id=m.cuota_id
  WHERE c.organization_id=f.org_a AND c.venta_id=f.sale_a AND c.numero=2;
 SELECT COALESCE(SUM(m.importe_asignado),0)
   INTO q3 FROM public.venta_cuota_movimientos m
   JOIN public.venta_cuotas c ON c.id=m.cuota_id
  WHERE c.organization_id=f.org_a AND c.venta_id=f.sale_a AND c.numero=3;
 INSERT INTO _c4_checks VALUES('second_partial_to_future',
  q2=33.33 AND q3=13.34);

 r:=private.financial_2c2_record_transfer_payment(
   f.org_a,f.sale_a,req_3,'PEN',20,f.payment_at);
 INSERT INTO _c4_checks VALUES('third_exact_closure',
  (r->>'saldo')::numeric=0 AND (r->>'revision')::bigint=4);
 INSERT INTO _c4_checks VALUES('all_three_paid',
  (SELECT COUNT(*)=3 AND COUNT(*) FILTER(WHERE estado='pagada')=3
      AND SUM(saldo_pendiente)=0 AND BOOL_AND(NOT vencida)
   FROM private.financial_2c4_installments(
     f.org_a,f.sale_a,(now() AT TIME ZONE 'America/Lima')::date+90)));

 r:=private.financial_2c2_record_transfer_payment(
   f.org_b,f.sale_b,req_b,'PEN',10,f.payment_at);
 INSERT INTO _c4_checks VALUES('legacy_without_schedule_paid',
  (r->>'saldo')::numeric=40);
 INSERT INTO _c4_checks VALUES('legacy_no_due_invented',
  NOT EXISTS(SELECT 1 FROM private.financial_2c4_installments(
    f.org_b,f.sale_b,NULL)));
 INSERT INTO _c4_checks VALUES('legacy_no_installment_moves',
  NOT EXISTS(SELECT 1 FROM public.venta_cuota_movimientos
    WHERE organization_id=f.org_b AND venta_id=f.sale_b));

 WITH cr AS (
  INSERT INTO public.venta_cronogramas(organization_id,venta_id,version,estado)
  VALUES (f.org_b,f.sale_b,1,'vigente')
  RETURNING id
 )
 INSERT INTO public.venta_cuotas(
  organization_id,venta_id,cronograma_id,numero,
  vencimiento,importe_original,importe_vigente)
 SELECT f.org_b,f.sale_b,cr.id,1,
  (now() AT TIME ZONE 'America/Lima')::date+7,39.99,39.99 FROM cr;

 BEGIN
   PERFORM private.financial_2c2_record_transfer_payment(
     f.org_b,f.sale_b,gen_random_uuid(),'PEN',10,f.payment_at);
   INSERT INTO _c4_checks VALUES('mismatched_schedule_rejected',false);
 EXCEPTION WHEN check_violation THEN
   INSERT INTO _c4_checks VALUES('mismatched_schedule_rejected',true);
 END;
 INSERT INTO _c4_checks VALUES('failed_mismatch_atomic',
   (SELECT COUNT(*)=1 FROM public.pagos_venta
    WHERE organization_id=f.org_b AND venta_id=f.sale_b));
 UPDATE public.venta_cuotas
   SET importe_original=40,importe_vigente=40
 WHERE organization_id=f.org_b AND venta_id=f.sale_b;
 r:=private.financial_2c2_record_transfer_payment(
  f.org_b,f.sale_b,gen_random_uuid(),'PEN',40,f.payment_at);
 INSERT INTO _c4_checks VALUES('corrected_schedule_closes',
  (r->>'saldo')::numeric=0);
END;
$scenario$;

DO $require$
BEGIN
 IF EXISTS(SELECT 1 FROM _c4_checks WHERE NOT passed) THEN
   RAISE EXCEPTION '2C4 failed checks: %',
     (SELECT string_agg(name,', ' ORDER BY name) FROM _c4_checks WHERE NOT passed);
 END IF;
END $require$;

SELECT plan(31);
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='schedule_three_exact')),'schedule_three_exact');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='before_no_movements')),'before_no_movements');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='first_balance_50')),'first_balance_50');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='first_fifo_33_33_16_67')),'first_fifo_33_33_16_67');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='first_two_moves')),'first_two_moves');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='not_overdue_on_due_day')),'not_overdue_on_due_day');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='partial_overdue_next_day')),'partial_overdue_next_day');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='retry_same_payment')),'retry_same_payment');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='retry_no_duplicate_movements')),'retry_no_duplicate_movements');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='second_balance_20')),'second_balance_20');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='second_partial_to_future')),'second_partial_to_future');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='third_exact_closure')),'third_exact_closure');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='all_three_paid')),'all_three_paid');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='legacy_without_schedule_paid')),'legacy_without_schedule_paid');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='legacy_no_due_invented')),'legacy_no_due_invented');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='legacy_no_installment_moves')),'legacy_no_installment_moves');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='mismatched_schedule_rejected')),'mismatched_schedule_rejected');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='failed_mismatch_atomic')),'failed_mismatch_atomic');
SELECT ok(((SELECT passed FROM _c4_checks WHERE name='corrected_schedule_closes')),'corrected_schedule_closes');
SELECT ok((EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.venta_eventos_financieros'::regclass AND tgname='zz_fin2c4_allocate_receipt_to_installments')),'writer_trigger_installed');
SELECT ok(((SELECT NOT prosecdef AND provolatile='s' FROM pg_proc WHERE oid='private.financial_2c4_installments(uuid,bigint,date)'::regprocedure)),'read_invoker_private');
SELECT ok((NOT has_function_privilege('authenticated','private.financial_2c4_installments(uuid,bigint,date)','EXECUTE') AND NOT has_function_privilege('service_role','private.financial_2c4_installments(uuid,bigint,date)','EXECUTE')),'read_denied_client');
SELECT ok((EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.venta_cuota_movimientos'::regclass AND tgname='venta_cuota_mov_fin2a_immutable')),'movements_append_only');
SELECT ok(((SELECT SUM(importe_asignado)=100 AND COUNT(*)=5 AND COUNT(DISTINCT evento_id)=3 FROM public.venta_cuota_movimientos m JOIN _fin2c2_f f ON m.organization_id=f.org_a AND m.venta_id=f.sale_a)),'total_one_hundred');
SELECT ok(((SELECT SUM(importe_asignado)=40 AND COUNT(*)=1 FROM public.venta_cuota_movimientos m JOIN _fin2c2_f f ON m.organization_id=f.org_b AND m.venta_id=f.sale_b)),'total_legacy_forty');
SELECT ok(((SELECT apta_para_motor AND cobros_eventos=100 AND saldo_calculado=0 FROM private.financial_2c_audit_sale((SELECT org_a FROM _fin2c2_f),(SELECT sale_a FROM _fin2c2_f)))),'total_ledger_first');
SELECT ok(((SELECT apta_para_motor AND cobros_eventos=50 AND saldo_calculado=0 FROM private.financial_2c_audit_sale((SELECT org_b FROM _fin2c2_f),(SELECT sale_b FROM _fin2c2_f)))),'other_tenant_isolated');
SELECT ok(((SELECT COUNT(*)=3 AND SUM(monto)=100 FROM public.pagos_venta p JOIN _fin2c2_f f ON p.organization_id=f.org_a AND p.venta_id=f.sale_a)),'no_duplicate_income');
SELECT ok(((SELECT COUNT(*)=0 FROM private.financial_2c2_write_intents)),'no_leaked_intents');
SELECT ok((NOT EXISTS(SELECT 1 FROM public.venta_cuota_movimientos m JOIN public.venta_cuotas c ON m.cuota_id=c.id WHERE m.organization_id<>c.organization_id OR m.venta_id<>c.venta_id)),'no_cross_sale_allocation');
SELECT ok(((SELECT COUNT(*)=3 AND COUNT(DISTINCT vencimiento)=2 FROM public.venta_cuotas c JOIN _fin2c2_f f ON c.organization_id=f.org_a AND c.venta_id=f.sale_a)),'expected_dates');
SELECT * FROM finish();
ROLLBACK;
