-- Pruebas de esquema y transacciones aisladas. Fixtures descartadas por ROLLBACK.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
CREATE TEMP TABLE _fin2a_fixture (
  org_a uuid NOT NULL,
  org_b uuid NOT NULL,
  sale_a bigint NOT NULL,
  sale_b bigint NOT NULL,
  op_a uuid,
  event_a uuid,
  cron_a uuid,
  cuota_a uuid,
  movimiento_a uuid,
  request_a uuid NOT NULL
) ON COMMIT DROP;
INSERT INTO _fin2a_fixture (org_a,org_b,sale_a,sale_b,request_a)
VALUES(gen_random_uuid(),gen_random_uuid(),-8200001001,-8200001002,gen_random_uuid());

-- Datos padres sólo para este test. Se omiten triggers comerciales durante
-- la inserción de fixtures, luego se restauran todas las FK/triggers reales.
SET LOCAL session_replication_role = replica;
INSERT INTO public.organizations(id,display_name,country_code,currency_code,timezone)
SELECT org_a,'CI Financial A','PE','PEN','America/Lima' FROM _fin2a_fixture
UNION ALL
SELECT org_b,'CI Financial B','PE','PEN','America/Lima' FROM _fin2a_fixture;
INSERT INTO public.ventas(id,organization_id,total)
SELECT sale_a,org_a,100::numeric FROM _fin2a_fixture
UNION ALL
SELECT sale_b,org_b,200::numeric FROM _fin2a_fixture;
SET LOCAL session_replication_role = origin;

INSERT INTO public.venta_cuentas_financieras
(organization_id,venta_id,moneda,exigible,saldo_pendiente)
SELECT org_a,sale_a,'PEN',100,100 FROM _fin2a_fixture
UNION ALL
SELECT org_b,sale_b,'PEN',200,200 FROM _fin2a_fixture;

WITH ins AS (
  INSERT INTO public.venta_operaciones_financieras
    (organization_id,venta_id,tipo,request_id,payload_hash,resultado)
  SELECT org_a,sale_a,'apertura',request_a,'test-payload','aplicado' FROM _fin2a_fixture
  RETURNING id
) UPDATE _fin2a_fixture SET op_a=(SELECT id FROM ins);
WITH ins AS (
  INSERT INTO public.venta_eventos_financieros
    (organization_id,venta_id,operacion_id,secuencia,tipo,delta_exigible,efectivo_at)
  SELECT org_a,sale_a,op_a,1,'apertura',100,now() FROM _fin2a_fixture
  RETURNING id
) UPDATE _fin2a_fixture SET event_a=(SELECT id FROM ins);
WITH ins AS (
  INSERT INTO public.venta_cronogramas
    (organization_id,venta_id,version,estado,origen_evento_id)
  SELECT org_a,sale_a,1,'vigente',event_a FROM _fin2a_fixture
  RETURNING id
) UPDATE _fin2a_fixture SET cron_a=(SELECT id FROM ins);
WITH ins AS (
  INSERT INTO public.venta_cuotas
    (organization_id,venta_id,cronograma_id,numero,vencimiento,importe_original,importe_vigente)
  SELECT org_a,sale_a,cron_a,1,date '2026-12-01',100,100 FROM _fin2a_fixture
  RETURNING id
) UPDATE _fin2a_fixture SET cuota_a=(SELECT id FROM ins);
WITH ins AS (
  INSERT INTO public.venta_cuota_movimientos
    (organization_id,venta_id,cuota_id,evento_id,tipo,importe_asignado)
  SELECT org_a,sale_a,cuota_a,event_a,'ajuste',10 FROM _fin2a_fixture
  RETURNING id
) UPDATE _fin2a_fixture SET movimiento_a=(SELECT id FROM ins);

