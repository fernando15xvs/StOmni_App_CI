BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(16);

SELECT ok(
  (SELECT column_default IS NULL FROM information_schema.columns
   WHERE table_schema='public' AND table_name='productos' AND column_name='tipo_venta'),
  'tipo_venta no tiene default implícito'
);
SELECT col_not_null('public','productos','tipo_venta','tipo_venta es obligatorio');
SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.productos'::regclass
      AND conname='productos_tipo_venta_canonical_check'
      AND pg_get_constraintdef(oid) LIKE '%UNIDAD%'
      AND pg_get_constraintdef(oid) LIKE '%PAQUETE%'
      AND pg_get_constraintdef(oid) NOT LIKE '%AMBOS%'
  ),
  'productos restringe tipo_venta al conjunto canónico'
);

SELECT is(public._require_product_sale_type('UNIDAD'),'UNIDAD','acepta UNIDAD');
SELECT is(public._require_product_sale_type('CAJA'),'CAJA','acepta CAJA');
SELECT is(public._require_product_sale_type('PAQUETE'),'PAQUETE','acepta PAQUETE');
SELECT is(public._require_product_sale_type('CAJA_PAQUETES'),'CAJA_PAQUETES','acepta CAJA_PAQUETES');
SELECT is(public._require_product_sale_type('CAJA_UNIDADES'),'CAJA_UNIDADES','acepta CAJA_UNIDADES');
SELECT throws_ok($$ SELECT public._require_product_sale_type('AMBOS') $$, NULL, NULL, 'rechaza AMBOS');
SELECT throws_ok($ SELECT public._require_product_sale_type('PAQUETES') $, NULL, NULL, 'rechaza PAQUETES');
SELECT throws_ok($ SELECT public._require_product_sale_type('unidad') $, NULL, NULL, 'rechaza minúsculas');

SELECT ok(
  position('_require_product_sale_type' IN pg_get_functiondef(
    'public.crear_producto_con_stock(uuid,jsonb,jsonb)'::regprocedure
  )) > 0,
  'alta de producto valida el código canónico'
);
SELECT ok(
  position('_require_product_sale_type' IN pg_get_functiondef(
    'public.actualizar_producto_seguro_v1(bigint,jsonb,boolean)'::regprocedure
  )) > 0,
  'edición de producto valida el código canónico'
);
SELECT ok(
  position('''UNIDAD''' IN pg_get_functiondef(
    'public.save_service_v1(bigint,text,text,text,numeric,numeric)'::regprocedure
  )) > 0
  AND position('''unidad''' IN pg_get_functiondef(
    'public.save_service_v1(bigint,text,text,text,numeric,numeric)'::regprocedure
  )) = 0,
  'servicios persisten UNIDAD en formato canónico'
);
SELECT throws_ok($$
  SELECT public._validate_product_unit_profile_v2(
    '{"schema_version":1,"base_code":"unidad","presentations":[{"code":"unidad","singular":"Unidad","plural":"Unidades","factor":1,"fractional":false}]}'::jsonb
  )
$$, NULL, NULL, 'schema v1 ya no se acepta');
SELECT lives_ok($$
  SELECT public._validate_product_unit_profile_v2(
    '{"schema_version":2,"base_code":"unidad","presentations":[{"code":"unidad","singular":"Unidad","plural":"Unidades","factor":1,"fractional":false,"precision":0}]}'::jsonb
  )
$$, 'schema v2 es el único perfil válido');

SELECT * FROM finish();
ROLLBACK;
