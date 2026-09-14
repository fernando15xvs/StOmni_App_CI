BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(14);

SELECT has_function(
  'public',
  'save_product_unit_profile_v5',
  ARRAY['bigint','bigint','jsonb'],
  'perfil v5 disponible'
);

SELECT ok(
  position('UPDATE public.detalle_ventas' IN pg_get_functiondef(
    'public.save_product_unit_profile_v5(bigint,bigint,jsonb)'::regprocedure
  )) = 0,
  'cambiar precisión no reescribe detalle_ventas histórico'
);

SELECT ok(
  position('UPDATE public.detalle_cotizaciones' IN pg_get_functiondef(
    'public.save_product_unit_profile_v5(bigint,bigint,jsonb)'::regprocedure
  )) = 0,
  'cambiar precisión no reescribe cotizaciones históricas'
);

SELECT ok(
  position('UPDATE public.inventario_almacen' IN pg_get_functiondef(
    'public.save_product_unit_profile_v5(bigint,bigint,jsonb)'::regprocedure
  )) = 0
  AND position('inventario_almacen' IN pg_get_functiondef(
    'public.save_product_unit_profile_v5(bigint,bigint,jsonb)'::regprocedure
  )) > 0
  AND position('detalle_ventas' IN pg_get_functiondef(
    'public.save_product_unit_profile_v5(bigint,bigint,jsonb)'::regprocedure
  )) > 0,
  'perfil v5 hace inmutable la escala cuando existe stock o historial'
);

SELECT ok(
  position('stock_minimo' IN pg_get_functiondef(
    'public.save_product_unit_profile_v5(bigint,bigint,jsonb)'::regprocedure
  )) > 0,
  'perfil v5 conserva escala del stock mínimo'
);

SELECT has_function(
  'public',
  '_stock_quantity_at_current_scale',
  ARRAY['bigint','integer','integer'],
  'helper de conversión histórica disponible'
);

SELECT has_function(
  'public',
  '_rebase_sale_stock_to_current_scale_v1',
  ARRAY['bigint'],
  'rebase perezoso de venta disponible'
);

SELECT ok(
  position('v_converted <> trunc(v_converted)' IN pg_get_functiondef(
    'public._stock_quantity_at_current_scale(bigint,integer,integer)'::regprocedure
  )) > 0
  AND position('abs(v_converted) > 2147483647' IN pg_get_functiondef(
    'public._stock_quantity_at_current_scale(bigint,integer,integer)'::regprocedure
  )) > 0,
  'la conversión histórica exige exactitud y rango entero'
);

SELECT ok(
  position('precio_unitario' IN pg_get_functiondef(
    'public._rebase_sale_stock_to_current_scale_v1(bigint)'::regprocedure
  )) > 0,
  'el rebase ajusta precio interno junto con piezas almacenadas'
);

SELECT ok(
  position('_rebase_sale_stock_to_current_scale_v1' IN pg_get_functiondef(
    'public.anular_venta_v2(bigint,text)'::regprocedure
  )) > 0,
  'anulación pública pasa por guard de escala'
);

SELECT ok(
  position('anular_venta_v2_unscaled_legacy' IN pg_get_functiondef(
    'public.anular_venta_v2(bigint,text)'::regprocedure
  )) > 0,
  'anulación reutiliza implementación transaccional endurecida'
);

SELECT ok(
  position('_rebase_sale_stock_to_current_scale_v1' IN pg_get_functiondef(
    'public.crear_nota_credito_v1(uuid,uuid,text,text,jsonb,numeric,boolean,timestamp with time zone)'::regprocedure
  )) > 0,
  'nota de crédito pública protege reposición de stock fraccionario'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.anular_venta_v2_unscaled_legacy(bigint,text)',
    'EXECUTE'
  ),
  'cliente no puede saltarse el guard de anulación'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public.crear_nota_credito_v1_unscaled_legacy(uuid,uuid,text,text,jsonb,numeric,boolean,timestamp with time zone)',
    'EXECUTE'
  ),
  'cliente no puede saltarse el guard de nota de crédito'
);

SELECT * FROM finish();
ROLLBACK;
