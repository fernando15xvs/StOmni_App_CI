-- 2C3B: cobro en efectivo con sesión y JWT, fixtures reversibles.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
CREATE TEMP TABLE _c3 (
 org_a uuid,org_b uuid,branch_a uuid,branch_b uuid,reg_a uuid,reg_b uuid,
 sess_a uuid,sess_b uuid,actor_a uuid,actor_b uuid,
 sale_a bigint,sale_b bigint,emp_a bigint,role_a uuid,request_a uuid,
 fecha_pago timestamptz
) ON COMMIT DROP;
INSERT INTO _c3 VALUES(
 gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
 gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),
 gen_random_uuid(),gen_random_uuid(),-840040001,-840040002,NULL,gen_random_uuid(),
 gen_random_uuid(), now()-interval '30 minutes');
SET LOCAL session_replication_role=replica;
INSERT INTO auth.users(id,aud,role)
SELECT actor_a,'authenticated','authenticated' FROM _c3
UNION ALL SELECT actor_b,'authenticated','authenticated' FROM _c3;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org_a,'2C3 ficticia A','PE','PEN','America/Lima' FROM _c3
UNION ALL SELECT org_b,'2C3 ficticia B','PE','PEN','America/Lima' FROM _c3;
INSERT INTO public.app_users(user_id,organization_id,status,base_role)
SELECT actor_a,org_a,'active','operador' FROM _c3
UNION ALL SELECT actor_b,org_b,'active','operador' FROM _c3;

INSERT INTO public.branches(id,organization_id,code,name,is_main,status)
SELECT branch_a,org_a,'C3A','2C3-A',true,'active' FROM _c3
UNION ALL SELECT branch_b,org_b,'C3B','2C3-B',true,'active' FROM _c3;
INSERT INTO public.cash_registers(id,organization_id,branch_id,code,name,status)
SELECT reg_a,org_a,branch_a,'CASH-C3A','Caja 2C3 A','active' FROM _c3
UNION ALL SELECT reg_b,org_b,branch_b,'CASH-C3B','Caja 2C3 B','active' FROM _c3;
INSERT INTO public.sesiones_caja(
 id,organization_id,branch_id,cash_register_id,usuario_id,fecha_apertura,monto_apertura,estado)
SELECT sess_a,org_a,branch_a,reg_a,actor_a,now()-interval '2 hours',10,'ABIERTA' FROM _c3
UNION ALL SELECT sess_b,org_b,branch_b,reg_b,actor_b,now()-interval '2 hours',10,'ABIERTA' FROM _c3;
WITH em AS (
 INSERT INTO public.empleados(nombre,rol,organization_id,branch_id,auth_id,activo,employment_status)
 SELECT 'Caja 2C3 A','operador',org_a,branch_a,actor_a,true,'active' FROM _c3 RETURNING id
) UPDATE _c3 SET emp_a=(SELECT id FROM em);
INSERT INTO public.roles(id,organization_id,code,name,status)
 SELECT role_a,org_a,'operator','Operador ficticio','active' FROM _c3;
INSERT INTO public.employee_roles(organization_id,employee_id,role_id)
 SELECT org_a,emp_a,role_a FROM _c3;
INSERT INTO public.ventas(id,organization_id,total,saldo,estado,fecha,monto_notas_credito)
 SELECT sale_a,org_a,100,100,'pendiente',now()-interval '1 day',0 FROM _c3
 UNION ALL SELECT sale_b,org_b,50,50,'pendiente',now()-interval '1 day',0 FROM _c3;
SET LOCAL session_replication_role=origin;
INSERT INTO public.venta_cuentas_financieras(
 organization_id,venta_id,moneda,estado_conciliacion,exigible,cobros_netos,saldo_pendiente,revision)
 SELECT org_a,sale_a,'PEN','conciliada',100,0,100,1 FROM _c3
 UNION ALL SELECT org_b,sale_b,'PEN','conciliada',50,0,50,1 FROM _c3;
WITH op AS (
 INSERT INTO public.venta_operaciones_financieras(
 organization_id,venta_id,tipo,request_id,payload_hash,resultado,metadata_apertura)
 SELECT org_a,sale_a,'apertura',gen_random_uuid(),'2c3-a','aplicado',
  '{"cobertura":"historico_auditado"}'::jsonb FROM _c3
 UNION ALL
 SELECT org_b,sale_b,'apertura',gen_random_uuid(),'2c3-b','aplicado',
  '{"cobertura":"historico_auditado"}'::jsonb FROM _c3
 RETURNING id,organization_id,venta_id
)
INSERT INTO public.venta_eventos_financieros(
 organization_id,venta_id,operacion_id,secuencia,tipo,delta_exigible,delta_cobros,efectivo_at)
 SELECT organization_id,venta_id,id,1,'apertura',
  CASE WHEN venta_id=-840040001 THEN 100 ELSE 50 END,0,now()-interval '1 day'
 FROM op;

