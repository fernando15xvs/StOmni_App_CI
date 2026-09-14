-- Permite operar productos seriados sin una UI de escaneo obligatoria.
-- Si el cliente envía series explícitas se respetan; si no, el servidor toma
-- determinísticamente las más antiguas disponibles en el almacén.
BEGIN;

CREATE OR REPLACE FUNCTION public._resolve_serial_numbers_v1(
  p_product_id bigint,
  p_warehouse_id bigint,
  p_quantity integer,
  p_requested jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_result jsonb:='[]'::jsonb;
  v_serial text;
  v_count integer:=0;
BEGIN
  IF p_product_id IS NULL OR p_product_id<=0 OR p_warehouse_id IS NULL
     OR p_warehouse_id<=0 OR p_quantity IS NULL OR p_quantity<=0 THEN
    RAISE EXCEPTION 'Solicitud de series inválida' USING ERRCODE='22023';
  END IF;

  IF p_requested IS NOT NULL AND jsonb_typeof(p_requested)='array'
     AND jsonb_array_length(p_requested)>0 THEN
    IF jsonb_array_length(p_requested)<>p_quantity THEN
      RAISE EXCEPTION 'Selecciona una serie por cada unidad' USING ERRCODE='23514';
    END IF;
    FOR v_serial IN
      SELECT trim(value #>> '{}') FROM jsonb_array_elements(p_requested)
    LOOP
      IF v_serial='' OR EXISTS(
        SELECT 1 FROM jsonb_array_elements_text(v_result) e
        WHERE lower(e.value)=lower(v_serial)
      ) THEN
        RAISE EXCEPTION 'Serie inválida o repetida' USING ERRCODE='22023';
      END IF;
      PERFORM 1 FROM public.inventory_serials
      WHERE product_id=p_product_id AND warehouse_id=p_warehouse_id
        AND serial_number=v_serial AND status='in_stock'
      FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'La serie % no está disponible',v_serial USING ERRCODE='23514';
      END IF;
      v_result:=v_result||to_jsonb(v_serial);
      v_count:=v_count+1;
    END LOOP;
  ELSE
    FOR v_serial IN
      SELECT s.serial_number
      FROM public.inventory_serials s
      WHERE s.product_id=p_product_id AND s.warehouse_id=p_warehouse_id
        AND s.status='in_stock'
      ORDER BY s.created_at,s.id
      LIMIT p_quantity
      FOR UPDATE
    LOOP
      v_result:=v_result||to_jsonb(v_serial);
      v_count:=v_count+1;
    END LOOP;
    IF v_count<>p_quantity THEN
      RAISE EXCEPTION 'Stock seriado insuficiente en el almacén' USING ERRCODE='23514';
    END IF;
  END IF;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public._consume_inventory_traceability_v1(
  p_request_id uuid,
  p_product_id bigint,
  p_warehouse_id bigint,
  p_base_quantity numeric,
  p_serial_numbers jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_config public.product_traceability_configs%ROWTYPE;
  v_existing public.inventory_traceability_consumptions%ROWTYPE;
  v_remaining numeric;
  v_take numeric;
  v_lot public.inventory_lots%ROWTYPE;
  v_allocations jsonb:='[]'::jsonb;
  v_serial text;
  v_resolved jsonb;
BEGIN
  IF p_request_id IS NULL OR p_product_id IS NULL OR p_product_id<=0
     OR p_warehouse_id IS NULL OR p_warehouse_id<=0
     OR p_base_quantity IS NULL OR p_base_quantity<=0 THEN
    RAISE EXCEPTION 'Consumo trazable inválido' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_existing
  FROM public.inventory_traceability_consumptions
  WHERE request_id=p_request_id AND product_id=p_product_id AND warehouse_id=p_warehouse_id;
  IF FOUND THEN
    IF v_existing.base_quantity<>p_base_quantity THEN
      RAISE EXCEPTION 'El request_id ya consumió otra cantidad trazable' USING ERRCODE='23505';
    END IF;
    RETURN v_existing.allocations;
  END IF;

  SELECT * INTO v_config FROM public.product_traceability_configs
  WHERE product_id=p_product_id FOR SHARE;
  IF NOT FOUND OR v_config.mode='none' THEN RETURN '[]'::jsonb; END IF;

  IF v_config.mode='lot' THEN
    v_remaining:=p_base_quantity;
    FOR v_lot IN
      SELECT * FROM public.inventory_lots
      WHERE product_id=p_product_id AND warehouse_id=p_warehouse_id AND base_quantity>0
      ORDER BY expiry_date NULLS LAST,created_at,id
      FOR UPDATE
    LOOP
      EXIT WHEN v_remaining<=0;
      v_take:=least(v_lot.base_quantity,v_remaining);
      UPDATE public.inventory_lots
      SET base_quantity=base_quantity-v_take,updated_at=now()
      WHERE id=v_lot.id;
      v_allocations:=v_allocations||jsonb_build_array(jsonb_build_object(
        'lot_id',v_lot.id,'lot_code',v_lot.lot_code,
        'expiry_date',v_lot.expiry_date,'base_quantity',v_take
      ));
      v_remaining:=v_remaining-v_take;
    END LOOP;
    IF v_remaining>0.000001 THEN
      RAISE EXCEPTION 'Stock por lote insuficiente para completar la salida' USING ERRCODE='23514';
    END IF;
  ELSE
    IF p_base_quantity<>trunc(p_base_quantity) THEN
      RAISE EXCEPTION 'La trazabilidad por serie requiere cantidad entera' USING ERRCODE='23514';
    END IF;
    v_resolved:=public._resolve_serial_numbers_v1(
      p_product_id,p_warehouse_id,p_base_quantity::integer,p_serial_numbers
    );
    FOR v_serial IN SELECT value FROM jsonb_array_elements_text(v_resolved) LOOP
      UPDATE public.inventory_serials
      SET status='sold',updated_at=now()
      WHERE product_id=p_product_id AND warehouse_id=p_warehouse_id
        AND serial_number=v_serial AND status='in_stock';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'La serie % dejó de estar disponible',v_serial USING ERRCODE='40001';
      END IF;
      v_allocations:=v_allocations||jsonb_build_array(jsonb_build_object('serial_number',v_serial));
    END LOOP;
  END IF;

  INSERT INTO public.inventory_traceability_consumptions(
    request_id,product_id,warehouse_id,mode,base_quantity,allocations
  ) VALUES(p_request_id,p_product_id,p_warehouse_id,v_config.mode,p_base_quantity,v_allocations);
  RETURN v_allocations;
END;
$function$;

-- Reenvuelve movimientos para resolver series antes de ejecutar la versión v3.
CREATE OR REPLACE FUNCTION public.trasladar_stock_scaled_v4(
  p_request_id uuid,p_producto_id bigint,p_origen_id bigint,p_destino_id bigint,
  p_cantidad_base numeric,p_motivo text DEFAULT NULL,p_fecha timestamptz DEFAULT now(),
  p_serial_numbers jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public
AS $function$
DECLARE v_serials jsonb:=p_serial_numbers; v_mode text;
BEGIN
  v_mode:=public._active_traceability_mode_v1(p_producto_id);
  IF v_mode='serial' THEN
    IF p_cantidad_base<>trunc(p_cantidad_base) THEN
      RAISE EXCEPTION 'El traslado seriado requiere cantidad entera' USING ERRCODE='23514';
    END IF;
    v_serials:=public._resolve_serial_numbers_v1(
      p_producto_id,p_origen_id,p_cantidad_base::integer,p_serial_numbers
    );
  END IF;
  RETURN public.trasladar_stock_scaled_v3(
    p_request_id,p_producto_id,p_origen_id,p_destino_id,p_cantidad_base,
    p_motivo,p_fecha,v_serials
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_merma_scaled_v4(
  p_request_id uuid,p_producto_id bigint,p_almacen_id bigint,p_cantidad_base numeric,
  p_motivo text,p_fecha timestamptz DEFAULT now(),p_serial_numbers jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public
AS $function$
DECLARE v_serials jsonb:=p_serial_numbers; v_mode text;
BEGIN
  v_mode:=public._active_traceability_mode_v1(p_producto_id);
  IF v_mode='serial' THEN
    IF p_cantidad_base<>trunc(p_cantidad_base) THEN
      RAISE EXCEPTION 'La merma seriada requiere cantidad entera' USING ERRCODE='23514';
    END IF;
    v_serials:=public._resolve_serial_numbers_v1(
      p_producto_id,p_almacen_id,p_cantidad_base::integer,p_serial_numbers
    );
  END IF;
  RETURN public.registrar_merma_scaled_v3(
    p_request_id,p_producto_id,p_almacen_id,p_cantidad_base,p_motivo,p_fecha,v_serials
  );
END;
$function$;

REVOKE ALL ON FUNCTION public._resolve_serial_numbers_v1(bigint,bigint,integer,jsonb)
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.trasladar_stock_scaled_v4(uuid,bigint,bigint,bigint,numeric,text,timestamptz,jsonb)
  FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.registrar_merma_scaled_v4(uuid,bigint,bigint,numeric,text,timestamptz,jsonb)
  FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.trasladar_stock_scaled_v4(uuid,bigint,bigint,bigint,numeric,text,timestamptz,jsonb)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_merma_scaled_v4(uuid,bigint,bigint,numeric,text,timestamptz,jsonb)
  TO authenticated;

COMMIT;
