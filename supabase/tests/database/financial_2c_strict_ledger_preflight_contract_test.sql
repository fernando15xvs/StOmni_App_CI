-- 2C1 pgTAP; datos de ambas empresas ficticios y transacción reversible.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
CREATE TEMP TABLE _fin2c_fixture (
  org_a uuid,org_b uuid,sale_a bigint,sale_b bigint,
  payment_id bigint,op_id uuid,request_a uuid
) ON COMMIT DROP;
INSERT INTO _fin2c_fixture(org_a,org_b,sale_a,sale_b,request_a)
VALUES(gen_random_uuid(),gen_random_uuid(),-8400002001,-8400002002,gen_random_uuid());
SET LOCAL session_replication_role=replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org_a,'2C fixture A','PE','PEN','America/Lima' FROM _fin2c_fixture
UNION ALL SELECT org_b,'2C fixture B','PE','PEN','America/Lima' FROM _fin2c_fixture;
INSERT INTO public.ventas(id,organization_id,total,saldo,estado,fecha,monto_notas_credito)
SELECT sale_a,org_a,100,60,'pendiente',now(),0 FROM _fin2c_fixture
UNION ALL SELECT sale_b,org_b,100,100,'pendiente',now(),0 FROM _fin2c_fixture;
WITH ins AS (
 INSERT INTO public.pagos_venta(venta_id,organization_id,metodo,monto,fecha)
 SELECT sale_a,org_a,'transferencia',40,now() FROM _fin2c_fixture RETURNING id
) UPDATE _fin2c_fixture SET payment_id=(SELECT id FROM ins);
SET LOCAL session_replication_role=origin;
INSERT INTO public.venta_cuentas_financieras
 (organization_id,venta_id,moneda,estado_conciliacion,exigible,cobros_netos,saldo_pendiente,revision)
SELECT org_a,sale_a,'PEN','pendiente',100,40,60,1 FROM _fin2c_fixture;
WITH ins AS (
 INSERT INTO public.venta_operaciones_financieras
 (organization_id,venta_id,tipo,request_id,payload_hash,resultado,metadata_apertura)
 SELECT org_a,sale_a,'apertura',request_a,'synthetic-ledger','aplicado',
 '{"cobertura":"fuentes_actuales_no_historial_exhaustivo"}'::jsonb
 FROM _fin2c_fixture RETURNING id
) UPDATE _fin2c_fixture SET op_id=(SELECT id FROM ins);
INSERT INTO public.venta_eventos_financieros
 (organization_id,venta_id,operacion_id,secuencia,tipo,delta_exigible,delta_cobros,efectivo_at,pago_id)
