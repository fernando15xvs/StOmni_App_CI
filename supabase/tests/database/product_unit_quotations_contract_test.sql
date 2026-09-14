BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(9);

SELECT has_column(
  'public',
  'detalle_cotizaciones',
  'presentation_snapshot',
  'cotizaciones conservan snapshot comercial'
);

SELECT has_function(
  'public',
  'guardar_cotizacion_with_units_v2',
  ARRAY[
    'uuid',
    'bigint',
    'numeric',
    'timestamp with time zone',
    'text',
    'integer',
    'jsonb'
  ],
  'RPC vigente de cotizaciones configurables disponible'
);

SELECT ok(
  has_function_privilege(
    'authenticated',
    'public.guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamp with time zone,text,integer,jsonb)',
    'EXECUTE'
  ),
  'authenticated puede ejecutar el RPC vigente'
);

SELECT ok(
  NOT has_function_privilege(
    'anon',
    'public.guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamp with time zone,text,integer,jsonb)',
    'EXECUTE'
  ),
  'anon no puede ejecutar el RPC'
);

SELECT ok(
  to_regprocedure('public._legacy_guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamp with time zone,text,integer,jsonb)') IS NOT NULL
  AND position('FOR SHARE' IN pg_get_functiondef(
    'public._legacy_guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamp with time zone,text,integer,jsonb)'::regprocedure
  )) > 0,
  'el motor endurecido bloquea de forma compartida producto y perfil durante validación'
);

SELECT ok(
  position('private.assert_sales_payload_in_current_organization' IN pg_get_functiondef(
    'public.guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamp with time zone,text,integer,jsonb)'::regprocedure
  )) > 0
  AND position('_legacy_guardar_cotizacion_with_units_v2' IN pg_get_functiondef(
    'public.guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamp with time zone,text,integer,jsonb)'::regprocedure
  )) > 0
  AND position('guardar_cotizacion_v2' IN pg_get_functiondef(
    'public._legacy_guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamp with time zone,text,integer,jsonb)'::regprocedure
  )) > 0,
  'la implementación vigente valida tenant y reutiliza la transacción legacy endurecida'
);

SELECT ok(
  position('unit_profile_revision' IN pg_get_functiondef(
    'public._legacy_guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamp with time zone,text,integer,jsonb)'::regprocedure
  )) > 0,
  'la revisión del perfil se valida dentro de PostgreSQL'
);

SELECT ok(
  position('''profile'',v_profile.profile' IN replace(pg_get_functiondef(
    'public._legacy_guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamp with time zone,text,integer,jsonb)'::regprocedure
  ), ' ', '')) > 0,
  'el snapshot conserva el perfil persistido completo'
);

SELECT ok(
  position('''base_label'',v_detail->>' IN replace(pg_get_functiondef(
    'public._legacy_guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamp with time zone,text,integer,jsonb)'::regprocedure
  ), ' ', '')) = 0
  AND position('''base_label'',v_base_label' IN replace(pg_get_functiondef(
    'public._legacy_guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamp with time zone,text,integer,jsonb)'::regprocedure
  ), ' ', '')) > 0,
  'la etiqueta base se deriva del perfil persistido y no se confía al cliente'
);

SELECT * FROM finish();
ROLLBACK;
