-- 2C4: integración de asignaciones de cuotas con escritor de efectivo y JWT.
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

CREATE TEMP TABLE _c4_cash_checks(name text PRIMARY KEY,passed boolean NOT NULL) ON COMMIT DROP;
DO $cases$
DECLARE f _c3%ROWTYPE; r jsonb; r2 jsonb; again jsonb; first_req uuid:=gen_random_uuid(); last_req uuid:=gen_random_uuid();
BEGIN
 SELECT * INTO f FROM _c3;
 PERFORM set_config('request.jwt.claim.sub',f.actor_a::text,true);
 r:=private.financial_2c3b_record_cash_payment(f.org_a,f.sale_a,first_req,f.sess_a,40,f.fecha_pago);
 INSERT INTO _c4_cash_checks VALUES('first_cash_partial', (r->>'saldo')::numeric=60);
 INSERT INTO _c4_cash_checks VALUES('first_quota_40',
  (SELECT COUNT(*)=1 AND SUM(m.importe_asignado)=40
     FROM public.venta_cuota_movimientos m JOIN public.venta_cuotas c ON c.id=m.cuota_id
    WHERE m.organization_id=f.org_a AND m.venta_id=f.sale_a AND c.numero=1));
 again:=private.financial_2c3b_record_cash_payment(f.org_a,f.sale_a,first_req,f.sess_a,40,f.fecha_pago);
 INSERT INTO _c4_cash_checks VALUES('cash_retry_no_reallocation',
  again->>'idempotent'='true' AND again->>'pago_id'=r->>'pago_id'
  AND (SELECT COUNT(*) FROM public.venta_cuota_movimientos
       WHERE organization_id=f.org_a AND venta_id=f.sale_a)=1);
 r2:=private.financial_2c3b_record_cash_payment(f.org_a,f.sale_a,last_req,f.sess_a,60,f.fecha_pago);
 INSERT INTO _c4_cash_checks VALUES('second_cash_closes',
  (r2->>'saldo')::numeric=0 AND (r2->>'revision')::bigint=3);
 INSERT INTO _c4_cash_checks VALUES('quota_one_splits_twice',
  (SELECT COUNT(*)=2 AND SUM(m.importe_asignado)=50
     FROM public.venta_cuota_movimientos m JOIN public.venta_cuotas c ON c.id=m.cuota_id
    WHERE m.organization_id=f.org_a AND m.venta_id=f.sale_a AND c.numero=1));
 INSERT INTO _c4_cash_checks VALUES('quota_two_receives_50',
  (SELECT COUNT(*)=1 AND SUM(m.importe_asignado)=50
     FROM public.venta_cuota_movimientos m JOIN public.venta_cuotas c ON c.id=m.cuota_id
    WHERE m.organization_id=f.org_a AND m.venta_id=f.sale_a AND c.numero=2));
 PERFORM set_config('request.jwt.claim.sub','',true);
END $cases$;
DO $validate$
BEGIN
 IF EXISTS(SELECT 1 FROM _c4_cash_checks WHERE NOT passed) THEN
   RAISE EXCEPTION '2C4 cash allocation failed: %',
     (SELECT string_agg(name,', ' ORDER BY name) FROM _c4_cash_checks WHERE NOT passed);
 END IF;
END $validate$;
SELECT plan(14);
SELECT ok(((SELECT passed FROM _c4_cash_checks WHERE name='first_cash_partial')),'first_cash_partial');
SELECT ok(((SELECT passed FROM _c4_cash_checks WHERE name='first_quota_40')),'first_quota_40');
SELECT ok(((SELECT passed FROM _c4_cash_checks WHERE name='cash_retry_no_reallocation')),'cash_retry_no_reallocation');
SELECT ok(((SELECT passed FROM _c4_cash_checks WHERE name='second_cash_closes')),'second_cash_closes');
SELECT ok(((SELECT passed FROM _c4_cash_checks WHERE name='quota_one_splits_twice')),'quota_one_splits_twice');
SELECT ok(((SELECT passed FROM _c4_cash_checks WHERE name='quota_two_receives_50')),'quota_two_receives_50');
SELECT ok(((SELECT COUNT(*)=2 AND SUM(monto)=100 FROM public.pagos_venta p JOIN _c3 f ON p.organization_id=f.org_a AND p.venta_id=f.sale_a)),'no_duplicate_cash_income');
SELECT ok(((SELECT COUNT(*)=2 FROM public.pagos_venta p JOIN _c3 f ON p.organization_id=f.org_a AND p.venta_id=f.sale_a WHERE p.cash_session_id=f.sess_a AND p.cash_register_id=f.reg_a AND p.metodo='efectivo')),'cash_belongs_session');
SELECT ok(((SELECT COUNT(*)=3 AND SUM(importe_asignado)=100 FROM public.venta_cuota_movimientos m JOIN _c3 f ON m.organization_id=f.org_a AND m.venta_id=f.sale_a)),'three_quota_moves');
SELECT ok(((SELECT COUNT(*)=2 AND COUNT(*) FILTER (WHERE estado='pagada')=2 FROM _c3 f CROSS JOIN LATERAL private.financial_2c4_installments(f.org_a,f.sale_a,NULL))),'two_paid_quotas');
SELECT ok(((SELECT a.apta_para_motor AND a.saldo_calculado=0 FROM _c3 f CROSS JOIN LATERAL private.financial_2c_audit_sale(f.org_a,f.sale_a) a)),'ledger_matches_cash');
SELECT ok(((SELECT saldo_pendiente=50 FROM public.venta_cuentas_financieras a JOIN _c3 f ON a.organization_id=f.org_b AND a.venta_id=f.sale_b)),'no_mismatch_tenant');
SELECT ok(((SELECT COUNT(*)=0 FROM private.financial_2c2_write_intents)),'intents_clean');
SELECT ok((NOT has_function_privilege('authenticated','private.financial_2c4_installments(uuid,bigint,date)','EXECUTE')),'preflight_unexposed');
SELECT * FROM finish();
ROLLBACK;