SELECT org_a,sale_a,op_id,1,'apertura',100,0,now(),NULL FROM _fin2c_fixture
UNION ALL SELECT org_a,sale_a,op_id,2,'cobro',0,40,now(),payment_id FROM _fin2c_fixture;
SELECT plan(26);
SELECT ok((to_regprocedure('private.financial_2c_audit_sale(uuid,bigint)') IS NOT NULL), 'auditoria instalada');
SELECT ok((to_regprocedure('private.financial_2c_preflight_payment(uuid,bigint,uuid,text,numeric,text,timestamptz)') IS NOT NULL), 'preflight instalado');
SELECT ok((NOT has_function_privilege('authenticated','private.financial_2c_audit_sale(uuid,bigint)','EXECUTE') AND NOT has_function_privilege('anon','private.financial_2c_audit_sale(uuid,bigint)','EXECUTE')), 'auditoria privada');
SELECT ok((NOT has_function_privilege('authenticated','private.financial_2c_preflight_payment(uuid,bigint,uuid,text,numeric,text,timestamptz)','EXECUTE')), 'preflight privado');
SELECT ok(((SELECT bool_and(NOT prosecdef AND provolatile='s') FROM pg_proc WHERE oid IN ('private.financial_2c_audit_sale(uuid,bigint)'::regprocedure,'private.financial_2c_preflight_payment(uuid,bigint,uuid,text,numeric,text,timestamptz)'::regprocedure))), 'funciones sin escritura ni escalamiento');
SELECT ok(((SELECT NOT apta_para_motor AND bloqueos @> ARRAY['cuenta_no_conciliada','cobertura_historica_no_certificada'] FROM private.financial_2c_audit_sale((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture)))), 'cuenta pendiente rechazada');
SELECT ok(((SELECT NOT permitido AND codigo='conciliacion_no_aprobada' FROM private.financial_2c_preflight_payment((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture),gen_random_uuid(),'PEN',10,'transferencia',now()))), 'cobro legacy bloqueado');
SELECT ok(((SELECT saldo_calculado=60 AND exigible_eventos=100 AND cobros_eventos=40 FROM private.financial_2c_audit_sale((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture)))), 'calculo canonico E-C');
SELECT ok(((SELECT NOT permitido AND codigo='monto_invalido_centavos' FROM private.financial_2c_preflight_payment((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture),gen_random_uuid(),'PEN',10.001,'transferencia',now()))), 'no fracciones de centavo');
SELECT ok(((SELECT NOT permitido AND codigo='monto_invalido_centavos' FROM private.financial_2c_preflight_payment((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture),gen_random_uuid(),'PEN',0,'transferencia',now()))), 'no cero');
SELECT ok(((SELECT NOT permitido AND codigo='monto_invalido_centavos' FROM private.financial_2c_preflight_payment((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture),gen_random_uuid(),'PEN',-1,'transferencia',now()))), 'no negativo');
SELECT ok(((SELECT NOT permitido AND codigo='payload_incompleto' FROM private.financial_2c_preflight_payment(NULL,(SELECT sale_a FROM _fin2c_fixture),gen_random_uuid(),'PEN',10,'transferencia',now()))), 'tenant NULL');
SELECT ok(((SELECT NOT permitido AND codigo='cuenta_no_abierta' FROM private.financial_2c_preflight_payment((SELECT org_b FROM _fin2c_fixture),(SELECT sale_b FROM _fin2c_fixture),gen_random_uuid(),'PEN',10,'transferencia',now()))), 'tenant sin cuenta aislado');
SELECT ok(((SELECT NOT apta_para_motor AND bloqueos @> ARRAY['cuenta_no_abierta'] FROM private.financial_2c_audit_sale((SELECT org_b FROM _fin2c_fixture),(SELECT sale_b FROM _fin2c_fixture)))), 'no inventa cuentas externas');
UPDATE public.venta_cuentas_financieras SET estado_conciliacion='conciliada' WHERE (organization_id,venta_id) IN (SELECT org_a,sale_a FROM _fin2c_fixture);
SELECT ok(((SELECT NOT apta_para_motor AND bloqueos @> ARRAY['cobertura_historica_no_certificada'] FROM private.financial_2c_audit_sale((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture)))), 'conciliada sin historia permanece bloqueada');
UPDATE public.venta_operaciones_financieras SET metadata_apertura='{"cobertura":"historico_auditado"}'::jsonb WHERE id=(SELECT op_id FROM _fin2c_fixture);
SELECT ok(((SELECT apta_para_motor AND cardinality(bloqueos)=0 FROM private.financial_2c_audit_sale((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture)))), 'fixture completa auditada');
SELECT ok(((SELECT permitido AND codigo='preflight_aprobado_sin_registro' AND saldo_actual=60 AND saldo_despues=0 FROM private.financial_2c_preflight_payment((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture),gen_random_uuid(),'PEN',60,'transferencia',now()))), 'monto exacto permitido sin escritura');
SELECT ok(((SELECT permitido AND saldo_despues=59.99 FROM private.financial_2c_preflight_payment((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture),gen_random_uuid(),'PEN',0.01,'transferencia',now()))), 'centavo exacto');
SELECT ok(((SELECT NOT permitido AND codigo='monto_supera_saldo' FROM private.financial_2c_preflight_payment((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture),gen_random_uuid(),'PEN',60.01,'transferencia',now()))), 'sobrepago de un centavo');
SELECT ok(((SELECT NOT permitido AND codigo='moneda_distinta' FROM private.financial_2c_preflight_payment((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture),gen_random_uuid(),'USD',10,'transferencia',now()))), 'no moneda distinta');
SELECT ok(((SELECT NOT permitido AND codigo='caja_no_integrada' FROM private.financial_2c_preflight_payment((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture),gen_random_uuid(),'PEN',10,'EFECTIVO',now()))), 'efectivo no integrado');
INSERT INTO public.venta_operaciones_financieras(organization_id,venta_id,tipo,request_id,payload_hash,resultado) SELECT org_a,sale_a,'cobro',request_a,'retry-fixture','pendiente' FROM _fin2c_fixture;
SELECT ok(((SELECT NOT permitido AND codigo='request_existente_requiere_resolucion' FROM private.financial_2c_preflight_payment((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture),(SELECT request_a FROM _fin2c_fixture),'PEN',10,'transferencia',now()))), 'request previo no se duplica');
SET LOCAL session_replication_role=replica;
UPDATE public.pagos_venta SET monto=39 WHERE id=(SELECT payment_id FROM _fin2c_fixture);
SET LOCAL session_replication_role=origin;
SELECT ok(((SELECT NOT apta_para_motor AND bloqueos @> ARRAY['origenes_pago_no_conciliados'] FROM private.financial_2c_audit_sale((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture)))), 'origen de cobro y evento deben cuadrar');
SELECT ok(((SELECT NOT permitido AND codigo='conciliacion_no_aprobada' FROM private.financial_2c_preflight_payment((SELECT org_a FROM _fin2c_fixture),(SELECT sale_a FROM _fin2c_fixture),gen_random_uuid(),'PEN',10,'transferencia',now()))), 'preflight bloqueado por pagos inconsistentes');
SELECT ok(((SELECT COUNT(*)=2 FROM public.venta_eventos_financieros ev JOIN _fin2c_fixture f ON ev.organization_id=f.org_a AND ev.venta_id=f.sale_a)), 'sin eventos adicionales');
SELECT ok(((SELECT COUNT(*)=1 FROM public.venta_cuentas_financieras cf JOIN _fin2c_fixture f ON cf.organization_id=f.org_a AND cf.venta_id=f.sale_a)), 'sin nuevas cuentas');
SELECT * FROM finish();
ROLLBACK;
