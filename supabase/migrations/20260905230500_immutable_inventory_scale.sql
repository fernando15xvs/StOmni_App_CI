BEGIN;

-- Final writer for configurable product units. Historical transactions are
-- immutable: storage precision may only change before the product has stock or
-- any operational history. This keeps cancellations, credit notes and kardex
-- valid without rewriting legal/audit records.
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
  v_old_min integer := 0;
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

  SELECT COALESCE(stock_minimo,0) INTO v_old_min
  FROM public.productos
  WHERE id=p_product_id AND COALESCE(activo,true)
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Producto inexistente o inactivo'; END IF;

  SELECT * INTO v_current
  FROM public.product_unit_profiles
  WHERE product_id=p_product_id
  FOR UPDATE;
  v_exists := FOUND;
  IF v_exists THEN
    IF v_current.revision <> p_expected_revision THEN
      RAISE EXCEPTION USING ERRCODE='40001',
        MESSAGE='La configuración cambió en otro equipo';
    END IF;
    IF v_current.profile->>'base_code' <> p_profile->>'base_code' THEN
      RAISE EXCEPTION 'La unidad base no puede cambiar después de configurar el producto';
    END IF;
    v_old_scale := public._product_unit_storage_scale(v_current.profile);
  ELSIF p_expected_revision <> 0 THEN
    RAISE EXCEPTION USING ERRCODE='40001', MESSAGE='La configuración ya no existe';
  END IF;

  IF v_new_scale <> v_old_scale THEN
    IF EXISTS (
      SELECT 1 FROM public.inventario_almacen
      WHERE producto_id=p_product_id AND COALESCE(cantidad,0)<>0
    ) OR EXISTS (
      SELECT 1 FROM public.detalle_ventas WHERE producto_id=p_product_id
    ) OR EXISTS (
      SELECT 1 FROM public.detalle_cotizaciones WHERE producto_id=p_product_id
    ) OR EXISTS (
      SELECT 1 FROM public.inventario_movimientos WHERE producto_id=p_product_id
    ) OR (
      to_regclass('public.notas_credito_detalles') IS NOT NULL
      AND EXISTS (
        SELECT 1 FROM public.notas_credito_detalles WHERE producto_id=p_product_id
      )
    ) THEN
      RAISE EXCEPTION
        'La precisión del inventario no puede cambiar después de la primera operación del producto';
    END IF;

    IF v_new_scale>v_old_scale THEN
      IF abs(v_old_min::numeric*v_new_scale/v_old_scale)>2147483647 THEN
        RAISE EXCEPTION 'El stock mínimo excedería el rango permitido';
      END IF;
      UPDATE public.productos
      SET stock_minimo=(v_old_min::numeric*v_new_scale/v_old_scale)::integer
      WHERE id=p_product_id;
    ELSE
      IF v_old_scale%v_new_scale<>0
         OR v_old_min%(v_old_scale/v_new_scale)<>0 THEN
        RAISE EXCEPTION 'El stock mínimo impide reducir la precisión sin pérdida';
      END IF;
      UPDATE public.productos
      SET stock_minimo=v_old_min/(v_old_scale/v_new_scale)
      WHERE id=p_product_id;
    END IF;
  END IF;

  IF v_exists THEN
    UPDATE public.product_unit_profiles
      SET profile=p_profile, revision=revision+1, updated_at=now()
      WHERE product_id=p_product_id
      RETURNING * INTO v_saved;
  ELSE
    INSERT INTO public.product_unit_profiles(product_id,revision,profile)
      VALUES(p_product_id,1,p_profile)
      RETURNING * INTO v_saved;
  END IF;

  RETURN jsonb_build_object(
    'revision',v_saved.revision,
    'profile',v_saved.profile,
    'storage_scale',v_new_scale
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.save_product_unit_profile_v5(bigint,bigint,jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_product_unit_profile_v5(bigint,bigint,jsonb)
  TO authenticated;

COMMIT;
