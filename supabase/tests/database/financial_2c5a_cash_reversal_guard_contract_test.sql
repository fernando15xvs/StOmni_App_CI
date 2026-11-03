-- 2C5A: rechazo de reversos de caja y compatibilidad transferencias/efectivo.
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

WITH cr AS (
 INSERT INTO public.venta_cronogramas(organization_id,venta_id,version,estado)
 SELECT org_a,sale_a,1,'vigente' FROM _c3
 RETURNING id,organization_id,venta_id
)
INSERT INTO public.venta_cuotas(
 organization_id,venta_id,cronograma_id,numero,vencimiento,
 importe_original,importe_vigente
)
SELECT cr.organization_id,cr.venta_id,cr.id,n,
 (now() AT TIME ZONE 'America/Lima')::date+n,
 50,50
FROM cr CROSS JOIN (VALUES(1),(2)) AS q(n);


CREATE TEMP TABLE _c5_cash_check(name text PRIMARY KEY,passed boolean NOT NULL) ON COMMIT DROP;
DO $scenario$
DECLARE
 f _c3%ROWTYPE;
 cash jsonb;
 transfer jsonb;
 rev jsonb;
 cash_ev uuid;
 transfer_ev uuid;
 rev_req uuid:=gen_random_uuid();
 request_cash uuid:=gen_random_uuid();
 request_transfer uuid:=gen_random_uuid();
BEGIN
 SELECT * INTO f FROM _c3;
 PERFORM set_config('request.jwt.claim.sub',f.actor_a::text,true);
 cash:=private.financial_2c3b_record_cash_payment(
  f.org_a,f.sale_a,request_cash,f.sess_a,20,f.fecha_pago);
 SELECT id INTO cash_ev FROM public.venta_eventos_financieros
  WHERE organization_id=f.org_a AND venta_id=f.sale_a
    AND operacion_id=(cash->>'operacion_id')::uuid AND tipo='cobro';
 PERFORM set_config('request.jwt.claim.sub','',true);
 BEGIN
  PERFORM private.financial_2c5a_reverse_transfer_payment(
    f.org_a,f.sale_a,rev_req,cash_ev,f.fecha_pago);
  INSERT INTO _c5_cash_check VALUES('cash_reverse_denied',false);
 EXCEPTION WHEN check_violation THEN
  INSERT INTO _c5_cash_check VALUES('cash_reverse_denied',true);
 END;
 INSERT INTO _c5_cash_check VALUES('cash_remains_20',
  (SELECT c.cobros_netos=20 AND c.saldo_pendiente=80
    FROM public.venta_cuentas_financieras c
    WHERE c.organization_id=f.org_a AND c.venta_id=f.sale_a));
 INSERT INTO _c5_cash_check VALUES('cash_session_untouched',
  (SELECT estado='ABIERTA' AND fecha_cierre IS NULL
   FROM public.sesiones_caja WHERE organization_id=f.org_a AND id=f.sess_a));
 INSERT INTO _c5_cash_check VALUES('no_cash_reversal_event',
  (SELECT COUNT(*)=0 FROM public.venta_eventos_financieros
   WHERE organization_id=f.org_a AND venta_id=f.sale_a AND tipo='reverso'));

 transfer:=private.financial_2c2_record_transfer_payment(
  f.org_a,f.sale_a,request_transfer,'PEN',30,f.fecha_pago);
 SELECT id INTO transfer_ev FROM public.venta_eventos_financieros
  WHERE organization_id=f.org_a AND venta_id=f.sale_a
    AND operacion_id=(transfer->>'operacion_id')::uuid AND tipo='cobro';
 rev:=private.financial_2c5a_reverse_transfer_payment(
  f.org_a,f.sale_a,rev_req,transfer_ev,f.fecha_pago);
 INSERT INTO _c5_cash_check VALUES('transfer_reversible_after_cash',
   (rev->>'saldo')::numeric=80 AND (rev->>'importe')::numeric=30);
 INSERT INTO _c5_cash_check VALUES('cash_still_collected_20',
   (SELECT apta_para_motor AND cobros_eventos=20 AND saldo_calculado=80
   FROM private.financial_2c_audit_sale(f.org_a,f.sale_a)));
 INSERT INTO _c5_cash_check VALUES('cash_allocations_still_20',
   (SELECT SUM(m.importe_asignado)=20
    FROM public.venta_cuota_movimientos m
    JOIN public.venta_eventos_financieros ev
      ON m.evento_id=ev.id
    WHERE m.organization_id=f.org_a AND m.venta_id=f.sale_a
      AND ev.id=cash_ev));
 INSERT INTO _c5_cash_check VALUES('reversed_transfer_allocations_negative30',
   (SELECT SUM(m.importe_asignado)=-30
    FROM public.venta_cuota_movimientos m
    WHERE m.organization_id=f.org_a AND m.venta_id=f.sale_a
      AND m.evento_id=(rev->>'evento_reverso_id')::uuid));
 INSERT INTO _c5_cash_check VALUES('gross_payments_50_preserved',
   (SELECT COUNT(*)=2 AND SUM(monto)=50
     FROM public.pagos_venta
     WHERE organization_id=f.org_a AND venta_id=f.sale_a));
