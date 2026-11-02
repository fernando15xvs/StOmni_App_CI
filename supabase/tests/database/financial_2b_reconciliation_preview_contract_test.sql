BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

CREATE TEMP TABLE _fin2b_fixtures (
  org_a uuid NOT NULL,
  org_b uuid NOT NULL,
  venta_a bigint NOT NULL,
  venta_b bigint NOT NULL
) ON COMMIT DROP;

INSERT INTO _fin2b_fixtures VALUES
  (gen_random_uuid(),gen_random_uuid(),-8300001001,-8300001002);

-- Solo fixtures: evita triggers de flujos de ventas/caja que requieren una
-- sesión real. Restablece el rol de replicación antes de las comprobaciones.
SET LOCAL session_replication_role = replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org_a,'2B fixture A','PE','PEN','America/Lima' FROM _fin2b_fixtures
UNION ALL
SELECT org_b,'2B fixture B','PE','PEN','America/Lima' FROM _fin2b_fixtures;
INSERT INTO public.ventas(id,organization_id,total,saldo,estado,fecha,monto_notas_credito)
SELECT venta_a,org_a,100,80,'pendiente',now(),0 FROM _fin2b_fixtures
UNION ALL
SELECT venta_b,org_b,50,50,'pendiente',now(),0 FROM _fin2b_fixtures;
INSERT INTO public.pagos_venta(venta_id,organization_id,metodo,monto,fecha)
SELECT venta_a,org_a,'efectivo',20,now() FROM _fin2b_fixtures;
SET LOCAL session_replication_role = origin;

SELECT plan(15);
SELECT ok(to_regprocedure('private.financial_2b_preview_sales(uuid,integer)') IS NOT NULL,'función de preconciliación instalada');
SELECT ok(NOT has_function_privilege('anon','private.financial_2b_preview_sales(uuid,integer)','EXECUTE')
 AND NOT has_function_privilege('authenticated','private.financial_2b_preview_sales(uuid,integer)','EXECUTE')
 AND NOT has_function_privilege('service_role','private.financial_2b_preview_sales(uuid,integer)','EXECUTE'),
 'diagnóstico interno no expuesto a clientes ni servicio por accidente');
SELECT ok((SELECT NOT prosecdef AND provolatile='s'
 FROM pg_proc WHERE oid='private.financial_2b_preview_sales(uuid,integer)'::regprocedure),'invoker y estable de solo lectura');
