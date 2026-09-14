BEGIN;

CREATE OR REPLACE FUNCTION public.register_traceable_merchandise_receipt_v1(
  p_request_id uuid,
  p_product_id bigint,
  p_warehouse_id bigint,
  p_total_base_quantity numeric,
  p_received_at timestamptz,
  p_entry_type text,
  p_document text,
  p_supplier_id bigint,
  p_observations text,
  p_unit_cost numeric,
  p_unit_price numeric,
  p_box_price numeric,
  p_comparative_box_price numeric,
  p_allocations jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_config public.product_traceability_configs%ROWTYPE;
  v_existing public.inventory_traceability_receipts%ROWTYPE;
  v_allocation jsonb;
  v_sum numeric:=0;
  v_qty numeric;
  v_lot text;
  v_expiry date;
  v_existing_expiry date;
  v_serial text;
  v_inventory_request uuid;
  v_profile jsonb;
BEGIN
  IF NOT public.app_tiene_permiso('inventory.receive') THEN
    RAISE EXCEPTION 'No autorizado para recibir inventario' USING ERRCODE='42501';
  END IF;
  IF p_request_id IS NULL OR p_product_id IS NULL OR p_product_id<=0
     OR p_warehouse_id IS NULL OR p_warehouse_id<=0
     OR p_total_base_quantity IS NULL OR p_total_base_quantity<=0
     OR p_allocations IS NULL OR jsonb_typeof(p_allocations)<>'array'
     OR jsonb_array_length(p_allocations)=0 THEN
    RAISE EXCEPTION 'Recepción trazable inválida' USING ERRCODE='22023';
  END IF;

  SELECT * INTO v_existing FROM public.inventory_traceability_receipts
    WHERE request_id=p_request_id;
  IF FOUND THEN
    IF v_existing.product_id<>p_product_id OR v_existing.warehouse_id<>p_warehouse_id
       OR v_existing.total_base_quantity<>p_total_base_quantity THEN
      RAISE EXCEPTION 'El request_id pertenece a otra recepción' USING ERRCODE='23505';
    END IF;
    RETURN jsonb_build_object('idempotent',true,'inventory_request_id',v_existing.inventory_request_id);
  END IF;

  SELECT * INTO v_config FROM public.product_traceability_configs
    WHERE product_id=p_product_id FOR SHARE;
  IF NOT FOUND OR v_config.mode='none' THEN
    RAISE EXCEPTION 'El producto no tiene trazabilidad habilitada' USING ERRCODE='23514';
  END IF;

  v_profile:=public.get_business_profile_v1();
  IF v_config.mode='lot' AND coalesce((v_profile->'capabilities'->>'lot_tracking')::boolean,false)=false THEN
    RAISE EXCEPTION 'El seguimiento por lote no está habilitado para el negocio' USING ERRCODE='23514';
  END IF;
  IF v_config.mode='serial' AND coalesce((v_profile->'capabilities'->>'serial_number_tracking')::boolean,false)=false THEN
    RAISE EXCEPTION 'El seguimiento por serie no está habilitado para el negocio' USING ERRCODE='23514';
  END IF;
  IF v_config.expiry_required AND coalesce((v_profile->'capabilities'->>'expiry_tracking')::boolean,false)=false THEN
    RAISE EXCEPTION 'El seguimiento de vencimientos no está habilitado para el negocio' USING ERRCODE='23514';
  END IF;

  PERFORM public._visible_base_to_stored(p_product_id,p_total_base_quantity);
  PERFORM 1 FROM public.almacenes WHERE id=p_warehouse_id AND coalesce(activo,true) FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Almacén no disponible' USING ERRCODE='23503'; END IF;

  IF v_config.mode='lot' THEN
    FOR v_allocation IN SELECT value FROM jsonb_array_elements(p_allocations) LOOP
      v_lot:=trim(coalesce(v_allocation->>'lot_code',''));
      v_qty:=NULLIF(v_allocation->>'base_quantity','')::numeric;
      v_expiry:=NULLIF(v_allocation->>'expiry_date','')::date;
      IF v_lot='' OR length(v_lot)>100 OR v_qty IS NULL OR v_qty<=0
         OR (v_config.expiry_required AND v_expiry IS NULL) THEN
        RAISE EXCEPTION 'Asignación de lote inválida' USING ERRCODE='22023';
      END IF;
      PERFORM public._visible_base_to_stored(p_product_id,v_qty);
      SELECT expiry_date INTO v_existing_expiry
      FROM public.inventory_lots
      WHERE product_id=p_product_id AND warehouse_id=p_warehouse_id
        AND lot_code=v_lot FOR UPDATE;
      IF FOUND AND v_existing_expiry IS DISTINCT FROM v_expiry THEN
        RAISE EXCEPTION 'El lote % ya existe con otra fecha de vencimiento',v_lot USING ERRCODE='23514';
      END IF;
      v_sum:=v_sum+v_qty;
    END LOOP;
  ELSE
    IF p_total_base_quantity<>trunc(p_total_base_quantity)
       OR jsonb_array_length(p_allocations)<>p_total_base_quantity::integer THEN
      RAISE EXCEPTION 'Debe existir una serie por unidad recibida' USING ERRCODE='22023';
    END IF;
    FOR v_allocation IN SELECT value FROM jsonb_array_elements(p_allocations) LOOP
      v_serial:=trim(coalesce(v_allocation->>'serial_number',''));
      IF v_serial='' OR length(v_serial)>160 THEN
        RAISE EXCEPTION 'Número de serie inválido' USING ERRCODE='22023';
      END IF;
      IF EXISTS(SELECT 1 FROM public.inventory_serials
                WHERE product_id=p_product_id AND lower(serial_number)=lower(v_serial)) THEN
        RAISE EXCEPTION 'La serie % ya existe',v_serial USING ERRCODE='23505';
      END IF;
      v_sum:=v_sum+1;
    END LOOP;
  END IF;

  IF abs(v_sum-p_total_base_quantity)>0.000001 THEN
    RAISE EXCEPTION 'La trazabilidad no coincide con la cantidad recibida' USING ERRCODE='23514';
  END IF;

  v_inventory_request:=gen_random_uuid();
  PERFORM public.registrar_ingreso_mercaderia_scaled_v2(
    v_inventory_request,p_product_id,coalesce(p_received_at,now()),
    coalesce(nullif(trim(p_entry_type),''),'Ingreso trazable'),coalesce(trim(p_document),''),
    p_supplier_id,coalesce(trim(p_observations),''),
    jsonb_build_array(jsonb_build_object('almacen_id',p_warehouse_id,'cantidad_base',p_total_base_quantity)),
    coalesce(p_unit_cost,0),coalesce(p_unit_price,0),coalesce(p_box_price,0),
    coalesce(p_comparative_box_price,0)
  );

  IF v_config.mode='lot' THEN
    FOR v_allocation IN SELECT value FROM jsonb_array_elements(p_allocations) LOOP
      v_lot:=trim(v_allocation->>'lot_code');
      v_qty:=(v_allocation->>'base_quantity')::numeric;
      v_expiry:=NULLIF(v_allocation->>'expiry_date','')::date;
      INSERT INTO public.inventory_lots(product_id,warehouse_id,lot_code,expiry_date,base_quantity)
      VALUES(p_product_id,p_warehouse_id,v_lot,v_expiry,v_qty)
      ON CONFLICT(product_id,warehouse_id,lot_code) DO UPDATE SET
        base_quantity=public.inventory_lots.base_quantity+EXCLUDED.base_quantity,
        updated_at=now();
    END LOOP;
  ELSE
    FOR v_allocation IN SELECT value FROM jsonb_array_elements(p_allocations) LOOP
      INSERT INTO public.inventory_serials(
        product_id,warehouse_id,serial_number,status,received_request_id
      ) VALUES(
        p_product_id,p_warehouse_id,trim(v_allocation->>'serial_number'),'in_stock',p_request_id
      );
    END LOOP;
  END IF;

  INSERT INTO public.inventory_traceability_receipts(
    request_id,product_id,warehouse_id,mode,total_base_quantity,inventory_request_id
  ) VALUES(
    p_request_id,p_product_id,p_warehouse_id,v_config.mode,p_total_base_quantity,v_inventory_request
  );

  RETURN jsonb_build_object('idempotent',false,'inventory_request_id',v_inventory_request);
END;
$function$;

REVOKE ALL ON FUNCTION public.register_traceable_merchandise_receipt_v1(
  uuid,bigint,bigint,numeric,timestamptz,text,text,bigint,text,numeric,numeric,numeric,numeric,jsonb
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.register_traceable_merchandise_receipt_v1(
  uuid,bigint,bigint,numeric,timestamptz,text,text,bigint,text,numeric,numeric,numeric,numeric,jsonb
) TO authenticated;

COMMIT;