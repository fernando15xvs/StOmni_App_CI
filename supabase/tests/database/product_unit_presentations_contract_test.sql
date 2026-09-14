BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(18);

SELECT has_table('public', 'product_unit_profiles', 'existe almacenamiento de perfiles');
SELECT has_column('public', 'detalle_ventas', 'presentation_snapshot', 'ventas conservan snapshot comercial');
SELECT has_function('public', 'get_product_unit_profiles_v1', ARRAY['bigint[]'], 'lectura por lote disponible');
SELECT has_function('public', 'save_product_unit_profile_v1', ARRAY['bigint','bigint','jsonb'], 'escritura CAS disponible');
SELECT has_function('public', 'process_sale_with_units_v1', ARRAY[
  'uuid','bigint','numeric','timestamp with time zone','boolean','numeric','jsonb','jsonb',
  'bigint','bigint','text','numeric','numeric','text','numeric','bigint'
], 'venta transaccional con unidades disponible');
SELECT ok((SELECT relrowsecurity FROM pg_class
           WHERE oid = 'public.product_unit_profiles'::regclass), 'RLS activo');
SELECT table_privs_are('public', 'product_unit_profiles', 'anon', ARRAY[]::text[], 'anon no accede a perfiles');
SELECT table_privs_are('public', 'product_unit_profiles', 'authenticated', ARRAY['SELECT'], 'cliente solo lee tabla');
SELECT ok(NOT has_function_privilege('authenticated',
  'public._protect_profile_stock_contract()', 'EXECUTE'), 'helper del trigger no es invocable');
SELECT ok(NOT has_function_privilege('authenticated',
  'public._validate_product_unit_profile(jsonb)', 'EXECUTE'), 'validador no es invocable por clientes');
SELECT ok(NOT has_function_privilege('authenticated',
  'public._enforce_product_unit_profile()', 'EXECUTE'), 'trigger de validación no es invocable');
SELECT has_trigger('public', 'product_unit_profiles',
  'validate_product_unit_profile', 'la tabla siempre valida el perfil');
SELECT ok(position('v_detail->>''unidadLabel''' IN pg_get_functiondef(
  'public.process_sale_with_units_v1(uuid,bigint,numeric,timestamp with time zone,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)'::regprocedure)) = 0,
  'el snapshot no confía en etiquetas enviadas por el cliente');

SELECT lives_ok($$
  SELECT public._validate_product_unit_profile('{"schema_version":1,"base_code":"botella","presentations":[{"code":"botella","singular":"Botella","plural":"Botellas","factor":1,"fractional":false},{"code":"caja_24","singular":"Caja","plural":"Cajas","factor":24,"fractional":false}]}'::jsonb)
$$, 'perfil entero válido');
SELECT throws_ok($$
  SELECT public._validate_product_unit_profile('{"schema_version":1,"base_code":"kg","presentations":[{"code":"kg","singular":"kg","plural":"kg","factor":1,"fractional":true}]}'::jsonb)
$$, NULL, NULL, 'fracciones siguen bloqueadas');
SELECT throws_ok($$
  SELECT public._validate_product_unit_profile('{"schema_version":1,"base_code":"unidad","presentations":[{"code":"unidad","singular":"Unidad","plural":"Unidades","factor":2,"fractional":false}]}'::jsonb)
$$, NULL, NULL, 'la unidad base siempre equivale a uno');
SELECT throws_ok($$
  SELECT public._validate_product_unit_profile('{"schema_version":"1","base_code":"unidad","presentations":[{"code":"unidad","singular":"Unidad","plural":"Unidades","factor":1,"fractional":false}]}'::jsonb)
$$, NULL, NULL, 'la versión de esquema conserva tipo numérico estricto');
SELECT throws_ok($$
  SELECT public._validate_product_unit_profile(jsonb_build_object(
    'schema_version', 1,
    'base_code', 'unidad',
    'presentations', jsonb_build_array(jsonb_build_object(
      'code', 'unidad', 'singular', E'Unidad\ninyectada',
      'plural', 'Unidades', 'factor', 1, 'fractional', false
    ))
  ))
$$, NULL, NULL, 'las etiquetas no admiten caracteres de control');

SELECT * FROM finish();
ROLLBACK;
