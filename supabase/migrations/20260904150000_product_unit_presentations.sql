BEGIN;

CREATE TABLE public.product_unit_profiles (
  product_id bigint PRIMARY KEY REFERENCES public.productos(id) ON DELETE CASCADE,
  revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
  profile jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.product_unit_profiles ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.product_unit_profiles FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.product_unit_profiles TO authenticated;

CREATE POLICY product_unit_profiles_read_active
ON public.product_unit_profiles FOR SELECT TO authenticated
USING (public.app_empleado_activo());

ALTER TABLE public.detalle_ventas
  ADD COLUMN presentation_snapshot jsonb;

CREATE OR REPLACE FUNCTION public._validate_product_unit_profile(p_profile jsonb)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_row jsonb;
  v_codes text[] := ARRAY[]::text[];
  v_code text;
  v_factor numeric;
  v_base_count integer := 0;
BEGIN
  IF jsonb_typeof(p_profile) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Perfil de presentaciones inválido';
  END IF;
  IF jsonb_typeof(p_profile->'schema_version') IS DISTINCT FROM 'number'
     OR jsonb_typeof(p_profile->'base_code') IS DISTINCT FROM 'string'
     OR jsonb_typeof(p_profile->'presentations') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Perfil de presentaciones inválido';
  END IF;
  IF (p_profile->>'schema_version')::numeric <> 1
     OR jsonb_array_length(p_profile->'presentations') NOT BETWEEN 1 AND 20
     OR (p_profile->>'base_code') !~ '^[a-z][a-z0-9_]{0,39}$' THEN
    RAISE EXCEPTION 'Perfil de presentaciones inválido';
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_profile->'presentations')
  LOOP
    IF jsonb_typeof(v_row) <> 'object'
       OR jsonb_typeof(v_row->'code') <> 'string'
       OR jsonb_typeof(v_row->'singular') <> 'string'
       OR jsonb_typeof(v_row->'plural') <> 'string'
       OR jsonb_typeof(v_row->'factor') <> 'number'
       OR jsonb_typeof(v_row->'fractional') <> 'boolean' THEN
      RAISE EXCEPTION 'Presentación incompleta';
    END IF;
    v_code := v_row->>'code';
    v_factor := (v_row->>'factor')::numeric;
    IF v_code !~ '^[a-z][a-z0-9_]{0,39}$'
       OR v_code = ANY(v_codes)
       OR length(trim(v_row->>'singular')) NOT BETWEEN 1 AND 60
       OR length(trim(v_row->>'plural')) NOT BETWEEN 1 AND 60
       OR v_row->>'singular' <> trim(v_row->>'singular')
       OR v_row->>'plural' <> trim(v_row->>'plural')
       OR (v_row->>'singular') ~ '[[:cntrl:]]'
       OR (v_row->>'plural') ~ '[[:cntrl:]]'
       OR (v_row->>'fractional')::boolean
       OR v_factor::text IN ('NaN', 'Infinity', '-Infinity')
       OR v_factor <> trunc(v_factor)
       OR v_factor NOT BETWEEN 1 AND 2147483647 THEN
      RAISE EXCEPTION 'Presentación fuera del contrato entero actual';
    END IF;
    v_codes := array_append(v_codes, v_code);
    IF v_code = p_profile->>'base_code' THEN
      v_base_count := v_base_count + 1;
      IF v_factor <> 1 THEN
        RAISE EXCEPTION 'La unidad base debe tener factor 1';
      END IF;
    END IF;
  END LOOP;
  IF v_base_count <> 1 THEN
    RAISE EXCEPTION 'La unidad base debe aparecer exactamente una vez';
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public._enforce_product_unit_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  PERFORM public._validate_product_unit_profile(NEW.profile);
  RETURN NEW;
END;
$function$;

CREATE TRIGGER validate_product_unit_profile
BEFORE INSERT OR UPDATE OF profile ON public.product_unit_profiles
FOR EACH ROW EXECUTE FUNCTION public._enforce_product_unit_profile();

