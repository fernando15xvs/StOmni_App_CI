BEGIN;

ALTER TABLE public.detalle_cotizaciones
  ADD COLUMN IF NOT EXISTS presentation_snapshot jsonb;

CREATE OR REPLACE FUNCTION public.guardar_cotizacion_with_units_v1(
  p_request_id uuid,
  p_cliente_id bigint,
  p_total numeric,
  p_fecha timestamptz,
  p_observaciones text,
  p_validez_dias integer,
  p_detalles jsonb
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
  v_quote_id bigint;
BEGIN
  IF NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado';
  END IF;
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'request_id es obligatorio para evitar cotizaciones duplicadas';
  END IF;
  IF p_detalles IS NULL OR jsonb_typeof(p_detalles) <> 'array'
     OR jsonb_array_length(p_detalles) = 0 THEN
    RAISE EXCEPTION 'La cotización requiere detalles';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));

  SELECT c.id INTO v_quote_id
  FROM public.cotizaciones c
  WHERE c.request_id = p_request_id;
  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'idempotent', true,
      'cotizacion_id', v_quote_id
    );
  END IF;

  FOR v_detail IN SELECT value FROM jsonb_array_elements(p_detalles)
  LOOP
    IF NOT (v_detail ? 'unit_profile_revision') THEN
      v_normalized := v_normalized || jsonb_build_array(v_detail);
      v_snapshots := v_snapshots || jsonb_build_array(NULL);
      CONTINUE;
    END IF;

    SELECT lower(COALESCE(p.tipo_venta, '')) INTO v_product_type
    FROM public.productos p
    WHERE p.id = (v_detail->>'producto_id')::bigint
      AND COALESCE(p.activo, true)
    FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Producto inexistente o inactivo';
    END IF;

    SELECT u.* INTO v_profile
    FROM public.product_unit_profiles u
    WHERE u.product_id = (v_detail->>'producto_id')::bigint
    FOR SHARE;
    IF NOT FOUND OR
       v_profile.revision <> (v_detail->>'unit_profile_revision')::bigint THEN
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
       OR v_price::text IN ('NaN', 'Infinity', '-Infinity')
       OR v_price < 0
       OR abs(v_subtotal - v_quantity * v_price) > 0.02 THEN
      RAISE EXCEPTION 'Cantidad o precio comercial inconsistente';
    END IF;

    v_legacy_unit := CASE
      WHEN v_product_type IN ('paquetes', 'paquete', 'caja_paquetes') THEN 'paquete'
      WHEN v_product_type IN ('solo_cajas', 'caja') THEN 'caja'
      ELSE 'unidad'
    END;

    IF abs(v_subtotal - v_base * round(v_subtotal / v_base, 4)) > 0.02 THEN
      RAISE EXCEPTION 'El factor y la cantidad requieren más precisión de precio; divide la línea';
    END IF;

    -- guardar_cotizacion_v2 continúa siendo la única implementación legacy.
    -- Se le entrega la cantidad base para que sus reglas históricas no tengan
    -- que conocer códigos configurables. La presentación visual se restaura
    -- exclusivamente desde presentation_snapshot.
    v_normalized := v_normalized || jsonb_build_array(
      v_detail || jsonb_build_object(
        'cantidad', v_base,
        'piezas_reales', v_base,
        'tipo_unidad', v_legacy_unit,
        'precio_unitario', round(v_subtotal / v_base, 4),
        'precio_unitario_comercial', round(v_subtotal / v_base, 4)
      )
    );

    v_snapshots := v_snapshots || jsonb_build_array(jsonb_build_object(
      'schema_version', 1,
      'code', v_presentation->>'code',
      'singular', v_presentation->>'singular',
      'plural', v_presentation->>'plural',
      'factor', v_factor,
      'quantity', v_quantity,
      'commercial_price', v_price,
      'base_code', v_profile.profile->>'base_code',
      'base_label', v_base_label,
      'revision', v_profile.revision,
      'profile', v_profile.profile
    ));
  END LOOP;

  v_result := public.guardar_cotizacion_v2(
    p_request_id,
    p_cliente_id,
    p_total,
    p_fecha,
    p_observaciones,
    p_validez_dias,
    v_normalized
  );
  v_quote_id := (v_result->>'cotizacion_id')::bigint;

  IF v_quote_id IS NULL OR
     (SELECT count(*) FROM public.detalle_cotizaciones
      WHERE cotizacion_id = v_quote_id) <> jsonb_array_length(v_snapshots) THEN
    RAISE EXCEPTION 'No se pudo asociar el snapshot de presentaciones de la cotización';
  END IF;

  WITH saved AS (
    SELECT id, row_number() OVER (ORDER BY id) ordinal
    FROM public.detalle_cotizaciones
    WHERE cotizacion_id = v_quote_id
  ), snapshots AS (
    SELECT value snapshot, ordinality ordinal
    FROM jsonb_array_elements(v_snapshots) WITH ORDINALITY
  )
  UPDATE public.detalle_cotizaciones detail
     SET presentation_snapshot = snapshots.snapshot
    FROM saved JOIN snapshots USING (ordinal)
   WHERE detail.id = saved.id
     AND snapshots.snapshot <> 'null'::jsonb;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.guardar_cotizacion_with_units_v1(
  uuid,bigint,numeric,timestamptz,text,integer,jsonb
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guardar_cotizacion_with_units_v1(
  uuid,bigint,numeric,timestamptz,text,integer,jsonb
) TO authenticated;

COMMIT;
