BEGIN;

ALTER TABLE public.notas_credito_detalles
  ADD COLUMN IF NOT EXISTS commercial_quantity_snapshot numeric(18,6),
  ADD COLUMN IF NOT EXISTS presentation_snapshot jsonb,
  ADD COLUMN IF NOT EXISTS fiscal_unit_code_snapshot text,
  ADD COLUMN IF NOT EXISTS stock_scale_snapshot integer;

ALTER TABLE public.notas_credito_detalles
  DROP CONSTRAINT IF EXISTS notas_credito_detalles_fiscal_unit_code_snapshot_check;
ALTER TABLE public.notas_credito_detalles
  ADD CONSTRAINT notas_credito_detalles_fiscal_unit_code_snapshot_check
  CHECK (
    fiscal_unit_code_snapshot IS NULL
    OR fiscal_unit_code_snapshot ~ '^[A-Z0-9]{1,6}$'
  );

ALTER TABLE public.notas_credito_detalles
  DROP CONSTRAINT IF EXISTS notas_credito_detalles_stock_scale_snapshot_check;
ALTER TABLE public.notas_credito_detalles
  ADD CONSTRAINT notas_credito_detalles_stock_scale_snapshot_check
  CHECK (stock_scale_snapshot IS NULL OR stock_scale_snapshot > 0);

-- Backfill immutable commercial representation before any lazy internal rebase.
-- Accepted historical notes keep their already persisted remote payload; these
-- fields are used for local regeneration/availability and future notes.
UPDATE public.notas_credito_detalles ncd
SET presentation_snapshot = dv.presentation_snapshot,
    stock_scale_snapshot = COALESCE(
      NULLIF(dv.presentation_snapshot->>'storage_scale', '')::integer,
      1
    ),
    commercial_quantity_snapshot = CASE
      WHEN NULLIF(dv.presentation_snapshot->>'quantity', '')::numeric > 0
       AND NULLIF(dv.presentation_snapshot->>'base_quantity', '')::numeric > 0
       AND COALESCE(NULLIF(dv.presentation_snapshot->>'storage_scale', '')::integer, 1) > 0
      THEN round(
        ncd.cantidad_visual::numeric
        * (dv.presentation_snapshot->>'quantity')::numeric
        / (
          (dv.presentation_snapshot->>'base_quantity')::numeric
          * COALESCE(NULLIF(dv.presentation_snapshot->>'storage_scale', '')::integer, 1)
        ),
        6
      )
      ELSE NULL
    END,
    fiscal_unit_code_snapshot = (
      SELECT NULLIF(p.value->>'fiscal_unit_code', '')
      FROM jsonb_array_elements(dv.presentation_snapshot->'profile'->'presentations') p(value)
      WHERE p.value->>'code' = dv.presentation_snapshot->>'code'
      LIMIT 1
    )
FROM public.detalle_ventas dv
WHERE dv.id = ncd.detalle_venta_id
  AND dv.presentation_snapshot IS NOT NULL
  AND COALESCE((dv.presentation_snapshot->>'schema_version')::integer, 0) = 2
  AND ncd.presentation_snapshot IS NULL;