INSERT INTO public.employee_permission_overrides(organization_id,employee_id,permission_code,allowed)
SELECT org_a,emp_a,'sales.collect',true FROM _c3;
CREATE TEMP TABLE _c3b_check(name text PRIMARY KEY,passed boolean NOT NULL) ON COMMIT DROP;
DO $spec$
DECLARE
  f _c3%ROWTYPE;
  v jsonb;
  again jsonb;
  endpay jsonb;
  payment2 uuid:=gen_random_uuid();
  badrequest uuid:=gen_random_uuid();
BEGIN
 SELECT * INTO f FROM _c3;
 PERFORM set_config('request.jwt.claim.sub',f.actor_a::text,true);
 IF auth.uid() IS DISTINCT FROM f.actor_a THEN
   RAISE EXCEPTION 'Fixture JWT actor mismatched';
 END IF;
 v:=private.financial_2c3b_record_cash_payment(
   f.org_a,f.sale_a,f.request_a,f.sess_a,40,f.fecha_pago);
 INSERT INTO _c3b_check VALUES
  ('first_cash',v->>'success'='true' AND v->>'idempotent'='false'
    AND (v->>'saldo')::numeric=60 AND (v->>'revision')::bigint=2
    AND v->>'cash_session_id'=f.sess_a::text);
 again:=private.financial_2c3b_record_cash_payment(
   f.org_a,f.sale_a,f.request_a,f.sess_a,40,f.fecha_pago);
 INSERT INTO _c3b_check VALUES
  ('retry_same',again->>'idempotent'='true'
    AND again->>'pago_id'=v->>'pago_id'
    AND again->>'operacion_id'=v->>'operacion_id');

 BEGIN
  PERFORM private.financial_2c3b_record_cash_payment(
   f.org_a,f.sale_a,f.request_a,f.sess_a,41,f.fecha_pago);
  INSERT INTO _c3b_check VALUES('changed_payload_rejected',false);
 EXCEPTION WHEN unique_violation THEN
  INSERT INTO _c3b_check VALUES('changed_payload_rejected',true);
 END;

 BEGIN
  PERFORM private.financial_2c3b_record_cash_payment(
   f.org_a,f.sale_a,f.request_a,f.sess_b,40,f.fecha_pago);
  INSERT INTO _c3b_check VALUES('changed_session_rejected',false);
 EXCEPTION WHEN unique_violation THEN
  INSERT INTO _c3b_check VALUES('changed_session_rejected',true);
 END;

 BEGIN
  PERFORM private.financial_2c3b_record_cash_payment(
   f.org_a,f.sale_a,badrequest,f.sess_a,60.01,f.fecha_pago);
  INSERT INTO _c3b_check VALUES('overpay_cent_rejected',false);
 EXCEPTION WHEN check_violation THEN
  INSERT INTO _c3b_check VALUES('overpay_cent_rejected',true);
 END;

 BEGIN
  PERFORM private.financial_2c3b_record_cash_payment(
   f.org_a,f.sale_a,badrequest,f.sess_a,0.001,f.fecha_pago);
  INSERT INTO _c3b_check VALUES('fraction_cent_rejected',false);
 EXCEPTION WHEN invalid_parameter_value THEN
  INSERT INTO _c3b_check VALUES('fraction_cent_rejected',true);
 END;

 BEGIN
  PERFORM private.financial_2c3b_record_cash_payment(
   f.org_b,f.sale_b,badrequest,f.sess_a,5,f.fecha_pago);
  INSERT INTO _c3b_check VALUES('cross_tenant_rejected',false);
 EXCEPTION WHEN insufficient_privilege THEN
  INSERT INTO _c3b_check VALUES('cross_tenant_rejected',true);
 END;

 BEGIN
  UPDATE public.ventas SET saldo=0
  WHERE organization_id=f.org_a AND id=f.sale_a;
  INSERT INTO _c3b_check VALUES('legacy_sale_blocked',false);
 EXCEPTION WHEN object_not_in_prerequisite_state THEN
  INSERT INTO _c3b_check VALUES('legacy_sale_blocked',true);
 END;

 BEGIN
  INSERT INTO public.pagos_venta(organization_id,venta_id,metodo,monto,fecha,cash_session_id,cash_register_id)
  VALUES(f.org_a,f.sale_a,'efectivo',1,f.fecha_pago,f.sess_a,f.reg_a);
  INSERT INTO _c3b_check VALUES('legacy_payment_blocked',false);
 EXCEPTION WHEN object_not_in_prerequisite_state THEN
  INSERT INTO _c3b_check VALUES('legacy_payment_blocked',true);
 END;

 UPDATE public.employee_permission_overrides
 SET allowed=false WHERE organization_id=f.org_a AND employee_id=f.emp_a
 AND permission_code='sales.collect';
 BEGIN
  PERFORM private.financial_2c3b_record_cash_payment(
   f.org_a,f.sale_a,badrequest,f.sess_a,10,f.fecha_pago);
  INSERT INTO _c3b_check VALUES('permission_revoked_rejected',false);
 EXCEPTION WHEN check_violation THEN
  INSERT INTO _c3b_check VALUES('permission_revoked_rejected',true);
 END;
 UPDATE public.employee_permission_overrides
 SET allowed=true WHERE organization_id=f.org_a AND employee_id=f.emp_a
 AND permission_code='sales.collect';

 UPDATE public.sesiones_caja SET estado='CERRADA',fecha_cierre=now()
 WHERE organization_id=f.org_a AND id=f.sess_a;
 BEGIN
  PERFORM private.financial_2c3b_record_cash_payment(
   f.org_a,f.sale_a,badrequest,f.sess_a,10,f.fecha_pago);
  INSERT INTO _c3b_check VALUES('closed_session_rejected',false);
 EXCEPTION WHEN check_violation THEN
  INSERT INTO _c3b_check VALUES('closed_session_rejected',true);
 END;
 UPDATE public.sesiones_caja SET estado='ABIERTA',fecha_cierre=NULL
 WHERE organization_id=f.org_a AND id=f.sess_a;

 PERFORM set_config('TimeZone','America/Lima',true);
 endpay:=private.financial_2c3b_record_cash_payment(
   f.org_a,f.sale_a,payment2,f.sess_a,60,f.fecha_pago);
 PERFORM set_config('TimeZone','UTC',true);
 again:=private.financial_2c3b_record_cash_payment(
   f.org_a,f.sale_a,payment2,f.sess_a,60,f.fecha_pago);
 INSERT INTO _c3b_check VALUES
  ('final_cash',endpay->>'success'='true'
    AND (endpay->>'saldo')::numeric=0
    AND (endpay->>'revision')::bigint=3);
 INSERT INTO _c3b_check VALUES
  ('timezone_retry',again->>'idempotent'='true'
    AND again->>'pago_id'=endpay->>'pago_id');
 BEGIN
  PERFORM private.financial_2c3b_record_cash_payment(
   f.org_a,f.sale_a,gen_random_uuid(),f.sess_a,0.01,f.fecha_pago);
  INSERT INTO _c3b_check VALUES('overpay_after_full_rejected',false);
 EXCEPTION WHEN check_violation THEN
  INSERT INTO _c3b_check VALUES('overpay_after_full_rejected',true);
 END;
 PERFORM set_config('request.jwt.claim.sub',f.actor_b::text,true);
 BEGIN
  PERFORM private.financial_2c3b_record_cash_payment(
   f.org_a,f.sale_a,f.request_a,f.sess_a,40,f.fecha_pago);
  INSERT INTO _c3b_check VALUES('other_actor_retry_rejected',false);
 EXCEPTION WHEN insufficient_privilege THEN
  INSERT INTO _c3b_check VALUES('other_actor_retry_rejected',true);
 END;
 PERFORM set_config('request.jwt.claim.sub','',true);
 BEGIN
  PERFORM private.financial_2c3b_record_cash_payment(
   f.org_a,f.sale_a,gen_random_uuid(),f.sess_a,1,f.fecha_pago);
  INSERT INTO _c3b_check VALUES('no_jwt_denied',false);
 EXCEPTION WHEN invalid_parameter_value THEN
  INSERT INTO _c3b_check VALUES('no_jwt_denied',true);
 END;