SELECT is((SELECT COUNT(*) FROM private.financial_2b_preview_sales(
  (SELECT org_a FROM _fin2b_fixtures), 500
)),1::bigint,'selecciona solo ventas del tenant A');
SELECT is((SELECT COUNT(*) FROM private.financial_2b_preview_sales((SELECT org_b FROM _fin2b_fixtures),500)),1::bigint,'tenant B conserva su propio resultado');
SELECT is((SELECT COUNT(*) FROM private.financial_2b_preview_sales((SELECT org_a FROM _fin2b_fixtures),0)),0::bigint,'limite cero no devuelve resultados');
SELECT is((SELECT COUNT(*) FROM private.financial_2b_preview_sales(gen_random_uuid(),500)),0::bigint,'tenant desconocido no obtiene ventas');
SELECT ok((SELECT total_venta=100 AND cobros_registrados=20 AND saldo_guardado=80 AND saldo_estimado=80 AND moneda='PEN' AND estado_preconciliacion='lista' AND cardinality(motivos)=0 FROM private.financial_2b_preview_sales(
  (SELECT org_a FROM _fin2b_fixtures), 500
)), 'venta exacta con pago conserva saldos sin doble conteo');
SET LOCAL session_replication_role = replica;
UPDATE public.ventas SET saldo=79 WHERE id=(SELECT venta_a FROM _fin2b_fixtures);
SET LOCAL session_replication_role = origin;
SELECT ok((SELECT estado_preconciliacion='bloqueada' AND motivos @> ARRAY['saldo_legacy_no_cuadra']::text[] FROM private.financial_2b_preview_sales(
  (SELECT org_a FROM _fin2b_fixtures), 500
)), 'saldo discrepante bloquea migración');
SET LOCAL session_replication_role = replica;
UPDATE public.ventas SET saldo=80 WHERE id=(SELECT venta_a FROM _fin2b_fixtures);
SET LOCAL session_replication_role = origin;
SET LOCAL session_replication_role = replica;
UPDATE public.pagos_venta SET monto=20.005 WHERE venta_id=(SELECT venta_a FROM _fin2b_fixtures);
SET LOCAL session_replication_role = origin;
SELECT ok((SELECT estado_preconciliacion='bloqueada' AND motivos @> ARRAY['pagos_incompletos_o_invalidos']::text[] FROM private.financial_2b_preview_sales(
  (SELECT org_a FROM _fin2b_fixtures), 500
)), 'fracción de centavo bloqueada');
SET LOCAL session_replication_role = replica;
UPDATE public.pagos_venta SET monto=20,fecha=NULL WHERE venta_id=(SELECT venta_a FROM _fin2b_fixtures);
SET LOCAL session_replication_role = origin;
SELECT ok((SELECT estado_preconciliacion='bloqueada' AND motivos @> ARRAY['pagos_incompletos_o_invalidos']::text[] FROM private.financial_2b_preview_sales(
  (SELECT org_a FROM _fin2b_fixtures), 500
)), 'pago sin fecha económica bloqueado');
SET LOCAL session_replication_role = replica;
UPDATE public.pagos_venta SET monto=20,fecha=now() WHERE venta_id=(SELECT venta_a FROM _fin2b_fixtures);
SET LOCAL session_replication_role = origin;
SET LOCAL session_replication_role = replica;
UPDATE public.ventas SET monto_notas_credito=1 WHERE id=(SELECT venta_a FROM _fin2b_fixtures);
SET LOCAL session_replication_role = origin;
SELECT ok((SELECT estado_preconciliacion='bloqueada' AND motivos @> ARRAY['ajustes_nc_requieren_conciliacion_individual']::text[] FROM private.financial_2b_preview_sales(
  (SELECT org_a FROM _fin2b_fixtures), 500
)), 'NC existente no es sumada sin verificar transiciones');
SET LOCAL session_replication_role = replica;
UPDATE public.ventas SET monto_notas_credito=0 WHERE id=(SELECT venta_a FROM _fin2b_fixtures);
SET LOCAL session_replication_role = origin;
SET LOCAL session_replication_role = replica;
UPDATE public.ventas SET estado='anulado' WHERE id=(SELECT venta_a FROM _fin2b_fixtures);
SET LOCAL session_replication_role = origin;
SELECT ok((SELECT estado_preconciliacion='bloqueada' AND motivos @> ARRAY['estado_venta_no_conciliable']::text[] FROM private.financial_2b_preview_sales(
  (SELECT org_a FROM _fin2b_fixtures), 500
)), 'venta anulada se bloquea');
SET LOCAL session_replication_role = replica;
UPDATE public.ventas SET estado='pendiente' WHERE id=(SELECT venta_a FROM _fin2b_fixtures);
SET LOCAL session_replication_role = origin;
SET LOCAL session_replication_role = replica;
INSERT INTO public.pagos_venta(venta_id,organization_id,metodo,monto,fecha) SELECT venta_a,org_a,'efectivo',90,now() FROM _fin2b_fixtures;
SET LOCAL session_replication_role = origin;
SELECT ok((SELECT estado_preconciliacion='bloqueada' AND motivos @> ARRAY['pagos_fuera_del_exigible']::text[] FROM private.financial_2b_preview_sales(
  (SELECT org_a FROM _fin2b_fixtures), 500
)), 'sobrepago no se abre silenciosamente');
SET LOCAL session_replication_role = replica;
DELETE FROM public.pagos_venta WHERE venta_id=(SELECT venta_a FROM _fin2b_fixtures) AND monto=90;
SET LOCAL session_replication_role = origin;
SET LOCAL session_replication_role = replica;
INSERT INTO public.venta_cuentas_financieras(organization_id,venta_id,moneda,exigible,cobros_netos,saldo_pendiente,estado_conciliacion) SELECT org_a,venta_a,'PEN',100,20,80,'pendiente' FROM _fin2b_fixtures;
SET LOCAL session_replication_role = origin;
SELECT ok((SELECT estado_preconciliacion='bloqueada' AND motivos @> ARRAY['cuenta_ya_abierta']::text[] FROM private.financial_2b_preview_sales(
  (SELECT org_a FROM _fin2b_fixtures), 500
)), 'cuenta existente evita reapertura silenciosa');
SELECT * FROM finish();
ROLLBACK;