CREATE OR REPLACE FUNCTION public._rebase_credit_note_stock_to_current_scale_for_sale_v1(
  p_venta_id bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_row record;
  v_current_scale integer;
  v_visual integer;
  v_pieces integer;
BEGIN
  IF p_venta_id IS NULL OR p_venta_id <= 0 THEN
    RAISE EXCEPTION 'Venta inválida';
  END IF;

  FOR v_row IN
    SELECT ncd.id,
           ncd.cantidad_visual,
           ncd.piezas_reales,
           GREATEST(COALESCE(ncd.stock_scale_snapshot, 1), 1) AS snapshot_scale,
           dv.producto_id
    FROM public.notas_credito_detalles ncd
    JOIN public.notas_credito nc ON nc.id = ncd.nota_credito_id
    JOIN public.detalle_ventas dv ON dv.id = ncd.detalle_venta_id
    WHERE nc.venta_id = p_venta_id
      AND ncd.detalle_venta_id IS NOT NULL
    FOR UPDATE OF ncd
  LOOP
    v_current_scale := public._product_storage_scale_for_id(v_row.producto_id);
    IF v_current_scale = v_row.snapshot_scale THEN
      CONTINUE;
    END IF;

    PERFORM pg_advisory_xact_lock(v_row.producto_id);
    v_visual := public._stock_quantity_at_current_scale(
      v_row.producto_id,
      COALESCE(v_row.cantidad_visual, 0),
      v_row.snapshot_scale
    );
    v_pieces := CASE
      WHEN v_row.piezas_reales IS NULL THEN NULL
      ELSE public._stock_quantity_at_current_scale(
        v_row.producto_id,
        v_row.piezas_reales,
        v_row.snapshot_scale
      )
    END;

    UPDATE public.notas_credito_detalles
    SET cantidad_visual = v_visual,
        piezas_reales = v_pieces,
        stock_scale_snapshot = v_current_scale
    WHERE id = v_row.id;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.obtener_disponibilidad_nota_credito_v2(
  p_comprobante_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_base jsonb;
  v_row jsonb;
  v_details jsonb := '[]'::jsonb;
  v_detail_id bigint;
  v_sale_detail record;
  v_original_commercial numeric;
  v_original_stored_snapshot numeric;
  v_committed_commercial numeric;
  v_available_commercial numeric;
  v_presentation jsonb;
BEGIN
  v_base := public.obtener_disponibilidad_nota_credito(p_comprobante_id);
  IF jsonb_typeof(v_base->'detalles') IS DISTINCT FROM 'array' THEN
    RETURN v_base;
  END IF;

  FOR v_row IN SELECT value FROM jsonb_array_elements(v_base->'detalles') LOOP
    v_detail_id := NULLIF(v_row->>'detalle_venta_id', '')::bigint;
    IF v_detail_id IS NULL THEN
      v_details := v_details || jsonb_build_array(v_row);
      CONTINUE;
    END IF;

    SELECT dv.presentation_snapshot
    INTO v_sale_detail
    FROM public.detalle_ventas dv
    WHERE dv.id = v_detail_id;

    IF NOT FOUND
       OR v_sale_detail.presentation_snapshot IS NULL
       OR COALESCE((v_sale_detail.presentation_snapshot->>'schema_version')::integer, 0) <> 2 THEN
      v_details := v_details || jsonb_build_array(v_row);
      CONTINUE;
    END IF;

    v_original_commercial := NULLIF(v_sale_detail.presentation_snapshot->>'quantity', '')::numeric;
    v_original_stored_snapshot :=
      NULLIF(v_sale_detail.presentation_snapshot->>'base_quantity', '')::numeric
      * COALESCE(NULLIF(v_sale_detail.presentation_snapshot->>'storage_scale', '')::integer, 1);

    IF v_original_commercial IS NULL OR v_original_commercial <= 0
       OR v_original_stored_snapshot IS NULL OR v_original_stored_snapshot <= 0 THEN
      RAISE EXCEPTION 'Snapshot comercial inválido para el detalle de venta %', v_detail_id;
    END IF;

    SELECT COALESCE(SUM(
      COALESCE(
        ncd.commercial_quantity_snapshot,
        round(
          ncd.cantidad_visual::numeric * v_original_commercial
          / v_original_stored_snapshot,
          6
        )
      )
    ), 0)
    INTO v_committed_commercial
    FROM public.notas_credito_detalles ncd
    JOIN public.notas_credito nc ON nc.id = ncd.nota_credito_id
    WHERE ncd.detalle_venta_id = v_detail_id
      AND nc.afecta_stock = true
      AND nc.estado IN (
        'pendiente_envio',
        'procesando',
        'pendiente_reintento',
        'resultado_incierto',
        'aceptado'
      );

    v_available_commercial := GREATEST(
      round(v_original_commercial - v_committed_commercial, 6),
      0
    );

    SELECT value INTO v_presentation
    FROM jsonb_array_elements(v_sale_detail.presentation_snapshot->'profile'->'presentations')
    WHERE value->>'code' = v_sale_detail.presentation_snapshot->>'code'
    LIMIT 1;

    v_details := v_details || jsonb_build_array(
      v_row || jsonb_build_object(
        'cantidad_original', v_original_commercial,
        'cantidad_comprometida', v_committed_commercial,
        'cantidad_disponible', v_available_commercial,
        'tipo_unidad', COALESCE(v_presentation->>'singular', v_row->>'tipo_unidad'),
        'presentation_code', v_sale_detail.presentation_snapshot->>'code',
        'quantity_precision', COALESCE((v_presentation->>'precision')::integer, 0),
        'presentation_snapshot', v_sale_detail.presentation_snapshot
      )
    );
  END LOOP;

  RETURN jsonb_set(v_base, '{detalles}', v_details, true);
END;
$function$;

CREATE OR REPLACE FUNCTION public.crear_nota_credito_with_units_v3(
  p_request_id uuid,
  p_comprobante_id uuid,
  p_motivo_codigo text,
  p_motivo_descripcion text DEFAULT NULL,
  p_detalles jsonb DEFAULT '[]'::jsonb,
  p_monto_descuento numeric DEFAULT NULL,
  p_reponer_stock boolean DEFAULT true,
  p_fecha timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_input jsonb;
  v_normalized jsonb := '[]'::jsonb;
  v_requested jsonb := '{}'::jsonb;
  v_detail_id bigint;
  v_requested_commercial numeric;
  v_sale_detail record;
  v_original_commercial numeric;
  v_original_stored numeric;
  v_requested_stored numeric;
  v_result jsonb;
  v_note_id uuid;
  v_presentation jsonb;
  v_venta_id bigint;
BEGIN
  IF p_detalles IS NULL OR jsonb_typeof(p_detalles) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Los detalles de la nota deben ser un arreglo';
  END IF;

  SELECT ce.venta_id INTO v_venta_id
  FROM public.comprobantes_electronicos ce
  WHERE ce.id = p_comprobante_id
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Comprobante inexistente';
  END IF;

  -- Align internal stock quantities before passing them to the legacy NC engine.
  PERFORM public._rebase_sale_stock_to_current_scale_v1(v_venta_id);
  PERFORM public._rebase_credit_note_stock_to_current_scale_for_sale_v1(v_venta_id);

  FOR v_input IN SELECT value FROM jsonb_array_elements(p_detalles) LOOP
    v_detail_id := NULLIF(v_input->>'detalle_venta_id', '')::bigint;
    IF v_detail_id IS NULL OR NOT (v_input ? 'cantidad') THEN
      v_normalized := v_normalized || jsonb_build_array(v_input);
      CONTINUE;
    END IF;

    SELECT dv.cantidad,
           dv.piezas_reales,
           dv.presentation_snapshot,
           dv.stock_scale_snapshot
    INTO v_sale_detail
    FROM public.detalle_ventas dv
    WHERE dv.id = v_detail_id
      AND dv.venta_id = v_venta_id
    FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Detalle de venta inexistente: %', v_detail_id;
    END IF;

    IF v_sale_detail.presentation_snapshot IS NULL
       OR COALESCE((v_sale_detail.presentation_snapshot->>'schema_version')::integer, 0) <> 2 THEN
      v_normalized := v_normalized || jsonb_build_array(v_input);
      CONTINUE;
    END IF;

    v_requested_commercial := NULLIF(v_input->>'cantidad', '')::numeric;
    v_original_commercial := NULLIF(v_sale_detail.presentation_snapshot->>'quantity', '')::numeric;
    v_original_stored := COALESCE(v_sale_detail.piezas_reales, v_sale_detail.cantidad, 0)::numeric;

    IF v_requested_commercial IS NULL OR v_requested_commercial <= 0
       OR v_original_commercial IS NULL OR v_original_commercial <= 0
       OR v_requested_commercial > v_original_commercial
       OR v_original_stored <= 0 THEN
      RAISE EXCEPTION 'Cantidad comercial inválida para el detalle %', v_detail_id;
    END IF;

    v_requested_stored := v_requested_commercial * v_original_stored / v_original_commercial;
    IF v_requested_stored <> trunc(v_requested_stored)
       OR v_requested_stored <= 0
       OR v_requested_stored > 2147483647 THEN
      RAISE EXCEPTION 'La devolución no coincide con la precisión de stock del producto';
    END IF;

    v_normalized := v_normalized || jsonb_build_array(
      v_input || jsonb_build_object('cantidad', v_requested_stored::integer)
    );
    v_requested := v_requested || jsonb_build_object(
      v_detail_id::text,
      jsonb_build_object(
        'quantity', v_requested_commercial,
        'presentation_snapshot', v_sale_detail.presentation_snapshot
      )
    );
  END LOOP;

  v_result := public.crear_nota_credito_v1(
    p_request_id,
    p_comprobante_id,
    p_motivo_codigo,
    p_motivo_descripcion,
    v_normalized,
    p_monto_descuento,
    p_reponer_stock,
    p_fecha
  );

  v_note_id := NULLIF(v_result->>'nota_credito_id', '')::uuid;
  IF v_note_id IS NULL THEN
    RETURN v_result;
  END IF;

  -- Persist immutable commercial/fiscal representation. For total cancellation
  -- or description correction, derive the commercial quantity from the internal
  -- quantity created by the legacy engine after both sides share the same scale.
  FOR v_sale_detail IN
    SELECT ncd.id AS note_detail_id,
           ncd.detalle_venta_id,
           ncd.cantidad_visual,
           dv.presentation_snapshot,
           dv.cantidad,
           dv.piezas_reales,
           dv.stock_scale_snapshot
    FROM public.notas_credito_detalles ncd
    JOIN public.detalle_ventas dv ON dv.id = ncd.detalle_venta_id
    WHERE ncd.nota_credito_id = v_note_id
      AND dv.presentation_snapshot IS NOT NULL
      AND COALESCE((dv.presentation_snapshot->>'schema_version')::integer, 0) = 2
  LOOP
    SELECT value INTO v_presentation
    FROM jsonb_array_elements(v_sale_detail.presentation_snapshot->'profile'->'presentations')
    WHERE value->>'code' = v_sale_detail.presentation_snapshot->>'code'
    LIMIT 1;

    IF v_presentation IS NULL THEN
      RAISE EXCEPTION 'La presentación de la venta no existe en su snapshot';
    END IF;

    v_requested_commercial := NULLIF(
      (v_requested -> (v_sale_detail.detalle_venta_id::text)) ->> 'quantity',
      ''
    )::numeric;
    IF v_requested_commercial IS NULL THEN
      v_original_commercial := NULLIF(v_sale_detail.presentation_snapshot->>'quantity', '')::numeric;
      v_original_stored := COALESCE(v_sale_detail.piezas_reales, v_sale_detail.cantidad, 0)::numeric;
      v_requested_commercial := round(
        v_sale_detail.cantidad_visual::numeric
        * v_original_commercial / v_original_stored,
        6
      );
    END IF;

    UPDATE public.notas_credito_detalles
    SET commercial_quantity_snapshot = v_requested_commercial,
        presentation_snapshot = v_sale_detail.presentation_snapshot,
        fiscal_unit_code_snapshot = NULLIF(v_presentation->>'fiscal_unit_code', ''),
        stock_scale_snapshot = GREATEST(COALESCE(v_sale_detail.stock_scale_snapshot, 1), 1)
    WHERE id = v_sale_detail.note_detail_id;
  END LOOP;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public._rebase_credit_note_stock_to_current_scale_for_sale_v1(bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.obtener_disponibilidad_nota_credito_v2(uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.crear_nota_credito_with_units_v3(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_disponibilidad_nota_credito_v2(uuid)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.crear_nota_credito_with_units_v3(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)
  TO authenticated;

COMMIT;
