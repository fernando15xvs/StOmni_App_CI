BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(20);

SELECT has_column('public','detalle_ventas','stock_scale_snapshot','ventas conservan escala de stock');
SELECT has_column('public','detalle_cotizaciones','stock_scale_snapshot','cotizaciones conservan escala de stock');
SELECT has_column('public','inventario_movimientos','stock_scale_snapshot','kardex conserva escala de stock');

SELECT has_function('public','save_product_unit_profile_v6',ARRAY['bigint','bigint','jsonb'],'writer vigente de perfil disponible');
SELECT has_function('public','process_sale_with_units_v4',ARRAY[
  'uuid','bigint','numeric','timestamp with time zone','boolean','numeric','jsonb','jsonb',
  'bigint','bigint','text','numeric','numeric','text','numeric','bigint'
],'venta escalada vigente disponible');
SELECT has_function('public','guardar_cotizacion_with_units_v2',ARRAY[
  'uuid','bigint','numeric','timestamp with time zone','text','integer','jsonb'
],'cotización escalada disponible');
SELECT has_function('public','registrar_merma_scaled_v1',ARRAY[
  'uuid','bigint','bigint','numeric','text','timestamp with time zone'
],'merma escalada disponible');
SELECT has_function('public','trasladar_stock_scaled_v1',ARRAY[
  'uuid','bigint','bigint','bigint','numeric','text','timestamp with time zone'
],'traslado escalado disponible');
SELECT has_function('public','registrar_ingreso_mercaderia_scaled_v1',ARRAY[
  'uuid','bigint','timestamp with time zone','text','text','bigint','text','jsonb',
  'numeric','numeric','numeric','numeric'
],'ingreso escalado disponible');

SELECT ok(NOT has_function_privilege('authenticated',
  'public._product_unit_storage_scale(jsonb)','EXECUTE'),
  'helper de escala no es invocable por cliente');
SELECT ok(NOT has_function_privilege('authenticated',
  'public._visible_base_to_stored(bigint,numeric)','EXECUTE'),
  'conversión a unidades menores no es invocable por cliente');
SELECT ok(has_function_privilege('authenticated',
  'public.save_product_unit_profile_v6(bigint,bigint,jsonb)','EXECUTE'),
  'authenticated puede guardar perfiles vía RPC vigente controlado');
SELECT ok(has_function_privilege('authenticated',
  'public.process_sale_with_units_v4(uuid,bigint,numeric,timestamp with time zone,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)','EXECUTE'),
  'authenticated puede procesar venta escalada vigente');

SELECT lives_ok($$
  SELECT public._validate_product_unit_profile_v2(
    '{"schema_version":2,"base_code":"kg","presentations":[{"code":"kg","singular":"kg","plural":"kg","factor":1,"fractional":true,"precision":3},{"code":"saco_25","singular":"Saco","plural":"Sacos","factor":25,"fractional":false,"precision":0}]}'::jsonb
  )
$$,'perfil kg/saco válido');
SELECT is(
  public._product_unit_storage_scale(
    '{"schema_version":2,"base_code":"kg","presentations":[{"code":"kg","singular":"kg","plural":"kg","factor":1,"fractional":true,"precision":3}]}'::jsonb
  ),
  1000,
  'kg con precisión 3 usa escala 1000'
);
SELECT throws_ok($$
  SELECT public._validate_product_unit_profile_v2(
    '{"schema_version":2,"base_code":"metro","presentations":[{"code":"metro","singular":"Metro","plural":"Metros","factor":1,"fractional":true,"precision":2},{"code":"rollo","singular":"Rollo","plural":"Rollos","factor":0.333,"fractional":true,"precision":3}]}'::jsonb
  )
$$,NULL,NULL,'se rechaza precisión comercial no representable en stock');

SELECT ok(
  to_regprocedure('public._legacy_save_product_unit_profile_v6(bigint,bigint,jsonb)') IS NOT NULL
  AND position('_legacy_save_product_unit_profile_v6' IN pg_get_functiondef(
    'public.save_product_unit_profile_v6(bigint,bigint,jsonb)'::regprocedure))>0
  AND position('save_product_unit_profile_v5' IN pg_get_functiondef(
    'public._legacy_save_product_unit_profile_v6(bigint,bigint,jsonb)'::regprocedure))>0
  AND position('inventario_movimientos' IN pg_get_functiondef(
    'public.save_product_unit_profile_v5(bigint,bigint,jsonb)'::regprocedure))>0,
  'writer tenant-aware delega al motor que verifica historia antes de cambiar escala');
SELECT ok(
  position('detalle_ventas' IN pg_get_functiondef(
    'public.save_product_unit_profile_v5(bigint,bigint,jsonb)'::regprocedure))>0
  AND position('detalle_cotizaciones' IN pg_get_functiondef(
    'public.save_product_unit_profile_v5(bigint,bigint,jsonb)'::regprocedure))>0,
  'motor final bloquea cambio de escala tras ventas o cotizaciones');
SELECT ok(position('UPDATE public.detalle_ventas' IN pg_get_functiondef(
  'public.save_product_unit_profile_v5(bigint,bigint,jsonb)'::regprocedure))=0,
  'writer final no reescribe historial de ventas');
SELECT ok(position('UPDATE public.detalle_cotizaciones' IN pg_get_functiondef(
  'public.save_product_unit_profile_v5(bigint,bigint,jsonb)'::regprocedure))=0,
  'writer final no reescribe historial de cotizaciones');

SELECT * FROM finish();
ROLLBACK;