CREATE TEMP TABLE _fin2a_assertions (name text PRIMARY KEY, passed boolean NOT NULL) ON COMMIT DROP;
DO $probe$
BEGIN
  BEGIN
    INSERT INTO public.venta_operaciones_financieras
      (organization_id,venta_id,tipo,request_id,payload_hash)
    SELECT org_b,sale_a,'cobro',gen_random_uuid(),'invalid-cross-tenant' FROM _fin2a_fixture;
    INSERT INTO _fin2a_assertions VALUES('cross_tenant',false);
  EXCEPTION WHEN foreign_key_violation THEN
    INSERT INTO _fin2a_assertions VALUES('cross_tenant',true);
  END;

  BEGIN
    INSERT INTO public.venta_cuotas
      (organization_id,venta_id,cronograma_id,numero,vencimiento,importe_original,importe_vigente)
    SELECT org_b,sale_b,cron_a,1,date '2026-12-01',200,200 FROM _fin2a_fixture;
    INSERT INTO _fin2a_assertions VALUES('cross_cronogram',false);
  EXCEPTION WHEN foreign_key_violation THEN
    INSERT INTO _fin2a_assertions VALUES('cross_cronogram',true);
  END;

  BEGIN
    INSERT INTO public.venta_cuotas
      (organization_id,venta_id,cronograma_id,numero,importe_original,importe_vigente)
    SELECT org_a,sale_a,cron_a,2,50,50 FROM _fin2a_fixture;
    INSERT INTO _fin2a_assertions VALUES('missing_due',false);
  EXCEPTION WHEN check_violation THEN
    INSERT INTO _fin2a_assertions VALUES('missing_due',true);
  END;

  BEGIN
    INSERT INTO public.venta_operaciones_financieras
      (organization_id,venta_id,tipo,request_id,payload_hash)
    SELECT org_a,sale_a,'apertura',request_a,'duplicate' FROM _fin2a_fixture;
    INSERT INTO _fin2a_assertions VALUES('duplicate_request',false);
  EXCEPTION WHEN unique_violation THEN
    INSERT INTO _fin2a_assertions VALUES('duplicate_request',true);
  END;

  BEGIN
    UPDATE public.venta_cuentas_financieras
       SET exigible=110
      WHERE (organization_id,venta_id) IN (SELECT org_a,sale_a FROM _fin2a_fixture);
    INSERT INTO _fin2a_assertions VALUES('bad_balance',false);
  EXCEPTION WHEN check_violation THEN
    INSERT INTO _fin2a_assertions VALUES('bad_balance',true);
  END;

  BEGIN
    UPDATE public.venta_eventos_financieros SET delta_exigible=1
    WHERE id=(SELECT event_a FROM _fin2a_fixture);
    INSERT INTO _fin2a_assertions VALUES('update_event',false);
  EXCEPTION WHEN check_violation THEN
    INSERT INTO _fin2a_assertions VALUES('update_event',true);
  END;

  BEGIN
    UPDATE public.venta_cuota_movimientos SET importe_asignado=20
    WHERE id=(SELECT movimiento_a FROM _fin2a_fixture);
    INSERT INTO _fin2a_assertions VALUES('update_movement',false);
  EXCEPTION WHEN check_violation THEN
    INSERT INTO _fin2a_assertions VALUES('update_movement',true);
  END;

  BEGIN
    INSERT INTO public.venta_cronogramas
      (organization_id,venta_id,version,estado)
    SELECT org_a,sale_a,2,'vigente' FROM _fin2a_fixture;
    INSERT INTO _fin2a_assertions VALUES('duplicate_current',false);
  EXCEPTION WHEN unique_violation THEN
    INSERT INTO _fin2a_assertions VALUES('duplicate_current',true);
  END;
END;
$probe$;
-- El mismo request UUID en otro tenant no colisiona.
INSERT INTO public.venta_operaciones_financieras
  (organization_id,venta_id,tipo,request_id,payload_hash)
SELECT org_b,sale_b,'apertura',request_a,'other-tenant' FROM _fin2a_fixture;

