BEGIN;

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
  v_count integer:=0;
  v_profile jsonb;
  v_enabled boolean:=false;
BEGIN
  IF p_request_id IS NULL OR p_product_id IS NULL OR p_product_id<=0
     OR p_warehouse_id IS NULL OR p_warehouse_id<=0
     OR p_base_quantity IS NULL OR p_base_quantity<=0 THEN
    RAISE EXCEPTION 'Consumo trazable inválido' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_config FROM public.product_traceability_configs
    WHERE product_id=p_product_id FOR SHARE;
  IF NOT FOUND OR v_config.mode='none' THEN
    RETURN '[]'::jsonb;
  END IF;

  -- Preconfiguration must not change live behavior. Only an enabled business
  -- capability activates consumption for the corresponding product mode.
  v_profile:=public.get_business_profile_v1();
  v_enabled:=CASE v_config.mode
    WHEN 'lot' THEN coalesce((v_profile->'capabilities'->>'lot_tracking')::boolean,false)
    WHEN 'serial' THEN coalesce((v_profile->'capabilities'->>'serial_number_tracking')::boolean,false)
    ELSE false
  END;
  IF NOT v_enabled THEN
    RETURN '[]'::jsonb;
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
    IF p_base_quantity<>trunc(p_base_quantity)
       OR p_serial_numbers IS NULL OR jsonb_typeof(p_serial_numbers)<>'array'
       OR jsonb_array_length(p_serial_numbers)<>p_base_quantity::integer THEN
      RAISE EXCEPTION 'Selecciona una serie por cada unidad vendida' USING ERRCODE='23514';
    END IF;
    FOR v_serial IN SELECT trim(value #>> '{}') FROM jsonb_array_elements(p_serial_numbers) LOOP
      IF v_serial='' THEN RAISE EXCEPTION 'Serie inválida' USING ERRCODE='22023'; END IF;
      UPDATE public.inventory_serials
        SET status='sold',updated_at=now()
      WHERE product_id=p_product_id AND warehouse_id=p_warehouse_id
        AND serial_number=v_serial AND status='in_stock';
      IF NOT FOUND THEN
        RAISE EXCEPTION 'La serie % no está disponible en el almacén',v_serial USING ERRCODE='23514';
      END IF;
      v_count:=v_count+1;
      v_allocations:=v_allocations||jsonb_build_array(jsonb_build_object(
        'serial_number',v_serial
      ));
    END LOOP;
    IF v_count<>p_base_quantity::integer THEN
      RAISE EXCEPTION 'Cantidad de series inconsistente' USING ERRCODE='23514';
    END IF;
  END IF;

  INSERT INTO public.inventory_traceability_consumptions(
    request_id,product_id,warehouse_id,mode,base_quantity,allocations
  ) VALUES(
    p_request_id,p_product_id,p_warehouse_id,v_config.mode,p_base_quantity,v_allocations
  );
  RETURN v_allocations;
END;
$function$;

REVOKE ALL ON FUNCTION public._consume_inventory_traceability_v1(
  uuid,bigint,bigint,numeric,jsonb
) FROM PUBLIC,anon,authenticated;

COMMIT;