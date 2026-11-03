-- 2C3A: permisos empleados y caja sobre datos sintéticos. Transacción reversible.
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
CREATE TEMP TABLE _c3_checks(key text PRIMARY KEY,passed boolean NOT NULL) ON COMMIT DROP;
DO $tests$
DECLARE f _c3%ROWTYPE; r record;
BEGIN
 SELECT * INTO f FROM _c3;
 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_a,20,f.fecha_pago);
 INSERT INTO _c3_checks VALUES ('default_deny',NOT r.permitido AND r.codigo='permiso_cobro_denegado');

 -- Una autorización explícita para operador habilita únicamente el preflight.
 INSERT INTO public.employee_permission_overrides(
 organization_id,employee_id,permission_code,allowed)
 VALUES(f.org_a,f.emp_a,'sales.collect',true);
 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_a,20,f.fecha_pago);
 INSERT INTO _c3_checks VALUES ('explicit_allow',
  r.permitido AND r.codigo='preflight_efectivo_aprobado_sin_registro'
  AND r.cash_register_id=f.reg_a AND r.saldo_actual=100
  AND r.saldo_despues=80 AND r.revision=1);

 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_a,100.01,f.fecha_pago);
 INSERT INTO _c3_checks VALUES ('overpay_cent',NOT r.permitido AND r.codigo='monto_supera_saldo');

 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_a,20.001,f.fecha_pago);
 INSERT INTO _c3_checks VALUES ('fraction_cent',NOT r.permitido AND r.codigo='monto_invalido_centavos');

 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_a,0,f.fecha_pago);
 INSERT INTO _c3_checks VALUES ('zero_blocked',NOT r.permitido AND r.codigo='monto_invalido_centavos');

 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_b,f.sess_a,20,f.fecha_pago);
 INSERT INTO _c3_checks VALUES ('other_actor',NOT r.permitido AND r.codigo='sesion_no_pertenece_actor');

 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_b,20,f.fecha_pago);
 INSERT INTO _c3_checks VALUES ('cross_tenant_session',NOT r.permitido AND r.codigo='sesion_fuera_organizacion');

 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_b,f.sale_b,f.request_a,f.actor_a,f.sess_a,20,f.fecha_pago);
 INSERT INTO _c3_checks VALUES ('cross_tenant_sale',NOT r.permitido AND r.codigo='sesion_fuera_organizacion');

 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_a,20,now()+interval '1 hour');
 INSERT INTO _c3_checks VALUES ('future_date',NOT r.permitido AND r.codigo='fecha_futura');

 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_a,20,now()-interval '3 hours');
 INSERT INTO _c3_checks VALUES ('before_cash_open',NOT r.permitido AND r.codigo='fecha_anterior_apertura_caja');

 UPDATE public.sesiones_caja SET estado='CERRADA',fecha_cierre=now()
 WHERE id=f.sess_a;
 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_a,20,f.fecha_pago);
 INSERT INTO _c3_checks VALUES ('closed_session',NOT r.permitido AND r.codigo='sesion_cerrada');
 UPDATE public.sesiones_caja SET estado='ABIERTA',fecha_cierre=NULL WHERE id=f.sess_a;

 UPDATE public.empleados SET employment_status='inactive' WHERE id=f.emp_a;
 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_a,20,f.fecha_pago);
 INSERT INTO _c3_checks VALUES ('inactive_employee',NOT r.permitido AND r.codigo='empleado_inactivo_otra_sucursal');
 UPDATE public.empleados SET employment_status='active' WHERE id=f.emp_a;

 UPDATE public.employee_permission_overrides SET allowed=false
 WHERE organization_id=f.org_a AND employee_id=f.emp_a AND permission_code='sales.collect';
 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_a,20,f.fecha_pago);
 INSERT INTO _c3_checks VALUES ('explicit_deny',NOT r.permitido AND r.codigo='permiso_cobro_denegado');

 INSERT INTO public.roles(organization_id,code,name,status)
 VALUES(f.org_a,'admin','Admin ficticio','active') RETURNING id INTO f.role_a;
 INSERT INTO public.employee_roles(organization_id,employee_id,role_id)
 VALUES(f.org_a,f.emp_a,f.role_a);
 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_a,20,f.fecha_pago);
 INSERT INTO _c3_checks VALUES ('admin_role_allow',r.permitido);

 UPDATE public.permissions SET is_active=false WHERE code='sales.collect';
 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_a,20,f.fecha_pago);
 INSERT INTO _c3_checks VALUES ('permission_disabled',NOT r.permitido AND r.codigo='permiso_cobrar_desactivado');
 UPDATE public.permissions SET is_active=true WHERE code='sales.collect';

 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_a,NULL,f.fecha_pago);
 INSERT INTO _c3_checks VALUES ('null_amount',NOT r.permitido AND r.codigo='payload_incompleto');
 SELECT * INTO r FROM private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_a,20,NULL);
 INSERT INTO _c3_checks VALUES ('null_date',NOT r.permitido AND r.codigo='payload_incompleto');
