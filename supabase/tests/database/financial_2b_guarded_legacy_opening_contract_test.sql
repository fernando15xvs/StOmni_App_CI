-- Fase 2B: apertura administrativa controlada.
-- Solo datos sintéticos, aislados por tenant y revertidos al final.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

CREATE TEMP TABLE _fin2b_open_fixture (
  org_a uuid NOT NULL,
  org_b uuid NOT NULL,
  sale_a bigint NOT NULL,
  sale_b bigint NOT NULL,
  request_a uuid NOT NULL
) ON COMMIT DROP;
INSERT INTO _fin2b_open_fixture VALUES
  (gen_random_uuid(),gen_random_uuid(),-8300002001,-8300002002,gen_random_uuid());

SET LOCAL session_replication_role = replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org_a,'Ledger fixture A','PE','PEN','America/Lima' FROM _fin2b_open_fixture
UNION ALL
SELECT org_b,'Ledger fixture B','PE','PEN','America/Lima' FROM _fin2b_open_fixture;
INSERT INTO public.ventas(id,organization_id,total,saldo,estado,fecha,monto_notas_credito)
SELECT sale_a,org_a,100,80,'pendiente',now(),0 FROM _fin2b_open_fixture
UNION ALL
SELECT sale_b,org_b,60,60,'pendiente',now(),0 FROM _fin2b_open_fixture;
INSERT INTO public.pagos_venta(venta_id,organization_id,metodo,monto,fecha)
SELECT sale_a,org_a,'efectivo',20,now() FROM _fin2b_open_fixture;
SET LOCAL session_replication_role = origin;

CREATE TEMP TABLE _fin2b_open_checks(name text PRIMARY KEY, passed boolean NOT NULL) ON COMMIT DROP;

DO $probe$
DECLARE f _fin2b_open_fixture%ROWTYPE;
        result record;
BEGIN
  SELECT * INTO f FROM _fin2b_open_fixture;

  BEGIN
    PERFORM * FROM private.financial_2b_open_legacy_sale(
      f.org_a,f.sale_a,f.request_a,'PEN',false);
    INSERT INTO _fin2b_open_checks VALUES ('confirmation_required',false);
  EXCEPTION WHEN invalid_parameter_value THEN
    INSERT INTO _fin2b_open_checks VALUES ('confirmation_required',true);
  END;

  BEGIN
    PERFORM * FROM private.financial_2b_open_legacy_sale(
      f.org_a,f.sale_a,f.request_a,'USD',true);
    INSERT INTO _fin2b_open_checks VALUES ('currency_mismatch',false);
  EXCEPTION WHEN check_violation THEN
    INSERT INTO _fin2b_open_checks VALUES ('currency_mismatch',true);
  END;

  SELECT * INTO result FROM private.financial_2b_open_legacy_sale(
    f.org_a,f.sale_a,f.request_a,'PEN',true);
  INSERT INTO _fin2b_open_checks VALUES (
    'opens_pending',result.estado='abierta_pendiente_conciliacion'
      AND result.venta_id=f.sale_a AND result.cantidad_eventos=2
  );

  SELECT * INTO result FROM private.financial_2b_open_legacy_sale(
    f.org_a,f.sale_a,f.request_a,'PEN',true);
  INSERT INTO _fin2b_open_checks VALUES (
    'retry_idempotent',result.estado='ya_abierta'
      AND result.cantidad_eventos=2
  );

  BEGIN
    PERFORM * FROM private.financial_2b_open_legacy_sale(
      f.org_a,f.sale_a,gen_random_uuid(),'PEN',true);
    INSERT INTO _fin2b_open_checks VALUES ('conflicting_retry',false);
  EXCEPTION WHEN unique_violation THEN
    INSERT INTO _fin2b_open_checks VALUES ('conflicting_retry',true);
  END;

  BEGIN
    UPDATE public.ventas SET saldo=50
    WHERE organization_id=f.org_a AND id=f.sale_a;
    INSERT INTO _fin2b_open_checks VALUES ('legacy_sale_mutation',false);
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    INSERT INTO _fin2b_open_checks VALUES ('legacy_sale_mutation',true);
  END;

  BEGIN
    INSERT INTO public.pagos_venta(organization_id,venta_id,metodo,monto,fecha)
    VALUES (f.org_a,f.sale_a,'efectivo',5,now());
    INSERT INTO _fin2b_open_checks VALUES ('legacy_payment_insert',false);
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    INSERT INTO _fin2b_open_checks VALUES ('legacy_payment_insert',true);
  END;

  BEGIN
    UPDATE public.pagos_venta SET monto=15
    WHERE organization_id=f.org_a AND venta_id=f.sale_a;
    INSERT INTO _fin2b_open_checks VALUES ('legacy_payment_update',false);
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    INSERT INTO _fin2b_open_checks VALUES ('legacy_payment_update',true);
  END;

  BEGIN
    DELETE FROM public.pagos_venta
    WHERE organization_id=f.org_a AND venta_id=f.sale_a;
    INSERT INTO _fin2b_open_checks VALUES ('legacy_payment_delete',false);
  EXCEPTION WHEN object_not_in_prerequisite_state THEN
    INSERT INTO _fin2b_open_checks VALUES ('legacy_payment_delete',true);
  END;

  -- El tenant B aún no se abrió: los writers legacy siguen disponibles allí.
  UPDATE public.ventas SET saldo=55 WHERE organization_id=f.org_b AND id=f.sale_b;
  INSERT INTO _fin2b_open_checks VALUES (
    'unopened_sale_unchanged',
    (SELECT saldo=55 FROM public.ventas
     WHERE organization_id=f.org_b AND id=f.sale_b)
  );
