BEGIN;

-- Keep the public RPC names stable for every existing client while inserting
-- the scale-normalization guard in front of the hardened legacy implementation.
ALTER FUNCTION public.anular_venta_v2(bigint, text)
  RENAME TO anular_venta_v2_unscaled_legacy;

CREATE OR REPLACE FUNCTION public.anular_venta_v2(
  p_venta_id bigint,
  p_motivo text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  PERFORM public._rebase_sale_stock_to_current_scale_v1(p_venta_id);
  RETURN public.anular_venta_v2_unscaled_legacy(p_venta_id, p_motivo);
END;
$function$;

-- The helper wrapper introduced in the previous migration must target the
-- renamed implementation to avoid recursive calls after this compatibility
-- layer takes ownership of the original public RPC name.
CREATE OR REPLACE FUNCTION public.anular_venta_with_units_v3(
  p_venta_id bigint,
  p_motivo text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  PERFORM public._rebase_sale_stock_to_current_scale_v1(p_venta_id);
  RETURN public.anular_venta_v2_unscaled_legacy(p_venta_id, p_motivo);
END;
$function$;

ALTER FUNCTION public.crear_nota_credito_v1(
  uuid, uuid, text, text, jsonb, numeric, boolean, timestamptz
) RENAME TO crear_nota_credito_v1_unscaled_legacy;

CREATE OR REPLACE FUNCTION public.crear_nota_credito_v1(
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
  v_venta_id bigint;
BEGIN
  IF COALESCE(p_reponer_stock, true) THEN
    SELECT venta_id INTO v_venta_id
    FROM public.comprobantes_electronicos
    WHERE id = p_comprobante_id
    FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Comprobante inexistente';
    END IF;
    PERFORM public._rebase_sale_stock_to_current_scale_v1(v_venta_id);
  END IF;

  RETURN public.crear_nota_credito_v1_unscaled_legacy(
    p_request_id,
    p_comprobante_id,
    p_motivo_codigo,
    p_motivo_descripcion,
    p_detalles,
    p_monto_descuento,
    p_reponer_stock,
    p_fecha
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.crear_nota_credito_with_units_v2(
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
  v_venta_id bigint;
BEGIN
  IF COALESCE(p_reponer_stock, true) THEN
    SELECT venta_id INTO v_venta_id
    FROM public.comprobantes_electronicos
    WHERE id = p_comprobante_id
    FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Comprobante inexistente';
    END IF;
    PERFORM public._rebase_sale_stock_to_current_scale_v1(v_venta_id);
  END IF;

  RETURN public.crear_nota_credito_v1_unscaled_legacy(
    p_request_id,
    p_comprobante_id,
    p_motivo_codigo,
    p_motivo_descripcion,
    p_detalles,
    p_monto_descuento,
    p_reponer_stock,
    p_fecha
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.anular_venta_v2_unscaled_legacy(bigint,text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.crear_nota_credito_v1_unscaled_legacy(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.anular_venta_v2(bigint,text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.crear_nota_credito_v1(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.anular_venta_v2(bigint,text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.crear_nota_credito_v1(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)
  TO authenticated;

COMMIT;
