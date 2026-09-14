BEGIN;

-- Electronic documents must derive their fiscal unit from the persisted
-- presentation profile. The client may select the presentation/revision, but it
-- cannot invent the SUNAT unit code used later by the emission boundary.
CREATE OR REPLACE FUNCTION public.process_sale_with_units_v3(
  p_request_id uuid,
  p_cliente_id bigint,
  p_total numeric,
  p_fecha timestamptz,
  p_es_credito boolean,
  p_monto_abono numeric,
  p_detalles jsonb,
  p_pagos jsonb,
  p_cotizacion_id bigint,
  p_vendedor_id bigint,
  p_tipo_comprobante text,
  p_descuento_global_porcentaje numeric,
  p_descuento_global_monto numeric,
  p_motivo_descuento text,
  p_subtotal_bruto numeric,
  p_descuento_autorizado_por bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_detail jsonb;
  v_profile public.product_unit_profiles%ROWTYPE;
  v_presentation jsonb;
  v_document_type text := lower(trim(coalesce(p_tipo_comprobante, 'ticket_interno')));
  v_fiscal_code text;
BEGIN
  IF v_document_type IN ('boleta', 'factura') THEN
    IF p_detalles IS NULL OR jsonb_typeof(p_detalles) IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION 'La venta requiere detalles válidos';
    END IF;

    FOR v_detail IN SELECT value FROM jsonb_array_elements(p_detalles) LOOP
      IF NOT (v_detail ? 'unit_profile_revision') THEN
        CONTINUE;
      END IF;

      SELECT u.*
      INTO v_profile
      FROM public.product_unit_profiles AS u
      WHERE u.product_id = NULLIF(v_detail->>'producto_id', '')::bigint
      FOR SHARE;

      IF NOT FOUND
         OR v_profile.revision <> NULLIF(v_detail->>'unit_profile_revision', '')::bigint THEN
        RAISE EXCEPTION
          'Las presentaciones del producto cambiaron; vuelve a seleccionarlo';
      END IF;

      PERFORM public._validate_product_unit_profile_v2(v_profile.profile);
      PERFORM public._validate_product_unit_fiscal_codes_v1(v_profile.profile);

      SELECT value
      INTO v_presentation
      FROM jsonb_array_elements(v_profile.profile->'presentations')
      WHERE value->>'code' = v_detail->>'tipo_unidad';

      IF v_presentation IS NULL THEN
        RAISE EXCEPTION 'La presentación seleccionada ya no existe';
      END IF;

      v_fiscal_code := upper(trim(coalesce(v_presentation->>'fiscal_unit_code', '')));
      IF v_fiscal_code = '' OR v_fiscal_code !~ '^[A-Z0-9]{1,6}$' THEN
        RAISE EXCEPTION
          'La presentación % no tiene un código fiscal válido para boleta/factura',
          coalesce(v_presentation->>'singular', v_presentation->>'code', '?');
      END IF;
    END LOOP;
  END IF;

  RETURN public.process_sale_with_units_v2(
    p_request_id,
    p_cliente_id,
    p_total,
    p_fecha,
    p_es_credito,
    p_monto_abono,
    p_detalles,
    p_pagos,
    p_cotizacion_id,
    p_vendedor_id,
    p_tipo_comprobante,
    p_descuento_global_porcentaje,
    p_descuento_global_monto,
    p_motivo_descuento,
    p_subtotal_bruto,
    p_descuento_autorizado_por
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.process_sale_with_units_v3(
  uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,
  text,numeric,numeric,text,numeric,bigint
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_sale_with_units_v3(
  uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,
  text,numeric,numeric,text,numeric,bigint
) TO authenticated;

COMMIT;