END;
$probe$;
SELECT plan(22);
SELECT ok(to_regprocedure('private.financial_2b_open_legacy_sale(uuid,bigint,uuid,text,boolean)') IS NOT NULL,'función administrativa disponible');
SELECT ok(NOT has_function_privilege('anon','private.financial_2b_open_legacy_sale(uuid,bigint,uuid,text,boolean)','EXECUTE') AND NOT has_function_privilege('authenticated','private.financial_2b_open_legacy_sale(uuid,bigint,uuid,text,boolean)','EXECUTE') AND NOT has_function_privilege('service_role','private.financial_2b_open_legacy_sale(uuid,bigint,uuid,text,boolean)','EXECUTE'),'no expone apertura a clientes');
SELECT ok((SELECT NOT prosecdef AND provolatile='v' FROM pg_proc WHERE oid='private.financial_2b_open_legacy_sale(uuid,bigint,uuid,text,boolean)'::regprocedure),'apertura es security invoker y volátil');
SELECT ok((SELECT prosecdef AND array_to_string(proconfig, ',') LIKE '%search_path=%' FROM pg_proc WHERE oid='private.financial_2b_guard_legacy_financial_write()'::regprocedure),'trigger privado con search_path fijado');
SELECT is((SELECT COUNT(*) FROM pg_trigger WHERE tgname IN ('zz_fin2b_legacy_sale_guard','zz_fin2b_legacy_payment_guard','zz_fin2b_legacy_credit_note_guard') AND NOT tgisinternal),3::bigint,'tres protecciones de escritores legacy');
SELECT ok((SELECT passed FROM _fin2b_open_checks WHERE name='confirmation_required'),'confirmation_required');
SELECT ok((SELECT passed FROM _fin2b_open_checks WHERE name='currency_mismatch'),'currency_mismatch');
SELECT ok((SELECT passed FROM _fin2b_open_checks WHERE name='opens_pending'),'opens_pending');
SELECT ok((SELECT passed FROM _fin2b_open_checks WHERE name='retry_idempotent'),'retry_idempotent');
SELECT ok((SELECT passed FROM _fin2b_open_checks WHERE name='conflicting_retry'),'conflicting_retry');
SELECT ok((SELECT passed FROM _fin2b_open_checks WHERE name='legacy_sale_mutation'),'legacy_sale_mutation');
SELECT ok((SELECT passed FROM _fin2b_open_checks WHERE name='legacy_payment_insert'),'legacy_payment_insert');
SELECT ok((SELECT passed FROM _fin2b_open_checks WHERE name='legacy_payment_update'),'legacy_payment_update');
SELECT ok((SELECT passed FROM _fin2b_open_checks WHERE name='legacy_payment_delete'),'legacy_payment_delete');
SELECT ok((SELECT passed FROM _fin2b_open_checks WHERE name='unopened_sale_unchanged'),'unopened_sale_unchanged');
SELECT is((SELECT COUNT(*) FROM public.venta_cuentas_financieras cf JOIN _fin2b_open_fixture f ON cf.organization_id=f.org_a AND cf.venta_id=f.sale_a AND cf.estado_conciliacion='pendiente'),1::bigint,'cuenta pendiente y no conciliada automáticamente');
SELECT is((SELECT COUNT(*) FROM public.venta_operaciones_financieras op JOIN _fin2b_open_fixture f ON op.organization_id=f.org_a AND op.venta_id=f.sale_a AND op.tipo='apertura'),1::bigint,'un solo registro de operación tras retry');
SELECT is((SELECT COUNT(*) FROM public.venta_eventos_financieros ev JOIN _fin2b_open_fixture f ON ev.organization_id=f.org_a AND ev.venta_id=f.sale_a),2::bigint,'solo apertura y un cobro histórico');
SELECT ok((SELECT SUM(ev.delta_exigible)=100 AND SUM(ev.delta_cobros)=20 FROM public.venta_eventos_financieros ev JOIN _fin2b_open_fixture f ON ev.organization_id=f.org_a AND ev.venta_id=f.sale_a),'sumatorias de eventos cuadran');
SELECT ok((SELECT metadata_apertura->>'cobertura'='fuentes_actuales_no_historial_exhaustivo' FROM public.venta_operaciones_financieras op JOIN _fin2b_open_fixture f ON op.organization_id=f.org_a AND op.venta_id=f.sale_a AND op.tipo='apertura'),'identifica cobertura histórica no exhaustiva');
SELECT is((SELECT COUNT(*) FROM public.venta_cuentas_financieras cf JOIN _fin2b_open_fixture f ON cf.organization_id=f.org_b AND cf.venta_id=f.sale_b),0::bigint,'no abre otra empresa automáticamente');
SELECT is((SELECT COUNT(*) FROM public.venta_eventos_financieros ev JOIN _fin2b_open_fixture f ON ev.organization_id=f.org_b AND ev.venta_id=f.sale_b),0::bigint,'no crea eventos de otro tenant');
SELECT * FROM finish();
ROLLBACK;