END
$spec$;
DO $check$
BEGIN
  IF EXISTS(SELECT 1 FROM _c3b_check WHERE NOT passed) THEN
    RAISE EXCEPTION '2C3B failed checks: %',
      (SELECT string_agg(name,', ' ORDER BY name) FROM _c3b_check WHERE NOT passed);
  END IF;
END
$check$;
SELECT plan(28);
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='first_cash')), 'check_first_cash');
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='retry_same')), 'check_retry_same');
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='changed_payload_rejected')), 'check_changed_payload_rejected');
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='changed_session_rejected')), 'check_changed_session_rejected');
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='overpay_cent_rejected')), 'check_overpay_cent_rejected');
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='fraction_cent_rejected')), 'check_fraction_cent_rejected');
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='cross_tenant_rejected')), 'check_cross_tenant_rejected');
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='legacy_sale_blocked')), 'check_legacy_sale_blocked');
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='legacy_payment_blocked')), 'check_legacy_payment_blocked');
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='permission_revoked_rejected')), 'check_permission_revoked_rejected');
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='closed_session_rejected')), 'check_closed_session_rejected');
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='final_cash')), 'check_final_cash');
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='timezone_retry')), 'check_timezone_retry');
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='overpay_after_full_rejected')), 'check_overpay_after_full_rejected');
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='other_actor_retry_rejected')), 'check_other_actor_retry_rejected');
SELECT ok(((SELECT passed FROM _c3b_check WHERE name='no_jwt_denied')), 'check_no_jwt_denied');
SELECT ok((to_regprocedure('private.financial_2c3b_record_cash_payment(uuid,bigint,uuid,uuid,numeric,timestamptz)') IS NOT NULL), 'writer_installed');
SELECT ok((NOT has_function_privilege('anon','private.financial_2c3b_record_cash_payment(uuid,bigint,uuid,uuid,numeric,timestamptz)','EXECUTE') AND NOT has_function_privilege('authenticated','private.financial_2c3b_record_cash_payment(uuid,bigint,uuid,uuid,numeric,timestamptz)','EXECUTE') AND NOT has_function_privilege('service_role','private.financial_2c3b_record_cash_payment(uuid,bigint,uuid,uuid,numeric,timestamptz)','EXECUTE')), 'writer_not_public');
SELECT ok(((SELECT NOT prosecdef AND provolatile='v' FROM pg_proc WHERE oid='private.financial_2c3b_record_cash_payment(uuid,bigint,uuid,uuid,numeric,timestamptz)'::regprocedure)), 'writer_invoker');
SELECT ok(((SELECT convalidated FROM pg_constraint WHERE conrelid='private.financial_2c2_write_intents'::regclass AND conname='financial_2c3b_intent_cash_context_check')), 'intent_cash_check');
SELECT ok(((SELECT COUNT(*)=0 FROM private.financial_2c2_write_intents)), 'intents_empty');
SELECT ok(((SELECT COUNT(*)=2 FROM public.pagos_venta pv JOIN _c3 f ON pv.organization_id=f.org_a AND pv.venta_id=f.sale_a WHERE pv.metodo='efectivo' AND pv.cash_session_id=f.sess_a AND pv.cash_register_id=f.reg_a AND pv.request_id IS NULL)), 'two_cash_rows');
SELECT ok(((SELECT count(*)=3 AND sum(ev.delta_cobros)=100 AND sum(ev.delta_exigible)=100 FROM public.venta_eventos_financieros ev JOIN _c3 f ON ev.organization_id=f.org_a AND ev.venta_id=f.sale_a)), 'event_amounts');
SELECT ok(((SELECT a.apta_para_motor AND a.saldo_calculado=0 AND a.cobros_eventos=100 FROM _c3 f CROSS JOIN LATERAL private.financial_2c_audit_sale(f.org_a,f.sale_a) a)), 'ledger_balanced');
SELECT ok(((SELECT v.saldo=0 AND v.estado='pagado' FROM public.ventas v JOIN _c3 f ON v.organization_id=f.org_a AND v.id=f.sale_a)), 'sale_balance');
SELECT ok(((SELECT s.estado='ABIERTA' AND s.fecha_cierre IS NULL FROM public.sesiones_caja s JOIN _c3 f ON s.organization_id=f.org_a AND s.id=f.sess_a)), 'cash_session_open');
SELECT ok(((SELECT v.saldo=50 FROM public.ventas v JOIN _c3 f ON v.organization_id=f.org_b AND v.id=f.sale_b)), 'other_sale_untouched');
SELECT ok(((SELECT count(*)=2 FROM public.venta_operaciones_financieras op JOIN _c3 f ON op.organization_id=f.org_a AND op.venta_id=f.sale_a WHERE op.tipo='cobro' AND op.resultado='aplicado')), 'two_ops');
SELECT * FROM finish();
ROLLBACK;
