-- 2C2: motor canónico de cobros por transferencia. Datos reversibles.
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

CREATE TEMP TABLE _fin2c2_checks (name text PRIMARY KEY, passed boolean NOT NULL) ON COMMIT DROP;
DO $cases$
DECLARE f _fin2c2_f%ROWTYPE; r jsonb; again jsonb; other jsonb;
BEGIN
 SELECT * INTO f FROM _fin2c2_f;

 BEGIN
   PERFORM private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,f.request_a,'PEN',0.001,f.payment_at);
   INSERT INTO _fin2c2_checks VALUES('fraction_cent',false);
 EXCEPTION WHEN invalid_parameter_value THEN
   INSERT INTO _fin2c2_checks VALUES('fraction_cent',true);
 END;
 BEGIN
   PERFORM private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,f.request_a,'USD',40,f.payment_at);
   INSERT INTO _fin2c2_checks VALUES('wrong_currency',false);
 EXCEPTION WHEN check_violation THEN
   INSERT INTO _fin2c2_checks VALUES('wrong_currency',true);
 END;
 BEGIN
   PERFORM private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,f.request_a,'PEN',100.01,f.payment_at);
   INSERT INTO _fin2c2_checks VALUES('overpay_cent',false);
 EXCEPTION WHEN check_violation THEN
   INSERT INTO _fin2c2_checks VALUES('overpay_cent',true);
 END;
 BEGIN
   PERFORM private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,f.request_a,'PEN',40,now()+interval '2 days');
   INSERT INTO _fin2c2_checks VALUES('future_date',false);
 EXCEPTION WHEN check_violation THEN
   INSERT INTO _fin2c2_checks VALUES('future_date',true);
 END;
 BEGIN
   PERFORM private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,f.request_a,'PEN',40,now()-interval '4 days');
   INSERT INTO _fin2c2_checks VALUES('before_sale_date',false);
 EXCEPTION WHEN check_violation THEN
   INSERT INTO _fin2c2_checks VALUES('before_sale_date',true);
 END;
 BEGIN
   PERFORM private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,NULL,'PEN',40,f.payment_at);
   INSERT INTO _fin2c2_checks VALUES('request_required',false);
 EXCEPTION WHEN invalid_parameter_value THEN
   INSERT INTO _fin2c2_checks VALUES('request_required',true);
 END;

 r:=private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,f.request_a,'PEN',40,f.payment_at);
 UPDATE _fin2c2_f SET payment_a=(r->>'pago_id')::bigint,op_a=(r->>'operacion_id')::uuid;
 INSERT INTO _fin2c2_checks VALUES('first_write',
     (r->>'success')::boolean AND NOT (r->>'idempotent')::boolean
     AND (r->>'saldo')::numeric=60 AND (r->>'revision')::bigint=2);

 -- Reintentar con distinta zona de sesión conserva la misma huella.
 PERFORM set_config('TimeZone','America/Lima',true);
 again:=private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,f.request_a,'PEN',40,f.payment_at);
 PERFORM set_config('TimeZone','UTC',true);
 INSERT INTO _fin2c2_checks VALUES('idempotency',
     (again->>'idempotent')::boolean AND again->>'pago_id'=r->>'pago_id'
     AND again->>'operacion_id'=r->>'operacion_id');

 BEGIN
   PERFORM private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,f.request_a,'PEN',41,f.payment_at);
   INSERT INTO _fin2c2_checks VALUES('retry_payload_conflict',false);
 EXCEPTION WHEN unique_violation THEN
   INSERT INTO _fin2c2_checks VALUES('retry_payload_conflict',true);
 END;
 BEGIN
   PERFORM private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,f.request_a,'PEN',40,f.payment_at+interval '1 minute');
   INSERT INTO _fin2c2_checks VALUES('retry_date_conflict',false);
 EXCEPTION WHEN unique_violation THEN
   INSERT INTO _fin2c2_checks VALUES('retry_date_conflict',true);
 END;

 BEGIN
   PERFORM set_config('stomni.finance2c2_writer','true',true);
   INSERT INTO public.pagos_venta(organization_id,venta_id,metodo,monto,fecha)
    VALUES(f.org_a,f.sale_a,'transferencia',5,f.payment_at);
   INSERT INTO _fin2c2_checks VALUES('spoof_guc_rejected',false);
 EXCEPTION WHEN object_not_in_prerequisite_state THEN
   INSERT INTO _fin2c2_checks VALUES('spoof_guc_rejected',true);
 END;

 BEGIN
   UPDATE public.ventas SET saldo=1 WHERE organization_id=f.org_a AND id=f.sale_a;
   INSERT INTO _fin2c2_checks VALUES('legacy_sale_update_blocked',false);
 EXCEPTION WHEN object_not_in_prerequisite_state THEN
   INSERT INTO _fin2c2_checks VALUES('legacy_sale_update_blocked',true);
 END;
 BEGIN
   DELETE FROM public.pagos_venta WHERE organization_id=f.org_a AND venta_id=f.sale_a;
   INSERT INTO _fin2c2_checks VALUES('legacy_payment_delete_blocked',false);
 EXCEPTION WHEN object_not_in_prerequisite_state THEN
   INSERT INTO _fin2c2_checks VALUES('legacy_payment_delete_blocked',true);
 END;

 -- La solicitud se puede reutilizar en otro tenant: idempotencia tenant-aware.
 other:=private.financial_2c2_record_transfer_payment(f.org_b,f.sale_b,f.request_a,'PEN',20,f.payment_at);
 INSERT INTO _fin2c2_checks VALUES('cross_tenant_same_request',
     other->>'success'='true' AND (other->>'saldo')::numeric=30);

 BEGIN
   PERFORM private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,f.request_b,'PEN',60.01,f.payment_at);
   INSERT INTO _fin2c2_checks VALUES('overpay_remaining_cent',false);
 EXCEPTION WHEN check_violation THEN
   INSERT INTO _fin2c2_checks VALUES('overpay_remaining_cent',true);
 END;

 r:=private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,f.request_b,'PEN',60,f.payment_at);
 INSERT INTO _fin2c2_checks VALUES('second_closes_balance',
    r->>'success'='true' AND (r->>'saldo')::numeric=0
    AND (r->>'revision')::bigint=3);
 BEGIN
   PERFORM private.financial_2c2_record_transfer_payment(f.org_a,f.sale_a,gen_random_uuid(),'PEN',0.01,f.payment_at);
   INSERT INTO _fin2c2_checks VALUES('zero_remaining_blocked',false);
 EXCEPTION WHEN check_violation THEN
   INSERT INTO _fin2c2_checks VALUES('zero_remaining_blocked',true);
 END;
