BEGIN;

-- Historical sales and quotations are immutable commercial records.  Changing
-- the current storage precision must never rewrite their quantities/prices.
-- Only current inventory (and its threshold) is rebased.  Reversible flows
-- translate historical quantities lazily through stock_scale_snapshot.
CREATE OR REPLACE FUNCTION public.save_product_unit_profile_v5(
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
  v_exists boolean := false;
  v_old_scale integer := 1;
  v_new_scale integer;
  v_divisor integer;
  v_ratio numeric;
  v_old_min integer;
BEGIN
  IF NOT public.app_es_admin() THEN
    RAISE EXCEPTION 'Solo un administrador puede editar presentaciones';
  END IF;
  IF p_product_id IS NULL OR p_product_id <= 0
     OR p_expected_revision IS NULL OR p_expected_revision < 0 THEN
    RAISE EXCEPTION 'Producto o revisión inválidos';
  END IF;

  PERFORM public._validate_product_unit_profile_v2(p_profile);
  v_new_scale := public._product_unit_storage_scale(p_profile);

  SELECT stock_minimo INTO v_old_min
  FROM public.productos
  WHERE id = p_product_id AND COALESCE(activo, true)
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Producto inexistente o inactivo';
  END IF;

  SELECT * INTO v_current
  FROM public.product_unit_profiles
  WHERE product_id = p_product_id
  FOR UPDATE;
  v_exists := FOUND;

  IF v_exists THEN
    IF v_current.revision <> p_expected_revision THEN
      RAISE EXCEPTION USING ERRCODE = '40001',
        MESSAGE = 'La configuración cambió en otro equipo';
    END IF;
    IF v_current.profile->>'base_code' <> p_profile->>'base_code' THEN
      RAISE EXCEPTION 'La unidad base no puede sustituirse sin una conversión explícita';
    END IF;
    v_old_scale := public._product_unit_storage_scale(v_current.profile);
  ELSIF p_expected_revision <> 0 THEN
    RAISE EXCEPTION USING ERRCODE = '40001',
      MESSAGE = 'La configuración ya no existe';
  END IF;

  IF v_new_scale <> v_old_scale THEN
    PERFORM pg_advisory_xact_lock(p_product_id);
    PERFORM 1
    FROM public.inventario_almacen
    WHERE producto_id = p_product_id
    FOR UPDATE;

    IF v_new_scale > v_old_scale THEN
      v_ratio := v_new_scale::numeric / v_old_scale::numeric;
      IF v_new_scale % v_old_scale <> 0 THEN
        RAISE EXCEPTION 'Conversión de precisión no soportada';
      END IF;
      IF EXISTS (
        SELECT 1
        FROM public.inventario_almacen
        WHERE producto_id = p_product_id
          AND abs(cantidad::numeric * v_ratio) > 2147483647
      ) OR abs(COALESCE(v_old_min, 0)::numeric * v_ratio) > 2147483647 THEN
        RAISE EXCEPTION 'La precisión solicitada excede el rango del inventario';
      END IF;

      UPDATE public.inventario_almacen
      SET cantidad = (cantidad::numeric * v_ratio)::integer
      WHERE producto_id = p_product_id;

      UPDATE public.productos
      SET stock_minimo = (COALESCE(v_old_min, 0)::numeric * v_ratio)::integer
      WHERE id = p_product_id;
    ELSE
      IF v_old_scale % v_new_scale <> 0 THEN
        RAISE EXCEPTION 'Conversión de precisión no soportada';
      END IF;
      v_divisor := v_old_scale / v_new_scale;
      IF EXISTS (
        SELECT 1
        FROM public.inventario_almacen
        WHERE producto_id = p_product_id
          AND cantidad % v_divisor <> 0
      ) OR COALESCE(v_old_min, 0) % v_divisor <> 0 THEN
        RAISE EXCEPTION 'No se puede reducir la precisión sin perder stock existente';
      END IF;

      UPDATE public.inventario_almacen
      SET cantidad = cantidad / v_divisor
      WHERE producto_id = p_product_id;

      UPDATE public.productos
      SET stock_minimo = COALESCE(v_old_min, 0) / v_divisor
      WHERE id = p_product_id;
    END IF;
  END IF;

  IF v_exists THEN
    UPDATE public.product_unit_profiles
    SET profile = p_profile,
        revision = revision + 1,
        updated_at = now()
    WHERE product_id = p_product_id
    RETURNING * INTO v_saved;
  ELSE
    INSERT INTO public.product_unit_profiles(product_id, revision, profile)
    VALUES (p_product_id, 1, p_profile)
    RETURNING * INTO v_saved;
  END IF;

  RETURN jsonb_build_object(
    'revision', v_saved.revision,
    'profile', v_saved.profile,
    'storage_scale', v_new_scale
  );
END;
$function$;

-- Convert an internal stock quantity captured under an historical scale to the
-- scale currently configured for the product.  Exact conversion is mandatory.
CREATE OR REPLACE FUNCTION public._stock_quantity_at_current_scale(
  p_product_id bigint,
  p_stored_quantity integer,
  p_snapshot_scale integer
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_current_scale integer;
  v_converted numeric;
BEGIN
  IF p_product_id IS NULL OR p_product_id <= 0
     OR p_stored_quantity IS NULL OR p_stored_quantity < 0
     OR p_snapshot_scale IS NULL OR p_snapshot_scale <= 0 THEN
    RAISE EXCEPTION 'Cantidad histórica inválida';
  END IF;

  v_current_scale := public._product_storage_scale_for_id(p_product_id);
  v_converted := p_stored_quantity::numeric * v_current_scale / p_snapshot_scale;

  IF v_converted <> trunc(v_converted)
     OR abs(v_converted) > 2147483647 THEN
    RAISE EXCEPTION 'La cantidad histórica no puede convertirse sin pérdida';
  END IF;
  RETURN v_converted::integer;
END;
$function$;

-- Lazily rebase only the internal stock fields of a sale.  Commercial fields
-- (cantidad, subtotal, precio comercial and presentation snapshots) stay intact.
CREATE OR REPLACE FUNCTION public._rebase_sale_stock_to_current_scale_v1(
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
  v_rebased integer;
BEGIN
  IF p_venta_id IS NULL OR p_venta_id <= 0 THEN
    RAISE EXCEPTION 'Venta inválida';
  END IF;

  FOR v_row IN
    SELECT id, producto_id, piezas_reales,
           GREATEST(COALESCE(stock_scale_snapshot, 1), 1) AS snapshot_scale,
           precio_unitario
    FROM public.detalle_ventas
    WHERE venta_id = p_venta_id
    FOR UPDATE
  LOOP
    v_current_scale := public._product_storage_scale_for_id(v_row.producto_id);
    IF v_current_scale = v_row.snapshot_scale THEN
      CONTINUE;
    END IF;

    PERFORM pg_advisory_xact_lock(v_row.producto_id);
    v_rebased := public._stock_quantity_at_current_scale(
      v_row.producto_id,
      COALESCE(v_row.piezas_reales, 0),
      v_row.snapshot_scale
    );

    UPDATE public.detalle_ventas
    SET piezas_reales = v_rebased,
        precio_unitario = CASE
          WHEN v_row.precio_unitario IS NULL THEN NULL
          ELSE v_row.precio_unitario * v_row.snapshot_scale::numeric
               / v_current_scale::numeric
        END,
        stock_scale_snapshot = v_current_scale
    WHERE id = v_row.id;
  END LOOP;
END;
$function$;

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
  -- anular_venta_v2 performs authorization, fiscal-state validation,
  -- idempotency, kardex and deletion.  We only normalize its internal stock
  -- quantities first, in the same transaction.
  PERFORM public._rebase_sale_stock_to_current_scale_v1(p_venta_id);
  RETURN public.anular_venta_v2(p_venta_id, p_motivo);
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
  SELECT venta_id INTO v_venta_id
  FROM public.comprobantes_electronicos
  WHERE id = p_comprobante_id
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Comprobante inexistente';
  END IF;

  IF COALESCE(p_reponer_stock, true) THEN
    PERFORM public._rebase_sale_stock_to_current_scale_v1(v_venta_id);
  END IF;

  RETURN public.crear_nota_credito_v1(
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

REVOKE ALL ON FUNCTION public.save_product_unit_profile_v5(bigint,bigint,jsonb)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._stock_quantity_at_current_scale(bigint,integer,integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._rebase_sale_stock_to_current_scale_v1(bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.anular_venta_with_units_v3(bigint,text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.crear_nota_credito_with_units_v2(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.save_product_unit_profile_v5(bigint,bigint,jsonb)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.anular_venta_with_units_v3(bigint,text)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.crear_nota_credito_with_units_v2(uuid,uuid,text,text,jsonb,numeric,boolean,timestamptz)
  TO authenticated;

COMMIT;
