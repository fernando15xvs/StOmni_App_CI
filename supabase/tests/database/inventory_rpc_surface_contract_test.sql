BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(18);

SELECT ok(
  NOT has_function_privilege('authenticated', 'public.ajustar_stock_y_kardex(bigint,bigint,integer,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric,text)', 'EXECUTE'),
  'ajustar_stock_y_kardex legacy no está expuesto'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'public.registrar_ingreso_mercaderia_v2(uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric)', 'EXECUTE'),
  'registrar_ingreso_mercaderia_v2 base no está expuesto'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'public.registrar_merma_v2(uuid,bigint,bigint,integer,text,timestamptz)', 'EXECUTE'),
  'registrar_merma_v2 base no está expuesto'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'public.registrar_merma_scaled_v3(uuid,bigint,bigint,numeric,text,timestamptz,jsonb)', 'EXECUTE'),
  'registrar_merma_scaled_v3 legacy no está expuesto'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'public.trasladar_stock_v2(uuid,bigint,bigint,bigint,integer,text,timestamptz)', 'EXECUTE'),
  'trasladar_stock_v2 base no está expuesto'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'public.trasladar_stock_scaled_v3(uuid,bigint,bigint,bigint,numeric,text,timestamptz,jsonb)', 'EXECUTE'),
  'trasladar_stock_scaled_v3 legacy no está expuesto'
);

SELECT ok(
  has_function_privilege('authenticated', 'public.ajustar_stock_scaled_v2(bigint,bigint,numeric,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric)', 'EXECUTE'),
  'ajustar_stock_scaled_v2 queda en allowlist'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.registrar_ingreso_mercaderia_scaled_v2(uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric)', 'EXECUTE'),
  'ingreso scaled v2 queda en allowlist'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.registrar_merma_scaled_v4(uuid,bigint,bigint,numeric,text,timestamptz,jsonb)', 'EXECUTE'),
  'merma v4 queda en allowlist'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.trasladar_stock_scaled_v4(uuid,bigint,bigint,bigint,numeric,text,timestamptz,jsonb)', 'EXECUTE'),
  'traslado v4 queda en allowlist'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.crear_producto_con_stock(uuid,jsonb,jsonb)', 'EXECUTE'),
  'alta producto+stock queda en allowlist'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.actualizar_producto_seguro_v1(bigint,jsonb,boolean)', 'EXECUTE'),
  'edición segura de producto queda en allowlist'
);

SELECT ok(
  NOT has_function_privilege('authenticated', 'public._legacy_evaluar_eliminacion_producto_v1(bigint)', 'EXECUTE'),
  'implementación legacy de evaluación es privada'
);
SELECT ok(
  NOT has_function_privilege('authenticated', 'public._legacy_eliminar_producto_seguro_v1(bigint)', 'EXECUTE'),
  'implementación legacy de eliminación es privada'
);

SELECT ok(
  pg_get_functiondef('public.evaluar_eliminacion_producto_v1(bigint)'::regprocedure)
    ILIKE '%private.has_permission(''tenant.admin'')%'
  AND pg_get_functiondef('public.evaluar_eliminacion_producto_v1(bigint)'::regprocedure)
    ILIKE '%private.assert_product_in_current_organization(p_producto_id)%',
  'wrapper de evaluación exige admin y producto del tenant'
);
SELECT ok(
  pg_get_functiondef('public.eliminar_producto_seguro_v1(bigint)'::regprocedure)
    ILIKE '%private.has_permission(''tenant.admin'')%'
  AND pg_get_functiondef('public.eliminar_producto_seguro_v1(bigint)'::regprocedure)
    ILIKE '%private.assert_product_in_current_organization(p_producto_id)%',
  'wrapper de eliminación exige admin y producto del tenant'
);

SELECT ok(
  NOT has_function_privilege('anon', 'public.eliminar_producto_seguro_v1(bigint)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.evaluar_eliminacion_producto_v1(bigint)', 'EXECUTE'),
  'anon no puede evaluar ni eliminar productos'
);
SELECT ok(
  has_function_privilege('authenticated', 'public.eliminar_producto_seguro_v1(bigint)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.evaluar_eliminacion_producto_v1(bigint)', 'EXECUTE'),
  'authenticated sólo entra por wrappers tenant-aware de eliminación'
);

SELECT * FROM finish();
ROLLBACK;
