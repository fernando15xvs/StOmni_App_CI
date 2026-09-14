BEGIN;

-- Serial tracking represents one physical identity per base unit. Products with
-- fractional base storage cannot use serial mode.
CREATE OR REPLACE FUNCTION public.save_product_traceability_config_v1(
  p_product_id bigint,
  p_expected_revision bigint,
  p_mode text,
  p_expiry_required boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE v_current public.product_traceability_configs%ROWTYPE;
BEGIN
  IF NOT public.app_tiene_permiso('products.update') THEN
    RAISE EXCEPTION 'No autorizado para configurar trazabilidad' USING ERRCODE='42501';
  END IF;
  IF p_product_id IS NULL OR p_product_id<=0 OR p_expected_revision IS NULL OR p_expected_revision<0
     OR p_mode NOT IN ('none','lot','serial')
     OR (coalesce(p_expiry_required,false) AND p_mode<>'lot') THEN
    RAISE EXCEPTION 'Configuración de trazabilidad inválida' USING ERRCODE='22023';
  END IF;
  IF p_mode='serial' AND public._product_storage_scale_for_id(p_product_id)<>1 THEN
    RAISE EXCEPTION 'La trazabilidad por serie requiere unidad base indivisible' USING ERRCODE='23514';
  END IF;
  PERFORM 1 FROM public.productos WHERE id=p_product_id AND coalesce(activo,true) FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Producto inexistente o inactivo' USING ERRCODE='P0002'; END IF;
  SELECT * INTO v_current FROM public.product_traceability_configs
    WHERE product_id=p_product_id FOR UPDATE;
  IF FOUND THEN
    IF v_current.revision<>p_expected_revision THEN
      RAISE EXCEPTION 'La configuración cambió en otro dispositivo' USING ERRCODE='40001';
    END IF;
    IF v_current.mode<>p_mode AND (
      EXISTS(SELECT 1 FROM public.inventory_lots WHERE product_id=p_product_id AND base_quantity>0)
      OR EXISTS(SELECT 1 FROM public.inventory_serials WHERE product_id=p_product_id AND status='in_stock')
    ) THEN
      RAISE EXCEPTION 'No puedes cambiar el modo mientras exista stock trazable' USING ERRCODE='23514';
    END IF;
    UPDATE public.product_traceability_configs SET
      mode=p_mode,expiry_required=coalesce(p_expiry_required,false),
      revision=revision+1,updated_at=now()
    WHERE product_id=p_product_id;
  ELSE
    IF p_expected_revision<>0 THEN
      RAISE EXCEPTION 'La configuración ya no coincide' USING ERRCODE='40001';
    END IF;
    INSERT INTO public.product_traceability_configs(product_id,mode,expiry_required)
      VALUES(p_product_id,p_mode,coalesce(p_expiry_required,false));
  END IF;
  RETURN public.get_product_traceability_config_v1(p_product_id);
END;
$function$;

CREATE TABLE public.inventory_traceability_consumptions (
  request_id uuid NOT NULL,
  product_id bigint NOT NULL REFERENCES public.productos(id),
  warehouse_id bigint NOT NULL REFERENCES public.almacenes(id),
  mode text NOT NULL CHECK(mode IN ('lot','serial')),
  base_quantity numeric(20,6) NOT NULL CHECK(base_quantity>0),
  allocations jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(request_id,product_id,warehouse_id)
);
ALTER TABLE public.inventory_traceability_consumptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_traceability_consumptions FROM PUBLIC,anon,authenticated;

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
  IF NOT FOUND OR v_config.mode='none' THEN
    RETURN '[]'::jsonb;
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

CREATE OR REPLACE FUNCTION public._consume_sale_traceability_v1(
  p_request_id uuid,
  p_detalles jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_detail jsonb;
  v_product_id bigint;
  v_warehouse_id bigint;
  v_stored numeric;
  v_scale integer;
  v_base numeric;
BEGIN
  IF p_detalles IS NULL OR jsonb_typeof(p_detalles)<>'array' THEN
    RAISE EXCEPTION 'Detalles de venta inválidos' USING ERRCODE='22023';
  END IF;
  FOR v_detail IN SELECT value FROM jsonb_array_elements(p_detalles) LOOP
    v_product_id:=NULLIF(v_detail->>'producto_id','')::bigint;
    v_warehouse_id:=NULLIF(v_detail->>'almacen_id','')::bigint;
    v_stored:=NULLIF(v_detail->>'piezas_reales','')::numeric;
    v_scale:=coalesce(NULLIF(v_detail->>'stock_scale','')::integer,
                      public._product_storage_scale_for_id(v_product_id));
    IF v_product_id IS NULL OR v_warehouse_id IS NULL OR v_stored IS NULL
       OR v_stored<=0 OR v_scale<=0 OR v_stored<>trunc(v_stored) THEN
      RAISE EXCEPTION 'Detalle de venta sin cantidad trazable válida' USING ERRCODE='22023';
    END IF;
    v_base:=v_stored/v_scale;
    PERFORM public._consume_inventory_traceability_v1(
      p_request_id,v_product_id,v_warehouse_id,v_base,v_detail->'serial_numbers'
    );
  END LOOP;
END;
$function$;

-- Reinstall final public wrappers with permission, price and traceability guards.
CREATE OR REPLACE FUNCTION public.process_sale_v4(
  p_request_id uuid,p_cliente_id bigint,p_total numeric,p_fecha timestamptz,
  p_es_credito boolean,p_monto_abono numeric,p_detalles jsonb,p_pagos jsonb,
  p_cotizacion_id bigint,p_vendedor_id bigint,p_tipo_comprobante text,
  p_descuento_global_porcentaje numeric,p_descuento_global_monto numeric,
  p_motivo_descuento text,p_subtotal_bruto numeric,p_descuento_autorizado_por bigint
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION 'No autorizado para registrar ventas' USING ERRCODE='42501';
  END IF;
  IF coalesce(p_descuento_global_monto,0)>0
     AND NOT public.app_tiene_permiso('sales.discount') THEN
    RAISE EXCEPTION 'No autorizado para aplicar descuentos' USING ERRCODE='42501';
  END IF;
  PERFORM public._assert_authorized_sale_prices_v1(p_detalles,p_fecha,p_cotizacion_id);
  PERFORM public._consume_sale_traceability_v1(p_request_id,p_detalles);
  v_result:=public.process_sale_v3(
    p_request_id,p_cliente_id,p_total,p_fecha,p_es_credito,p_monto_abono,
    p_detalles,p_pagos,p_cotizacion_id,p_vendedor_id,p_tipo_comprobante,
    p_descuento_global_porcentaje,p_descuento_global_monto,p_motivo_descuento,
    p_subtotal_bruto,p_descuento_autorizado_por
  );
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_sale_with_units_v4(
  p_request_id uuid,p_cliente_id bigint,p_total numeric,p_fecha timestamptz,
  p_es_credito boolean,p_monto_abono numeric,p_detalles jsonb,p_pagos jsonb,
  p_cotizacion_id bigint,p_vendedor_id bigint,p_tipo_comprobante text,
  p_descuento_global_porcentaje numeric,p_descuento_global_monto numeric,
  p_motivo_descuento text,p_subtotal_bruto numeric,p_descuento_autorizado_por bigint
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION 'No autorizado para registrar ventas' USING ERRCODE='42501';
  END IF;
  IF coalesce(p_descuento_global_monto,0)>0
     AND NOT public.app_tiene_permiso('sales.discount') THEN
    RAISE EXCEPTION 'No autorizado para aplicar descuentos' USING ERRCODE='42501';
  END IF;
  PERFORM public._assert_authorized_sale_prices_v1(p_detalles,p_fecha,p_cotizacion_id);
  PERFORM public._consume_sale_traceability_v1(p_request_id,p_detalles);
  v_result:=public.process_sale_with_units_v3(
    p_request_id,p_cliente_id,p_total,p_fecha,p_es_credito,p_monto_abono,
    p_detalles,p_pagos,p_cotizacion_id,p_vendedor_id,p_tipo_comprobante,
    p_descuento_global_porcentaje,p_descuento_global_monto,p_motivo_descuento,
    p_subtotal_bruto,p_descuento_autorizado_por
  );
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public._consume_inventory_traceability_v1(uuid,bigint,bigint,numeric,jsonb)
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._consume_sale_traceability_v1(uuid,jsonb)
  FROM PUBLIC,anon,authenticated;
REVOKE ALL ON public.inventory_traceability_consumptions FROM PUBLIC,anon,authenticated;

COMMIT;