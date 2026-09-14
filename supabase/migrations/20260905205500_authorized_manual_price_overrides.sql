BEGIN;

CREATE OR REPLACE FUNCTION public._assert_authorized_sale_prices_v1(
  p_detalles jsonb,
  p_fecha timestamptz,
  p_cotizacion_id bigint
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_detail jsonb;
  v_resolved jsonb;
  v_expected numeric;
  v_sent numeric;
  v_quantity numeric;
BEGIN
  -- Una cotización congela sus precios; el flujo de conversión conserva ese
  -- snapshot incluso si catálogo/promociones cambian después.
  IF p_cotizacion_id IS NOT NULL THEN RETURN; END IF;

  FOR v_detail IN SELECT value FROM jsonb_array_elements(p_detalles) LOOP
    v_quantity:=NULLIF(v_detail->>'cantidad','')::numeric;
    v_sent:=NULLIF(v_detail->>'precio_unitario_comercial','')::numeric;
    IF v_sent IS NULL THEN v_sent:=NULLIF(v_detail->>'precio','')::numeric; END IF;
    v_resolved:=public.resolve_sale_price_v1(
      (v_detail->>'producto_id')::bigint,
      v_detail->>'tipo_unidad',
      v_quantity,
      coalesce(p_fecha,now())
    );
    v_expected:=(v_resolved->>'price')::numeric;

    IF v_sent IS NULL OR v_sent<0 THEN
      RAISE EXCEPTION 'Precio de venta inválido para el producto %',
        v_detail->>'producto_id' USING ERRCODE='23514';
    END IF;

    -- El precio resuelto es la referencia autoritativa. El sistema histórico
    -- admite negociación manual por línea; esa desviación requiere el mismo
    -- permiso explícito de descuento que ya protege descuentos globales.
    IF abs(v_sent-v_expected)>0.01
       AND NOT public.app_tiene_permiso('sales.discount') THEN
      RAISE EXCEPTION 'El precio manual no está autorizado para el producto %',
        v_detail->>'producto_id' USING ERRCODE='42501';
    END IF;
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public._assert_authorized_sale_prices_v1(jsonb,timestamptz,bigint)
  FROM PUBLIC,anon,authenticated;

COMMIT;