END;
$tests$;
-- En PostgreSQL la replica se configura con SET LOCAL a nivel de transacción,
-- no con set_config() dentro de un bloque DO. Solo se alteran fixtures reversibles.
SET LOCAL session_replication_role=replica;
UPDATE public.cash_registers SET status='inactive'
 WHERE id=(SELECT reg_a FROM _c3);
SET LOCAL session_replication_role=origin;
INSERT INTO _c3_checks(key,passed)
SELECT 'inactive_register',NOT r.permitido AND r.codigo='caja_o_sucursal_inactiva'
FROM _c3 f
CROSS JOIN LATERAL private.financial_2c3_cash_preflight(
 f.org_a,f.sale_a,f.request_a,f.actor_a,f.sess_a,20,f.fecha_pago
) r;
SET LOCAL session_replication_role=replica;
UPDATE public.cash_registers SET status='active'
 WHERE id=(SELECT reg_a FROM _c3);
SET LOCAL session_replication_role=origin;
DO $verify$
BEGIN
 IF EXISTS(SELECT 1 FROM _c3_checks WHERE NOT passed) THEN
   RAISE EXCEPTION '2C3 cash preflight failed: %',
     (SELECT string_agg(key,', ' ORDER BY key) FROM _c3_checks WHERE NOT passed);
 END IF;
END;
$verify$;
SELECT plan(26);
SELECT ok((to_regprocedure('private.financial_2c3_cash_preflight(uuid,bigint,uuid,uuid,uuid,numeric,timestamptz)') IS NOT NULL),'installed');
SELECT ok((EXISTS(SELECT 1 FROM public.permissions WHERE code='sales.collect' AND category='sales' AND is_active)),'permission_seeded');
SELECT ok((NOT has_function_privilege('anon','private.financial_2c3_cash_preflight(uuid,bigint,uuid,uuid,uuid,numeric,timestamptz)','EXECUTE') AND NOT has_function_privilege('authenticated','private.financial_2c3_cash_preflight(uuid,bigint,uuid,uuid,uuid,numeric,timestamptz)','EXECUTE') AND NOT has_function_privilege('service_role','private.financial_2c3_cash_preflight(uuid,bigint,uuid,uuid,uuid,numeric,timestamptz)','EXECUTE')),'restricted_execution');
SELECT ok(((SELECT provolatile='s' AND NOT prosecdef FROM pg_proc WHERE oid='private.financial_2c3_cash_preflight(uuid,bigint,uuid,uuid,uuid,numeric,timestamptz)'::regprocedure)),'stable_invoker');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='default_deny')),'default_deny');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='explicit_allow')),'explicit_allow');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='overpay_cent')),'overpay_cent');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='fraction_cent')),'fraction_cent');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='zero_blocked')),'zero_blocked');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='other_actor')),'other_actor');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='cross_tenant_session')),'cross_tenant_session');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='cross_tenant_sale')),'cross_tenant_sale');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='future_date')),'future_date');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='before_cash_open')),'before_cash_open');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='closed_session')),'closed_session');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='inactive_register')),'inactive_register');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='inactive_employee')),'inactive_employee');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='explicit_deny')),'explicit_deny');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='admin_role_allow')),'admin_role_allow');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='permission_disabled')),'permission_disabled');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='null_amount')),'null_amount');
SELECT ok(((SELECT passed FROM _c3_checks WHERE key='null_date')),'null_date');
SELECT ok(((SELECT COUNT(*)=0 FROM public.pagos_venta pv JOIN _c3 f ON pv.organization_id=f.org_a AND pv.venta_id=f.sale_a)),'no_real_payments');
SELECT ok(((SELECT COUNT(*)=1 FROM public.venta_eventos_financieros ev JOIN _c3 f ON ev.organization_id=f.org_a AND ev.venta_id=f.sale_a)),'no_new_events');
SELECT ok(((SELECT COUNT(*)=0 FROM private.financial_2c2_write_intents)),'no_cash_intents');
SELECT ok(((SELECT cf.saldo_pendiente=100 AND cf.cobros_netos=0 FROM public.venta_cuentas_financieras cf JOIN _c3 f ON cf.organization_id=f.org_a AND cf.venta_id=f.sale_a)),'no_balance_change');
SELECT * FROM finish();
ROLLBACK;