SELECT plan(27);
SELECT is((SELECT count(*) FROM pg_class WHERE relnamespace='public'::regnamespace AND relkind='r' AND relname = ANY(ARRAY['venta_cuentas_financieras','venta_operaciones_financieras','venta_eventos_financieros','venta_cronogramas','venta_cuotas','venta_cuota_movimientos' ])), 6::bigint, 'seis tablas financieras creadas');
SELECT ok((SELECT bool_and(relrowsecurity) FROM pg_class WHERE relnamespace='public'::regnamespace AND relname = ANY(ARRAY['venta_cuentas_financieras','venta_operaciones_financieras','venta_eventos_financieros','venta_cronogramas','venta_cuotas','venta_cuota_movimientos' ])), 'RLS habilitado en todas las tablas');
SELECT ok((SELECT bool_and(has_table_privilege('authenticated',('public.'||relname)::regclass,'SELECT')) FROM pg_class WHERE relnamespace='public'::regnamespace AND relname = ANY(ARRAY['venta_cuentas_financieras','venta_operaciones_financieras','venta_eventos_financieros','venta_cronogramas','venta_cuotas','venta_cuota_movimientos' ])), 'lectura autenticada permitida sujeto a RLS');
SELECT ok((SELECT bool_and(NOT has_table_privilege('authenticated',('public.'||relname)::regclass,'INSERT,UPDATE,DELETE')) FROM pg_class WHERE relnamespace='public'::regnamespace AND relname = ANY(ARRAY['venta_cuentas_financieras','venta_operaciones_financieras','venta_eventos_financieros','venta_cronogramas','venta_cuotas','venta_cuota_movimientos' ])), 'cliente no puede mutar directamente');
SELECT ok((SELECT bool_and(NOT has_table_privilege('anon',('public.'||relname)::regclass,'SELECT')) FROM pg_class WHERE relnamespace='public'::regnamespace AND relname = ANY(ARRAY['venta_cuentas_financieras','venta_operaciones_financieras','venta_eventos_financieros','venta_cronogramas','venta_cuotas','venta_cuota_movimientos' ])), 'anon no lee saldos ni cuotas');
SELECT is((SELECT count(*) FROM pg_policies WHERE schemaname='public' AND tablename = ANY(ARRAY['venta_cuentas_financieras','venta_operaciones_financieras','venta_eventos_financieros','venta_cronogramas','venta_cuotas','venta_cuota_movimientos' ]) AND cmd='SELECT' AND qual LIKE '%row_belongs_to_current_organization(organization_id)%' AND qual LIKE '%has_permission%'), 6::bigint, 'políticas RLS con tenant y permiso explícito');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='venta_cuentas_venta_fkey' AND pg_get_constraintdef(oid) LIKE '%FOREIGN KEY (organization_id, venta_id)%'), 'venta_cuentas_venta_fkey conserva venta y organización');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='venta_ops_cuenta_fkey' AND pg_get_constraintdef(oid) LIKE '%FOREIGN KEY (organization_id, venta_id)%'), 'venta_ops_cuenta_fkey conserva venta y organización');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='venta_eventos_op_fkey' AND pg_get_constraintdef(oid) LIKE '%FOREIGN KEY (organization_id, venta_id, operacion_id)%'), 'venta_eventos_op_fkey conserva venta y organización');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='venta_eventos_pago_fkey' AND pg_get_constraintdef(oid) LIKE '%FOREIGN KEY (organization_id, venta_id, pago_id)%'), 'venta_eventos_pago_fkey conserva venta y organización');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='venta_eventos_nc_fkey' AND pg_get_constraintdef(oid) LIKE '%FOREIGN KEY (organization_id, venta_id, nota_credito_id)%'), 'venta_eventos_nc_fkey conserva venta y organización');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='venta_cronos_evento_fkey' AND pg_get_constraintdef(oid) LIKE '%FOREIGN KEY (organization_id, venta_id, origen_evento_id)%'), 'venta_cronos_evento_fkey conserva venta y organización');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='venta_cuotas_crono_fkey' AND pg_get_constraintdef(oid) LIKE '%FOREIGN KEY (organization_id, venta_id, cronograma_id)%'), 'venta_cuotas_crono_fkey conserva venta y organización');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='venta_cuota_mov_evento_fkey' AND pg_get_constraintdef(oid) LIKE '%FOREIGN KEY (organization_id, venta_id, evento_id)%'), 'venta_cuota_mov_evento_fkey conserva venta y organización');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='venta_cuota_mov_cuota_fkey' AND pg_get_constraintdef(oid) LIKE '%FOREIGN KEY (organization_id, venta_id, cuota_id)%'), 'venta_cuota_mov_cuota_fkey conserva venta y organización');
SELECT ok(EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='public' AND indexname='venta_cronos_vigente_fin2a_uix' AND indexdef ILIKE '%WHERE (estado = ''vigente''%'), 'una sola versión de cronograma vigente');
SELECT is((SELECT count(*) FROM pg_trigger WHERE tgname IN ('venta_eventos_fin2a_immutable','venta_cuota_mov_fin2a_immutable') AND NOT tgisinternal), 2::bigint, 'triggers de historial inmutable');
SELECT ok(EXISTS(SELECT 1 FROM pg_constraint WHERE conname='venta_ops_request_unique'), 'idempotencia por organización, tipo y request');
SELECT ok((SELECT passed FROM _fin2a_assertions WHERE name='cross_tenant'), 'regla efectiva cross_tenant');
SELECT ok((SELECT passed FROM _fin2a_assertions WHERE name='cross_cronogram'), 'regla efectiva cross_cronogram');
SELECT ok((SELECT passed FROM _fin2a_assertions WHERE name='missing_due'), 'regla efectiva missing_due');
SELECT ok((SELECT passed FROM _fin2a_assertions WHERE name='duplicate_request'), 'regla efectiva duplicate_request');
SELECT ok((SELECT passed FROM _fin2a_assertions WHERE name='bad_balance'), 'regla efectiva bad_balance');
SELECT ok((SELECT passed FROM _fin2a_assertions WHERE name='update_event'), 'regla efectiva update_event');
SELECT ok((SELECT passed FROM _fin2a_assertions WHERE name='update_movement'), 'regla efectiva update_movement');
SELECT ok((SELECT passed FROM _fin2a_assertions WHERE name='duplicate_current'), 'regla efectiva duplicate_current');
SELECT is((SELECT count(*) FROM public.venta_operaciones_financieras o JOIN _fin2a_fixture f ON o.organization_id=f.org_b AND o.venta_id=f.sale_b AND o.request_id=f.request_a),1::bigint,'request_id puede repetirse en otro tenant');
SELECT * FROM finish();
ROLLBACK;