CREATE OR REPLACE FUNCTION public.get_product_unit_profiles_v1(p_product_ids bigint[])
RETURNS SETOF jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado';
  END IF;
  IF p_product_ids IS NULL OR cardinality(p_product_ids) > 1000
     OR EXISTS (SELECT 1 FROM unnest(p_product_ids) id WHERE id IS NULL OR id <= 0) THEN
    RAISE EXCEPTION 'Lista de productos inválida';
  END IF;
  RETURN QUERY
    SELECT jsonb_build_object(
      'product_id', profile.product_id,
      'revision', profile.revision,
      'profile', profile.profile
    )
    FROM public.product_unit_profiles profile
    WHERE profile.product_id = ANY(p_product_ids)
    ORDER BY profile.product_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.save_product_unit_profile_v1(
  p_product_id bigint,
  p_expected_revision bigint,
  p_profile jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_current public.product_unit_profiles%ROWTYPE;
  v_saved public.product_unit_profiles%ROWTYPE;
BEGIN
  IF NOT public.app_es_admin() THEN
    RAISE EXCEPTION 'Solo un administrador puede editar presentaciones';
  END IF;
  IF p_product_id IS NULL OR p_product_id <= 0
     OR p_expected_revision IS NULL OR p_expected_revision < 0 THEN
    RAISE EXCEPTION 'Producto o revisión inválidos';
  END IF;
  PERFORM 1 FROM public.productos p
    WHERE p.id = p_product_id AND COALESCE(p.activo, true)
    FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Producto inexistente o inactivo'; END IF;
  PERFORM public._validate_product_unit_profile(p_profile);
  SELECT * INTO v_current FROM public.product_unit_profiles
    WHERE product_id = p_product_id FOR UPDATE;

  IF FOUND THEN
    IF v_current.revision <> p_expected_revision THEN
      RAISE EXCEPTION USING ERRCODE = '40001',
        MESSAGE = 'La configuración cambió en otro equipo';
    END IF;
    IF v_current.profile->>'base_code' <> p_profile->>'base_code' THEN
      RAISE EXCEPTION 'La unidad base no puede sustituirse sin convertir inventario';
    END IF;
    UPDATE public.product_unit_profiles
      SET profile = p_profile, revision = revision + 1, updated_at = now()
      WHERE product_id = p_product_id RETURNING * INTO v_saved;
  ELSE
    IF p_expected_revision <> 0 THEN
      RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'La configuración ya no existe';
    END IF;
    BEGIN
      INSERT INTO public.product_unit_profiles(product_id, revision, profile)
        VALUES (p_product_id, 1, p_profile) RETURNING * INTO v_saved;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION USING ERRCODE = '40001',
        MESSAGE = 'La configuración fue creada en otro equipo';
    END;
  END IF;
  RETURN jsonb_build_object('revision', v_saved.revision, 'profile', v_saved.profile);
END;
$function$;

CREATE OR REPLACE FUNCTION public._protect_profile_stock_contract()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF EXISTS (SELECT 1 FROM public.product_unit_profiles u WHERE u.product_id = OLD.id)
     AND (OLD.tipo_venta IS DISTINCT FROM NEW.tipo_venta
          OR OLD.cantidad_por_caja IS DISTINCT FROM NEW.cantidad_por_caja) THEN
    RAISE EXCEPTION 'No se puede cambiar la unidad histórica mientras el producto tiene presentaciones configuradas';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER protect_profile_stock_contract
BEFORE UPDATE OF tipo_venta, cantidad_por_caja ON public.productos
FOR EACH ROW EXECUTE FUNCTION public._protect_profile_stock_contract();

CREATE OR REPLACE FUNCTION public.process_sale_with_units_v1(
  p_request_id uuid, p_cliente_id bigint, p_total numeric,
  p_fecha timestamptz, p_es_credito boolean, p_monto_abono numeric,
  p_detalles jsonb, p_pagos jsonb, p_cotizacion_id bigint,
  p_vendedor_id bigint, p_tipo_comprobante text,
  p_descuento_global_porcentaje numeric, p_descuento_global_monto numeric,
  p_motivo_descuento text, p_subtotal_bruto numeric,
  p_descuento_autorizado_por bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_detail jsonb;
  v_normalized jsonb := '[]'::jsonb;
  v_snapshots jsonb := '[]'::jsonb;
  v_profile public.product_unit_profiles%ROWTYPE;
  v_presentation jsonb;
  v_product_type text;
  v_quantity integer;
  v_base integer;
  v_factor integer;
  v_price numeric;
  v_subtotal numeric;
  v_legacy_unit text;
  v_base_label text;
  v_result jsonb;
  v_sale_id bigint;
BEGIN
  IF NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado';
  END IF;
  IF p_detalles IS NULL OR jsonb_typeof(p_detalles) <> 'array'
     OR jsonb_array_length(p_detalles) = 0 THEN
    RAISE EXCEPTION 'La venta requiere detalles';
  END IF;
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'request_id es obligatorio para evitar ventas duplicadas';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));

  -- Los reintentos deben seguir siendo idempotentes aunque después se edite el perfil.
  IF EXISTS (SELECT 1 FROM public.ventas v WHERE v.request_id = p_request_id) THEN
    RETURN public.process_sale_v3(p_request_id, p_cliente_id, p_total, p_fecha,
      p_es_credito, p_monto_abono, p_detalles, p_pagos, p_cotizacion_id,
      p_vendedor_id, p_tipo_comprobante, p_descuento_global_porcentaje,
      p_descuento_global_monto, p_motivo_descuento, p_subtotal_bruto,
      p_descuento_autorizado_por);
  END IF;

  FOR v_detail IN SELECT value FROM jsonb_array_elements(p_detalles) LOOP
    IF NOT (v_detail ? 'unit_profile_revision') THEN
      v_normalized := v_normalized || jsonb_build_array(v_detail);
      v_snapshots := v_snapshots || jsonb_build_array(NULL);
      CONTINUE;
    END IF;
    IF lower(trim(COALESCE(p_tipo_comprobante, 'ticket_interno'))) NOT IN ('ticket', 'ticket_interno') THEN
      RAISE EXCEPTION 'Las presentaciones configurables requieren Ticket Interno en esta versión';
    END IF;
    SELECT lower(COALESCE(p.tipo_venta, '')) INTO v_product_type
      FROM public.productos p
      WHERE p.id = (v_detail->>'producto_id')::bigint
        AND COALESCE(p.activo, true)
      FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Producto inexistente o inactivo'; END IF;
    SELECT u.* INTO v_profile FROM public.product_unit_profiles u
      WHERE u.product_id = (v_detail->>'producto_id')::bigint FOR SHARE;
    IF NOT FOUND OR v_profile.revision <> (v_detail->>'unit_profile_revision')::bigint THEN
      RAISE EXCEPTION 'Las presentaciones del producto cambiaron; vuelve a seleccionarlo';
    END IF;
    PERFORM public._validate_product_unit_profile(v_profile.profile);
    SELECT value INTO v_presentation
      FROM jsonb_array_elements(v_profile.profile->'presentations')
      WHERE value->>'code' = v_detail->>'tipo_unidad';
    IF v_presentation IS NULL THEN
      RAISE EXCEPTION 'La presentación ya no existe';
    END IF;
    SELECT value->>'singular' INTO v_base_label
      FROM jsonb_array_elements(v_profile.profile->'presentations')
      WHERE value->>'code' = v_profile.profile->>'base_code';
    IF v_base_label IS NULL THEN
      RAISE EXCEPTION 'La unidad base del perfil no existe';
    END IF;
    v_quantity := NULLIF(v_detail->>'cantidad', '')::integer;
    v_base := NULLIF(v_detail->>'piezas_reales', '')::integer;
    v_factor := (v_presentation->>'factor')::integer;
    v_subtotal := NULLIF(v_detail->>'subtotal', '')::numeric;
    v_price := NULLIF(v_detail->>'precio_unitario_comercial', '')::numeric;
    IF v_quantity IS NULL OR v_quantity <= 0
       OR v_base IS NULL OR v_base <= 0 OR v_base > 2147483647
       OR v_factor IS NULL OR v_factor <= 0
       OR v_quantity > 2147483647 / v_factor
       OR v_base::bigint <> v_quantity::bigint * v_factor::bigint
       OR v_subtotal IS NULL
       OR v_subtotal::text IN ('NaN', 'Infinity', '-Infinity')
       OR v_subtotal < 0
       OR v_price IS NULL
       OR v_price::text IN ('NaN', 'Infinity', '-Infinity') OR v_price < 0
       OR abs(v_subtotal - v_quantity * v_price) > 0.02 THEN
      RAISE EXCEPTION 'Cantidad o precio comercial inconsistente';
    END IF;
    v_legacy_unit := CASE
      WHEN v_product_type IN ('paquetes', 'paquete', 'caja_paquetes') THEN 'paquete'
      WHEN v_product_type IN ('solo_cajas', 'caja') THEN 'caja'
      ELSE 'unidad' END;
    IF abs(v_subtotal - v_base * round(v_subtotal / v_base, 4)) > 0.02 THEN
      RAISE EXCEPTION 'El factor y la cantidad requieren más precisión de precio; divide la línea';
    END IF;
    v_normalized := v_normalized || jsonb_build_array(v_detail || jsonb_build_object(
      'cantidad', v_base, 'tipo_unidad', v_legacy_unit,
      'precio_unitario_comercial', round(v_subtotal / v_base, 4)));
    v_snapshots := v_snapshots || jsonb_build_array(jsonb_build_object(
      'schema_version', 1, 'code', v_presentation->>'code',
      'singular', v_presentation->>'singular', 'plural', v_presentation->>'plural',
      'factor', v_factor, 'quantity', v_quantity, 'commercial_price', v_price,
      'base_code', v_profile.profile->>'base_code',
      'base_label', v_base_label, 'revision', v_profile.revision));
  END LOOP;

  v_result := public.process_sale_v3(p_request_id, p_cliente_id, p_total, p_fecha,
    p_es_credito, p_monto_abono, v_normalized, p_pagos, p_cotizacion_id,
    p_vendedor_id, p_tipo_comprobante, p_descuento_global_porcentaje,
    p_descuento_global_monto, p_motivo_descuento, p_subtotal_bruto,
    p_descuento_autorizado_por);
  v_sale_id := (v_result->>'venta_id')::bigint;
  IF (SELECT count(*) FROM public.detalle_ventas WHERE venta_id = v_sale_id)
       <> jsonb_array_length(v_snapshots) THEN
    RAISE EXCEPTION 'No se pudo asociar el snapshot de presentaciones';
  END IF;
  WITH saved AS (
    SELECT id, row_number() OVER (ORDER BY id) ordinal
    FROM public.detalle_ventas WHERE venta_id = v_sale_id
  ), snapshots AS (
    SELECT value snapshot, ordinality ordinal
    FROM jsonb_array_elements(v_snapshots) WITH ORDINALITY
  )
  UPDATE public.detalle_ventas detail
     SET presentation_snapshot = snapshots.snapshot
    FROM saved JOIN snapshots USING (ordinal)
   WHERE detail.id = saved.id AND snapshots.snapshot <> 'null'::jsonb;

  WITH source AS (
    SELECT (detail->>'producto_id')::bigint product_id,
           snapshot->>'base_label' base_label
    FROM jsonb_array_elements(p_detalles) WITH ORDINALITY input(detail, ordinal)
    JOIN jsonb_array_elements(v_snapshots) WITH ORDINALITY saved(snapshot, ordinal)
      USING (ordinal)
    WHERE snapshot <> 'null'::jsonb
  )
  UPDATE public.inventario_movimientos movement
     SET salida_und = source.base_label,
         unidad_base_snapshot = source.base_label
    FROM source
   WHERE movement.request_id = p_request_id
     AND movement.producto_id = source.product_id
     AND movement.tipo = 'SALIDA';
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public._validate_product_unit_profile(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._enforce_product_unit_profile() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._protect_profile_stock_contract() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_product_unit_profiles_v1(bigint[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.save_product_unit_profile_v1(bigint,bigint,jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.process_sale_with_units_v1(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_product_unit_profiles_v1(bigint[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_product_unit_profile_v1(bigint,bigint,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_sale_with_units_v1(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) TO authenticated;

COMMIT;
