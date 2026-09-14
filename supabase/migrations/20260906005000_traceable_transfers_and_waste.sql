BEGIN;

CREATE OR REPLACE FUNCTION public._active_traceability_mode_v1(p_product_id bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_mode text;
  v_profile jsonb;
BEGIN
  SELECT mode INTO v_mode FROM public.product_traceability_configs
  WHERE product_id=p_product_id;
  IF NOT FOUND OR v_mode='none' THEN RETURN 'none'; END IF;
  v_profile:=public.get_business_profile_v1();
  IF v_mode='lot' AND coalesce((v_profile->'capabilities'->>'lot_tracking')::boolean,false) THEN
    RETURN 'lot';
  END IF;
  IF v_mode='serial' AND coalesce((v_profile->'capabilities'->>'serial_number_tracking')::boolean,false) THEN
    RETURN 'serial';
  END IF;
  RETURN 'none';
END;
$function$;

CREATE OR REPLACE FUNCTION public.trasladar_stock_scaled_v3(
  p_request_id uuid,
  p_producto_id bigint,
  p_origen_id bigint,
  p_destino_id bigint,
  p_cantidad_base numeric,
  p_motivo text DEFAULT NULL,
  p_fecha timestamptz DEFAULT now(),
  p_serial_numbers jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_mode text;
  v_allocations jsonb:='[]'::jsonb;
  v_row jsonb;
  v_serial text;
  v_count integer:=0;
  v_result jsonb;
BEGIN
  IF NOT public.app_tiene_permiso('inventory.adjust') THEN
    RAISE EXCEPTION 'No autorizado para trasladar stock' USING ERRCODE='42501';
  END IF;
  IF p_origen_id=p_destino_id THEN
    RAISE EXCEPTION 'Los almacenes deben ser diferentes' USING ERRCODE='22023';
  END IF;
  v_mode:=public._active_traceability_mode_v1(p_producto_id);

  IF v_mode='lot' THEN
    v_allocations:=public._consume_inventory_traceability_v1(
      p_request_id,p_producto_id,p_origen_id,p_cantidad_base,NULL
    );
    FOR v_row IN SELECT value FROM jsonb_array_elements(v_allocations) LOOP
      INSERT INTO public.inventory_lots(
        product_id,warehouse_id,lot_code,expiry_date,base_quantity
      ) VALUES(
        p_producto_id,p_destino_id,v_row->>'lot_code',
        NULLIF(v_row->>'expiry_date','')::date,(v_row->>'base_quantity')::numeric
      )
      ON CONFLICT(product_id,warehouse_id,lot_code) DO UPDATE SET
        base_quantity=public.inventory_lots.base_quantity+EXCLUDED.base_quantity,
        updated_at=now();
    END LOOP;
  ELSIF v_mode='serial' THEN
    IF p_cantidad_base<>trunc(p_cantidad_base)
       OR p_serial_numbers IS NULL OR jsonb_typeof(p_serial_numbers)<>'array'
       OR jsonb_array_length(p_serial_numbers)<>p_cantidad_base::integer THEN
      RAISE EXCEPTION 'Selecciona una serie por cada unidad trasladada' USING ERRCODE='23514';
    END IF;
    FOR v_serial IN SELECT trim(value #>> '{}') FROM jsonb_array_elements(p_serial_numbers) LOOP
      UPDATE public.inventory_serials
        SET warehouse_id=p_destino_id,status='in_stock',updated_at=now()
      WHERE product_id=p_producto_id AND warehouse_id=p_origen_id
        AND serial_number=v_serial AND status='in_stock';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'La serie % no está disponible en el almacén origen',v_serial USING ERRCODE='23514';
      END IF;
      v_count:=v_count+1;
      v_allocations:=v_allocations||jsonb_build_array(jsonb_build_object('serial_number',v_serial));
    END LOOP;
    INSERT INTO public.inventory_traceability_consumptions(
      request_id,product_id,warehouse_id,mode,base_quantity,allocations
    ) VALUES(p_request_id,p_producto_id,p_origen_id,'serial',p_cantidad_base,v_allocations)
    ON CONFLICT(request_id,product_id,warehouse_id) DO NOTHING;
  END IF;

  v_result:=public.trasladar_stock_scaled_v1(
    p_request_id,p_producto_id,p_origen_id,p_destino_id,p_cantidad_base,p_motivo,p_fecha
  );
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_merma_scaled_v3(
  p_request_id uuid,
  p_producto_id bigint,
  p_almacen_id bigint,
  p_cantidad_base numeric,
  p_motivo text,
  p_fecha timestamptz DEFAULT now(),
  p_serial_numbers jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_mode text;
  v_serial text;
  v_allocations jsonb:='[]'::jsonb;
  v_result jsonb;
BEGIN
  IF NOT public.app_tiene_permiso('inventory.adjust') THEN
    RAISE EXCEPTION 'No autorizado para registrar mermas' USING ERRCODE='42501';
  END IF;
  v_mode:=public._active_traceability_mode_v1(p_producto_id);
  IF v_mode='lot' THEN
    v_allocations:=public._consume_inventory_traceability_v1(
      p_request_id,p_producto_id,p_almacen_id,p_cantidad_base,NULL
    );
  ELSIF v_mode='serial' THEN
    IF p_cantidad_base<>trunc(p_cantidad_base)
       OR p_serial_numbers IS NULL OR jsonb_typeof(p_serial_numbers)<>'array'
       OR jsonb_array_length(p_serial_numbers)<>p_cantidad_base::integer THEN
      RAISE EXCEPTION 'Selecciona una serie por cada unidad dada de baja' USING ERRCODE='23514';
    END IF;
    FOR v_serial IN SELECT trim(value #>> '{}') FROM jsonb_array_elements(p_serial_numbers) LOOP
      UPDATE public.inventory_serials
        SET status='written_off',updated_at=now()
      WHERE product_id=p_producto_id AND warehouse_id=p_almacen_id
        AND serial_number=v_serial AND status='in_stock';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'La serie % no está disponible',v_serial USING ERRCODE='23514';
      END IF;
      v_allocations:=v_allocations||jsonb_build_array(jsonb_build_object('serial_number',v_serial));
    END LOOP;
    INSERT INTO public.inventory_traceability_consumptions(
      request_id,product_id,warehouse_id,mode,base_quantity,allocations
    ) VALUES(p_request_id,p_producto_id,p_almacen_id,'serial',p_cantidad_base,v_allocations)
    ON CONFLICT(request_id,product_id,warehouse_id) DO NOTHING;
  END IF;
  v_result:=public.registrar_merma_scaled_v1(
    p_request_id,p_producto_id,p_almacen_id,p_cantidad_base,p_motivo,p_fecha
  );
  RETURN v_result;
END;
$function$;

-- Legacy mutation entry points become fail-closed only when traceability is
-- actually active for that product. Before cutover they preserve old behavior.
CREATE OR REPLACE FUNCTION public.trasladar_stock_scaled_v2(
  p_request_id uuid,p_producto_id bigint,p_origen_id bigint,p_destino_id bigint,
  p_cantidad_base numeric,p_motivo text DEFAULT NULL,p_fecha timestamptz DEFAULT now()
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public
AS $function$
BEGIN
  IF NOT public.app_tiene_permiso('inventory.adjust') THEN
    RAISE EXCEPTION 'No autorizado para trasladar stock' USING ERRCODE='42501';
  END IF;
  IF public._active_traceability_mode_v1(p_producto_id)<>'none' THEN
    RAISE EXCEPTION 'Este producto requiere el flujo de traslado trazable' USING ERRCODE='23514';
  END IF;
  RETURN public.trasladar_stock_scaled_v1(
    p_request_id,p_producto_id,p_origen_id,p_destino_id,p_cantidad_base,p_motivo,p_fecha
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_merma_scaled_v2(
  p_request_id uuid,p_producto_id bigint,p_almacen_id bigint,p_cantidad_base numeric,
  p_motivo text,p_fecha timestamptz DEFAULT now()
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public
AS $function$
BEGIN
  IF NOT public.app_tiene_permiso('inventory.adjust') THEN
    RAISE EXCEPTION 'No autorizado para registrar mermas' USING ERRCODE='42501';
  END IF;
  IF public._active_traceability_mode_v1(p_producto_id)<>'none' THEN
    RAISE EXCEPTION 'Este producto requiere el flujo de merma trazable' USING ERRCODE='23514';
  END IF;
  RETURN public.registrar_merma_scaled_v1(
    p_request_id,p_producto_id,p_almacen_id,p_cantidad_base,p_motivo,p_fecha
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_ingreso_mercaderia_scaled_v2(
  p_request_id uuid,p_producto_id bigint,p_fecha timestamptz,p_tipo_ingreso text,
  p_documento text,p_proveedor_id bigint,p_observaciones text,p_almacenes jsonb,
  p_ingreso_costo numeric,p_ingreso_p_unit numeric,p_ingreso_p_caja numeric,
  p_ingreso_p_c_comp numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public
AS $function$
BEGIN
  IF NOT public.app_tiene_permiso('inventory.receive') THEN
    RAISE EXCEPTION 'No autorizado para registrar ingresos de inventario' USING ERRCODE='42501';
  END IF;
  IF public._active_traceability_mode_v1(p_producto_id)<>'none' THEN
    RAISE EXCEPTION 'Este producto requiere una recepción con trazabilidad' USING ERRCODE='23514';
  END IF;
  RETURN public.registrar_ingreso_mercaderia_scaled_v1(
    p_request_id,p_producto_id,p_fecha,p_tipo_ingreso,p_documento,p_proveedor_id,
    p_observaciones,p_almacenes,p_ingreso_costo,p_ingreso_p_unit,p_ingreso_p_caja,p_ingreso_p_c_comp
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.ajustar_stock_scaled_v2(
  p_producto_id bigint,p_almacen_id bigint,p_delta_base numeric,p_tipo_movimiento text,
  p_motivo text,p_ingreso_costo numeric DEFAULT 0,p_ingreso_p_unit numeric DEFAULT 0,
  p_ingreso_p_caja numeric DEFAULT 0,p_ingreso_p_c_comp numeric DEFAULT 0,
  p_salida_cliente text DEFAULT NULL,p_salida_p_unit numeric DEFAULT 0,
  p_salida_total numeric DEFAULT 0
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public
AS $function$
BEGIN
  IF NOT public.app_tiene_permiso('inventory.adjust') THEN
    RAISE EXCEPTION 'No autorizado para ajustar stock' USING ERRCODE='42501';
  END IF;
  IF public._active_traceability_mode_v1(p_producto_id)<>'none' THEN
    RAISE EXCEPTION 'El ajuste genérico no está permitido para productos trazables' USING ERRCODE='23514';
  END IF;
  PERFORM public.ajustar_stock_scaled_v1(
    p_producto_id,p_almacen_id,p_delta_base,p_tipo_movimiento,p_motivo,
    p_ingreso_costo,p_ingreso_p_unit,p_ingreso_p_caja,p_ingreso_p_c_comp,
    p_salida_cliente,p_salida_p_unit,p_salida_total
  );
END;
$function$;

REVOKE ALL ON FUNCTION public._active_traceability_mode_v1(bigint) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.trasladar_stock_scaled_v3(uuid,bigint,bigint,bigint,numeric,text,timestamptz,jsonb) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.registrar_merma_scaled_v3(uuid,bigint,bigint,numeric,text,timestamptz,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.trasladar_stock_scaled_v3(uuid,bigint,bigint,bigint,numeric,text,timestamptz,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_merma_scaled_v3(uuid,bigint,bigint,numeric,text,timestamptz,jsonb) TO authenticated;

COMMIT;