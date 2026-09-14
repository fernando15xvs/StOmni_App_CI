BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(17);

SELECT has_function(
  'public',
  'save_product_unit_profile_v6',
  ARRAY['bigint','bigint','jsonb'],
  'perfil fiscal-aware v6 disponible'
);

SELECT ok(
  position('_validate_product_unit_fiscal_codes_v1' IN pg_get_functiondef(
    'public.save_product_unit_profile_v6(bigint,bigint,jsonb)'::regprocedure
  )) > 0,
  'perfil v6 valida códigos fiscales antes de guardar'
);

SELECT has_column(
  'public',
  'notas_credito_detalles',
  'commercial_quantity_snapshot',
  'NC conserva cantidad comercial inmutable'
);

SELECT has_column(
  'public',
  'notas_credito_detalles',
  'presentation_snapshot',
  'NC conserva snapshot de presentación'
);

SELECT has_column(
  'public',
  'notas_credito_detalles',
  'fiscal_unit_code_snapshot',
  'NC conserva código fiscal inmutable'
);

SELECT has_column(
  'public',
  'notas_credito_detalles',
  'stock_scale_snapshot',
  'NC conserva escala interna propia'
);

SELECT has_function(
  'public',
  '_rebase_credit_note_stock_to_current_scale_for_sale_v1',
  ARRAY['bigint'],
  'rebase interno de NC disponible'
);

SELECT has_function(
  'public',
  'obtener_disponibilidad_nota_credito_v2',
  ARRAY['uuid'],
  'disponibilidad comercial de NC disponible'
);

SELECT has_function(
  'public',
  'crear_nota_credito_with_units_v3',
  ARRAY['uuid','uuid','text','text','jsonb','numeric','boolean','timestamp with time zone'],
  'creación de NC fraccionaria disponible'
);

SELECT ok(
  position('commercial_quantity_snapshot' IN pg_get_functiondef(
    'public.obtener_disponibilidad_nota_credito_v2(uuid)'::regprocedure
  )) > 0,
  'disponibilidad usa snapshot comercial en vez de truncar cantidades'
);

SELECT ok(
  position('_rebase_sale_stock_to_current_scale_v1' IN pg_get_functiondef(
    'public.crear_nota_credito_with_units_v3(uuid,uuid,text,text,jsonb,numeric,boolean,timestamp with time zone)'::regprocedure
  )) > 0,
  'creación NC normaliza primero la escala de la venta'
);

SELECT ok(
  position('_rebase_credit_note_stock_to_current_scale_for_sale_v1' IN pg_get_functiondef(
    'public.crear_nota_credito_with_units_v3(uuid,uuid,text,text,jsonb,numeric,boolean,timestamp with time zone)'::regprocedure
  )) > 0,
  'creación NC normaliza notas anteriores antes de validar disponibilidad'
);

SELECT ok(
  position('commercial_quantity_snapshot' IN pg_get_functiondef(
    'public.crear_nota_credito_with_units_v3(uuid,uuid,text,text,jsonb,numeric,boolean,timestamp with time zone)'::regprocedure
  )) > 0,
  'creación NC persiste cantidad comercial separada del stock interno'
);

SELECT ok(
  position('fiscal_unit_code_snapshot' IN pg_get_functiondef(
    'public.crear_nota_credito_with_units_v3(uuid,uuid,text,text,jsonb,numeric,boolean,timestamp with time zone)'::regprocedure
  )) > 0,
  'creación NC persiste unidad fiscal del snapshot'
);

SELECT ok(
  NOT has_function_privilege(
    'authenticated',
    'public._rebase_credit_note_stock_to_current_scale_for_sale_v1(bigint)',
    'EXECUTE'
  ),
  'cliente no puede invocar directamente el rebase interno de NC'
);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.obtener_disponibilidad_nota_credito_v2(uuid)',
    'EXECUTE'
  ),
  'cliente autenticado puede consultar disponibilidad v2'
);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.crear_nota_credito_with_units_v3(uuid,uuid,text,text,jsonb,numeric,boolean,timestamp with time zone)',
    'EXECUTE'
  ),
  'cliente autenticado puede crear NC con cantidades configurables'
);

SELECT * FROM finish();
ROLLBACK;