END;
$scenario$;
DO $check$
BEGIN
 IF EXISTS(SELECT 1 FROM _c5_cash_check WHERE NOT passed) THEN
  RAISE EXCEPTION '2C5A cash boundary failures: %',
    (SELECT string_agg(name,', ' ORDER BY name) FROM _c5_cash_check WHERE NOT passed);
 END IF;
END;
$check$;
SELECT plan(14);
SELECT ok(((SELECT passed FROM _c5_cash_check WHERE name='cash_reverse_denied')),'cash_reverse_denied');
SELECT ok(((SELECT passed FROM _c5_cash_check WHERE name='cash_remains_20')),'cash_remains_20');
SELECT ok(((SELECT passed FROM _c5_cash_check WHERE name='cash_session_untouched')),'cash_session_untouched');
SELECT ok(((SELECT passed FROM _c5_cash_check WHERE name='no_cash_reversal_event')),'no_cash_reversal_event');
SELECT ok(((SELECT passed FROM _c5_cash_check WHERE name='transfer_reversible_after_cash')),'transfer_reversible_after_cash');
SELECT ok(((SELECT passed FROM _c5_cash_check WHERE name='cash_still_collected_20')),'cash_still_collected_20');
SELECT ok(((SELECT passed FROM _c5_cash_check WHERE name='cash_allocations_still_20')),'cash_allocations_still_20');
SELECT ok(((SELECT passed FROM _c5_cash_check WHERE name='reversed_transfer_allocations_negative30')),'reversed_transfer_allocations_negative30');
SELECT ok(((SELECT passed FROM _c5_cash_check WHERE name='gross_payments_50_preserved')),'gross_payments_50_preserved');
SELECT ok(((SELECT COUNT(*)=2 FROM public.venta_eventos_financieros ev JOIN _c3 f ON ev.organization_id=f.org_a AND ev.venta_id=f.sale_a WHERE ev.tipo='cobro')),'two_cash_allocation_originals');
SELECT ok(((SELECT COUNT(*)=1 FROM public.venta_eventos_financieros ev JOIN _c3 f ON ev.organization_id=f.org_a AND ev.venta_id=f.sale_a WHERE ev.tipo='reverso')),'one_transfer_reversal');
SELECT ok(((SELECT COUNT(*)=0 FROM private.financial_2c2_write_intents)),'no_leaked_intents');
SELECT ok(((SELECT SUM(saldo_pendiente)=80 FROM _c3 f CROSS JOIN LATERAL private.financial_2c4_installments(f.org_a,f.sale_a,NULL))),'quota_sum80_outstanding');
SELECT ok(((SELECT COUNT(*)=2 FROM public.pagos_venta pv JOIN _c3 f ON pv.organization_id=f.org_a AND pv.venta_id=f.sale_a)),'source_payment_not_deleted');
SELECT * FROM finish();
ROLLBACK;