END;
$cases$;
SELECT plan(33);
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='fraction_cent')), 'fraction_cent');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='wrong_currency')), 'wrong_currency');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='overpay_cent')), 'overpay_cent');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='future_date')), 'future_date');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='before_sale_date')), 'before_sale_date');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='request_required')), 'request_required');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='first_write')), 'first_write');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='idempotency')), 'idempotency');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='retry_payload_conflict')), 'retry_payload_conflict');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='retry_date_conflict')), 'retry_date_conflict');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='spoof_guc_rejected')), 'spoof_guc_rejected');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='legacy_sale_update_blocked')), 'legacy_sale_update_blocked');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='legacy_payment_delete_blocked')), 'legacy_payment_delete_blocked');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='cross_tenant_same_request')), 'cross_tenant_same_request');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='overpay_remaining_cent')), 'overpay_remaining_cent');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='second_closes_balance')), 'second_closes_balance');
SELECT ok(((SELECT passed FROM _fin2c2_checks WHERE name='zero_remaining_blocked')), 'zero_remaining_blocked');
SELECT ok((to_regprocedure('private.financial_2c2_record_transfer_payment(uuid,bigint,uuid,text,numeric,timestamptz)') IS NOT NULL), 'writer installed');
SELECT ok((NOT has_function_privilege('anon','private.financial_2c2_record_transfer_payment(uuid,bigint,uuid,text,numeric,timestamptz)','EXECUTE') AND NOT has_function_privilege('authenticated','private.financial_2c2_record_transfer_payment(uuid,bigint,uuid,text,numeric,timestamptz)','EXECUTE') AND NOT has_function_privilege('service_role','private.financial_2c2_record_transfer_payment(uuid,bigint,uuid,text,numeric,timestamptz)','EXECUTE')), 'writer admin-only');
SELECT ok((NOT has_table_privilege('authenticated','private.financial_2c2_write_intents','INSERT') AND NOT has_table_privilege('service_role','private.financial_2c2_write_intents','INSERT')), 'intents private not client writable');
SELECT ok(((SELECT relrowsecurity FROM pg_class WHERE oid='private.financial_2c2_write_intents'::regclass)), 'intents RLS');
SELECT ok(((SELECT COUNT(*)=0 FROM private.financial_2c2_write_intents)), 'no leaked intents');
SELECT ok(((SELECT COUNT(*)=2 FROM public.pagos_venta pv JOIN _fin2c2_f f ON pv.organization_id=f.org_a AND pv.venta_id=f.sale_a)), 'two payments no retry duplicates');
SELECT ok(((SELECT COUNT(*)=2 FROM public.venta_operaciones_financieras op JOIN _fin2c2_f f ON op.organization_id=f.org_a AND op.venta_id=f.sale_a WHERE op.tipo='cobro')), 'two applied operations');
SELECT ok(((SELECT COUNT(*)=3 AND MIN(ev.secuencia)=1 AND MAX(ev.secuencia)=3 AND SUM(ev.delta_cobros)=100 FROM public.venta_eventos_financieros ev JOIN _fin2c2_f f ON ev.organization_id=f.org_a AND ev.venta_id=f.sale_a)), 'exact ordered events');
SELECT ok(((SELECT apta_para_motor AND saldo_calculado=0 AND cobros_eventos=100 FROM private.financial_2c_audit_sale((SELECT org_a FROM _fin2c2_f),(SELECT sale_a FROM _fin2c2_f)))), 'canonical audit remains valid');
SELECT ok(((SELECT cf.revision=3 AND cf.cobros_netos=100 AND cf.exigible=100 AND cf.saldo_pendiente=0 AND cf.excedente=0 FROM public.venta_cuentas_financieras cf JOIN _fin2c2_f f ON cf.organization_id=f.org_a AND cf.venta_id=f.sale_a)), 'projection matches');
SELECT ok(((SELECT v.saldo=0 AND v.estado='pagado' FROM public.ventas v JOIN _fin2c2_f f ON v.organization_id=f.org_a AND v.id=f.sale_a)), 'legacy sale projection synced');
SELECT ok(((SELECT COUNT(*)=2 FROM public.pagos_venta pv JOIN _fin2c2_f f ON pv.organization_id=f.org_a AND pv.venta_id=f.sale_a WHERE pv.cash_session_id IS NULL AND pv.cash_register_id IS NULL AND pv.request_id IS NULL AND pv.metodo='transferencia')), 'no cash or legacy request mutations');
SELECT ok(((SELECT op.resultado='aplicado' AND op.resultado_payload->>'pago_id' IS NOT NULL AND op.payload_hash<>'' FROM public.venta_operaciones_financieras op JOIN _fin2c2_f f ON op.organization_id=f.org_a AND op.venta_id=f.sale_a WHERE op.id=f.op_a)), 'idempotent recorded payload');
SELECT ok(((SELECT COUNT(*)=1 FROM public.pagos_venta pv JOIN _fin2c2_f f ON pv.organization_id=f.org_b AND pv.venta_id=f.sale_b)), 'cross tenant payment separated');
SELECT ok(((SELECT cf.saldo_pendiente=30 AND cf.cobros_netos=20 FROM public.venta_cuentas_financieras cf JOIN _fin2c2_f f ON cf.organization_id=f.org_b AND cf.venta_id=f.sale_b)), 'tenant B projection separate');
SELECT ok((SELECT array_to_string(proconfig, ',') ILIKE '%timezone=UTC%'
 FROM pg_proc WHERE oid='private.financial_2c2_record_transfer_payment(uuid,bigint,uuid,text,numeric,timestamptz)'::regprocedure),
 'firma idempotente usa UTC independientemente de la sesión');
SELECT * FROM finish();
ROLLBACK;
