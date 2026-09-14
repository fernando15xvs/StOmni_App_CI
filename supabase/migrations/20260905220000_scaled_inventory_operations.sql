BEGIN;

CREATE OR REPLACE FUNCTION public._product_storage_scale_for_id(p_product_id bigint)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_profile jsonb;
BEGIN
  SELECT profile INTO v_profile
  FROM public.product_unit_profiles
  WHERE product_id=p_product_id;
  IF NOT FOUND THEN RETURN 1; END IF;
  RETURN public._product_unit_storage_scale(v_profile);
END;
$function$;

CREATE OR REPLACE FUNCTION public._visible_base_to_stored(
  p_product_id bigint,
  p_quantity numeric
)
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_scale integer;
  v_stored numeric;
BEGIN
  IF p_quantity IS NULL OR p_quantity::text IN ('NaN','Infinity','-Infinity')
     OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'La cantidad debe ser positiva';
  END IF;
  v_scale:=public._product_storage_scale_for_id(p_product_id);
  v_stored:=p_quantity*v_scale;
  IF v_stored<>trunc(v_stored) OR v_stored>2147483647 THEN
    RAISE EXCEPTION 'La cantidad excede la precisión o rango del producto';
  END IF;
  RETURN v_stored::integer;
END;
$function$;

-- Final profile writer used by clients. Adds minimum-stock conversion around v3.
CREATE OR REPLACE FUNCTION public.save_product_unit_profile_v4(
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
  v_old_scale integer:=1;
  v_new_scale integer;
  v_old_min integer;
  v_result jsonb;
  v_divisor integer;
BEGIN
  SELECT stock_minimo INTO v_old_min
  FROM public.productos WHERE id=p_product_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Producto inexistente'; END IF;
  SELECT public._product_unit_storage_scale(profile)
    INTO v_old_scale FROM public.product_unit_profiles WHERE product_id=p_product_id;
  IF NOT FOUND THEN v_old_scale:=1; END IF;
  v_new_scale:=public._product_unit_storage_scale(p_profile);
  IF v_new_scale<v_old_scale THEN
    v_divisor:=v_old_scale/v_new_scale;
    IF v_old_scale%v_new_scale<>0 OR COALESCE(v_old_min,0)%v_divisor<>0 THEN
      RAISE EXCEPTION 'El stock mínimo impide reducir la precisión sin pérdida';
    END IF;
  ELSIF v_new_scale>v_old_scale
        AND abs(COALESCE(v_old_min,0)::numeric*v_new_scale/v_old_scale)>2147483647 THEN
    RAISE EXCEPTION 'El stock mínimo excedería el rango al cambiar precisión';
  END IF;

  v_result:=public.save_product_unit_profile_v3(
    p_product_id,p_expected_revision,p_profile
  );

  IF v_new_scale>v_old_scale THEN
    UPDATE public.productos
      SET stock_minimo=(COALESCE(v_old_min,0)::numeric*v_new_scale/v_old_scale)::integer
      WHERE id=p_product_id;
  ELSIF v_new_scale<v_old_scale THEN
    UPDATE public.productos
      SET stock_minimo=COALESCE(v_old_min,0)/(v_old_scale/v_new_scale)
      WHERE id=p_product_id;
  END IF;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_merma_scaled_v1(
  p_request_id uuid,
  p_producto_id bigint,
  p_almacen_id bigint,
  p_cantidad_base numeric,
  p_motivo text,
  p_fecha timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_scale integer;
  v_stored integer;
  v_result jsonb;
BEGIN
  v_scale:=public._product_storage_scale_for_id(p_producto_id);
  v_stored:=public._visible_base_to_stored(p_producto_id,p_cantidad_base);
  v_result:=public.registrar_merma_v2(
    p_request_id,p_producto_id,p_almacen_id,v_stored,p_motivo,p_fecha
  );
  UPDATE public.inventario_movimientos
    SET stock_scale_snapshot=v_scale
    WHERE request_id=p_request_id AND producto_id=p_producto_id;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.trasladar_stock_scaled_v1(
  p_request_id uuid,
  p_producto_id bigint,
  p_origen_id bigint,
  p_destino_id bigint,
  p_cantidad_base numeric,
  p_motivo text DEFAULT NULL,
  p_fecha timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_scale integer;
  v_stored integer;
  v_result jsonb;
BEGIN
  v_scale:=public._product_storage_scale_for_id(p_producto_id);
  v_stored:=public._visible_base_to_stored(p_producto_id,p_cantidad_base);
  v_result:=public.trasladar_stock_v2(
    p_request_id,p_producto_id,p_origen_id,p_destino_id,v_stored,p_motivo,p_fecha
  );
  UPDATE public.inventario_movimientos
    SET stock_scale_snapshot=v_scale
    WHERE request_id=p_request_id AND producto_id=p_producto_id;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_ingreso_mercaderia_scaled_v1(
  p_request_id uuid,
  p_producto_id bigint,
  p_fecha timestamptz,
  p_tipo_ingreso text,
  p_documento text,
  p_proveedor_id bigint,
  p_observaciones text,
  p_almacenes jsonb,
  p_ingreso_costo numeric,
  p_ingreso_p_unit numeric,
  p_ingreso_p_caja numeric,
  p_ingreso_p_c_comp numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_scale integer;
  v_row jsonb;
  v_normalized jsonb:='[]'::jsonb;
  v_result jsonb;
  v_quantity numeric;
BEGIN
  IF p_almacenes IS NULL OR jsonb_typeof(p_almacenes)<>'array' THEN
    RAISE EXCEPTION 'Distribución de almacenes inválida';
  END IF;
  v_scale:=public._product_storage_scale_for_id(p_producto_id);
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_almacenes) LOOP
    v_quantity:=NULLIF(v_row->>'cantidad_base','')::numeric;
    v_normalized:=v_normalized||jsonb_build_array(
      v_row||jsonb_build_object(
        'cantidad_base',public._visible_base_to_stored(p_producto_id,v_quantity)
      )
    );
  END LOOP;
  v_result:=public.registrar_ingreso_mercaderia_v2(
    p_request_id,p_producto_id,p_fecha,p_tipo_ingreso,p_documento,
    p_proveedor_id,p_observaciones,v_normalized,p_ingreso_costo,
    CASE WHEN v_scale>1 THEN p_ingreso_p_unit/v_scale ELSE p_ingreso_p_unit END,
    p_ingreso_p_caja,p_ingreso_p_c_comp
  );
  UPDATE public.inventario_movimientos
    SET stock_scale_snapshot=v_scale
    WHERE request_id=p_request_id AND producto_id=p_producto_id;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.ajustar_stock_scaled_v1(
  p_producto_id bigint,
  p_almacen_id bigint,
  p_delta_base numeric,
  p_tipo_movimiento text,
  p_motivo text,
  p_ingreso_costo numeric DEFAULT 0,
  p_ingreso_p_unit numeric DEFAULT 0,
  p_ingreso_p_caja numeric DEFAULT 0,
  p_ingreso_p_c_comp numeric DEFAULT 0,
  p_salida_cliente text DEFAULT NULL,
  p_salida_p_unit numeric DEFAULT 0,
  p_salida_total numeric DEFAULT 0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_scale integer;
  v_abs integer;
  v_stored integer;
BEGIN
  IF p_delta_base IS NULL OR p_delta_base=0 THEN RAISE EXCEPTION 'Delta inválido'; END IF;
  v_scale:=public._product_storage_scale_for_id(p_producto_id);
  v_abs:=public._visible_base_to_stored(p_producto_id,abs(p_delta_base));
  v_stored:=CASE WHEN p_delta_base<0 THEN -v_abs ELSE v_abs END;
  PERFORM public.ajustar_stock_y_kardex(
    p_producto_id,p_almacen_id,v_stored,p_tipo_movimiento,p_motivo,
    p_ingreso_costo,
    CASE WHEN v_scale>1 THEN p_ingreso_p_unit/v_scale ELSE p_ingreso_p_unit END,
    p_ingreso_p_caja,p_ingreso_p_c_comp,p_salida_cliente,
    CASE WHEN v_scale>1 THEN p_salida_p_unit/v_scale ELSE p_salida_p_unit END,
    p_salida_total,'AUTO'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public._product_storage_scale_for_id(bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._visible_base_to_stored(bigint,numeric) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.save_product_unit_profile_v4(bigint,bigint,jsonb) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.registrar_merma_scaled_v1(uuid,bigint,bigint,numeric,text,timestamptz) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.trasladar_stock_scaled_v1(uuid,bigint,bigint,bigint,numeric,text,timestamptz) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.registrar_ingreso_mercaderia_scaled_v1(uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.ajustar_stock_scaled_v1(bigint,bigint,numeric,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.save_product_unit_profile_v4(bigint,bigint,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_merma_scaled_v1(uuid,bigint,bigint,numeric,text,timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.trasladar_stock_scaled_v1(uuid,bigint,bigint,bigint,numeric,text,timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_ingreso_mercaderia_scaled_v1(uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ajustar_stock_scaled_v1(bigint,bigint,numeric,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric) TO authenticated;

COMMIT;
