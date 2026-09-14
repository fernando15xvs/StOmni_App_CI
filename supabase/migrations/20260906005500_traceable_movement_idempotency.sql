BEGIN;

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
  v_existing public.inventory_traceability_consumptions%ROWTYPE;
  v_allocations jsonb:='[]'::jsonb;
  v_row jsonb;
  v_serial text;
  v_result jsonb;
BEGIN
  IF NOT public.app_tiene_permiso('inventory.adjust') THEN
    RAISE EXCEPTION 'No autorizado para trasladar stock' USING ERRCODE='42501';
  END IF;
  IF p_request_id IS NULL OR p_origen_id=p_destino_id THEN
    RAISE EXCEPTION 'Traslado inválido' USING ERRCODE='22023';
  END IF;

  v_mode:=public._active_traceability_mode_v1(p_producto_id);
  IF v_mode<>'none' THEN
    SELECT * INTO v_existing
    FROM public.inventory_traceability_consumptions
    WHERE request_id=p_request_id
      AND product_id=p_producto_id
      AND warehouse_id=p_origen_id;

    IF FOUND THEN
      IF v_existing.mode<>v_mode OR
         abs(v_existing.base_quantity-p_cantidad_base)>0.000001 THEN
        RAISE EXCEPTION 'El request_id pertenece a otro movimiento trazable'
          USING ERRCODE='23505';
      END IF;
      -- El inventario general también es idempotente por request_id. No se
      -- vuelven a tocar lotes/series de destino en un retry confirmado.
      RETURN public.trasladar_stock_scaled_v1(
        p_request_id,p_producto_id,p_origen_id,p_destino_id,
        p_cantidad_base,p_motivo,p_fecha
      );
    END IF;
  END IF;

  IF v_mode='lot' THEN
    v_allocations:=public._consume_inventory_traceability_v1(
      p_request_id,p_producto_id,p_origen_id,p_cantidad_base,NULL
    );
    FOR v_row IN SELECT value FROM jsonb_array_elements(v_allocations) LOOP
      IF EXISTS(
        SELECT 1 FROM public.inventory_lots
        WHERE product_id=p_producto_id
          AND warehouse_id=p_destino_id
          AND lot_code=v_row->>'lot_code'
          AND expiry_date IS DISTINCT FROM NULLIF(v_row->>'expiry_date','')::date
      ) THEN
        RAISE EXCEPTION 'El lote % existe en destino con otro vencimiento',
          v_row->>'lot_code' USING ERRCODE='23514';
      END IF;
      INSERT INTO public.inventory_lots(
        product_id,warehouse_id,lot_code,expiry_date,base_quantity
      ) VALUES(
        p_producto_id,p_destino_id,v_row->>'lot_code',
        NULLIF(v_row->>'expiry_date','')::date,
        (v_row->>'base_quantity')::numeric
      )
      ON CONFLICT(product_id,warehouse_id,lot_code) DO UPDATE SET
        base_quantity=public.inventory_lots.base_quantity+EXCLUDED.base_quantity,
        updated_at=now();
    END LOOP;
  ELSIF v_mode='serial' THEN
    IF p_cantidad_base<>trunc(p_cantidad_base)
       OR p_serial_numbers IS NULL OR jsonb_typeof(p_serial_numbers)<>'array'
       OR jsonb_array_length(p_serial_numbers)<>p_cantidad_base::integer THEN
      RAISE EXCEPTION 'Selecciona una serie por cada unidad trasladada'
        USING ERRCODE='23514';
    END IF;
    FOR v_serial IN
      SELECT trim(value #>> '{}') FROM jsonb_array_elements(p_serial_numbers)
    LOOP
      UPDATE public.inventory_serials
      SET warehouse_id=p_destino_id,status='in_stock',updated_at=now()
      WHERE product_id=p_producto_id
        AND warehouse_id=p_origen_id
        AND serial_number=v_serial
        AND status='in_stock';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'La serie % no está disponible en el almacén origen',v_serial
          USING ERRCODE='23514';
      END IF;
      v_allocations:=v_allocations||jsonb_build_array(
        jsonb_build_object('serial_number',v_serial)
      );
    END LOOP;
    INSERT INTO public.inventory_traceability_consumptions(
      request_id,product_id,warehouse_id,mode,base_quantity,allocations
    ) VALUES(
      p_request_id,p_producto_id,p_origen_id,'serial',p_cantidad_base,v_allocations
    );
  END IF;

  v_result:=public.trasladar_stock_scaled_v1(
    p_request_id,p_producto_id,p_origen_id,p_destino_id,
    p_cantidad_base,p_motivo,p_fecha
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
  v_existing public.inventory_traceability_consumptions%ROWTYPE;
  v_serial text;
  v_allocations jsonb:='[]'::jsonb;
BEGIN
  IF NOT public.app_tiene_permiso('inventory.adjust') THEN
    RAISE EXCEPTION 'No autorizado para registrar mermas' USING ERRCODE='42501';
  END IF;
  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'request_id obligatorio' USING ERRCODE='22023';
  END IF;

  v_mode:=public._active_traceability_mode_v1(p_producto_id);
  IF v_mode<>'none' THEN
    SELECT * INTO v_existing
    FROM public.inventory_traceability_consumptions
    WHERE request_id=p_request_id
      AND product_id=p_producto_id
      AND warehouse_id=p_almacen_id;
    IF FOUND THEN
      IF v_existing.mode<>v_mode OR
         abs(v_existing.base_quantity-p_cantidad_base)>0.000001 THEN
        RAISE EXCEPTION 'El request_id pertenece a otro movimiento trazable'
          USING ERRCODE='23505';
      END IF;
      RETURN public.registrar_merma_scaled_v1(
        p_request_id,p_producto_id,p_almacen_id,
        p_cantidad_base,p_motivo,p_fecha
      );
    END IF;
  END IF;

  IF v_mode='lot' THEN
    PERFORM public._consume_inventory_traceability_v1(
      p_request_id,p_producto_id,p_almacen_id,p_cantidad_base,NULL
    );
  ELSIF v_mode='serial' THEN
    IF p_cantidad_base<>trunc(p_cantidad_base)
       OR p_serial_numbers IS NULL OR jsonb_typeof(p_serial_numbers)<>'array'
       OR jsonb_array_length(p_serial_numbers)<>p_cantidad_base::integer THEN
      RAISE EXCEPTION 'Selecciona una serie por cada unidad dada de baja'
        USING ERRCODE='23514';
    END IF;
    FOR v_serial IN
      SELECT trim(value #>> '{}') FROM jsonb_array_elements(p_serial_numbers)
    LOOP
      UPDATE public.inventory_serials
      SET status='written_off',updated_at=now()
      WHERE product_id=p_producto_id
        AND warehouse_id=p_almacen_id
        AND serial_number=v_serial
        AND status='in_stock';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'La serie % no está disponible',v_serial
          USING ERRCODE='23514';
      END IF;
      v_allocations:=v_allocations||jsonb_build_array(
        jsonb_build_object('serial_number',v_serial)
      );
    END LOOP;
    INSERT INTO public.inventory_traceability_consumptions(
      request_id,product_id,warehouse_id,mode,base_quantity,allocations
    ) VALUES(
      p_request_id,p_producto_id,p_almacen_id,'serial',p_cantidad_base,v_allocations
    );
  END IF;

  RETURN public.registrar_merma_scaled_v1(
    p_request_id,p_producto_id,p_almacen_id,
    p_cantidad_base,p_motivo,p_fecha
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.trasladar_stock_scaled_v3(
  uuid,bigint,bigint,bigint,numeric,text,timestamptz,jsonb
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.registrar_merma_scaled_v3(
  uuid,bigint,bigint,numeric,text,timestamptz,jsonb
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.trasladar_stock_scaled_v3(
  uuid,bigint,bigint,bigint,numeric,text,timestamptz,jsonb
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_merma_scaled_v3(
  uuid,bigint,bigint,numeric,text,timestamptz,jsonb
) TO authenticated;

COMMIT;