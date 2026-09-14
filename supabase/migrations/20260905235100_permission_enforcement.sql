BEGIN;

-- Public mutation entry points created during the architecture refactor are
-- wrapped here so a modified client cannot bypass the same effective permission
-- set enforced by the application layer. The underlying hardened transactions
-- remain unchanged and keep their existing idempotency/locking behavior.

CREATE OR REPLACE FUNCTION public.process_sale_v4(
  p_request_id uuid,
  p_cliente_id bigint,
  p_total numeric,
  p_fecha timestamptz,
  p_es_credito boolean,
  p_monto_abono numeric,
  p_detalles jsonb,
  p_pagos jsonb,
  p_cotizacion_id bigint,
  p_vendedor_id bigint,
  p_tipo_comprobante text,
  p_descuento_global_porcentaje numeric,
  p_descuento_global_monto numeric,
  p_motivo_descuento text,
  p_subtotal_bruto numeric,
  p_descuento_autorizado_por bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION 'No autorizado para registrar ventas' USING ERRCODE = '42501';
  END IF;
  IF coalesce(p_descuento_global_monto, 0) > 0
     AND NOT public.app_tiene_permiso('sales.discount') THEN
    RAISE EXCEPTION 'No autorizado para aplicar descuentos' USING ERRCODE = '42501';
  END IF;

  RETURN public.process_sale_v3(
    p_request_id,p_cliente_id,p_total,p_fecha,p_es_credito,p_monto_abono,
    p_detalles,p_pagos,p_cotizacion_id,p_vendedor_id,p_tipo_comprobante,
    p_descuento_global_porcentaje,p_descuento_global_monto,p_motivo_descuento,
    p_subtotal_bruto,p_descuento_autorizado_por
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.process_sale_with_units_v4(
  p_request_id uuid,
  p_cliente_id bigint,
  p_total numeric,
  p_fecha timestamptz,
  p_es_credito boolean,
  p_monto_abono numeric,
  p_detalles jsonb,
  p_pagos jsonb,
  p_cotizacion_id bigint,
  p_vendedor_id bigint,
  p_tipo_comprobante text,
  p_descuento_global_porcentaje numeric,
  p_descuento_global_monto numeric,
  p_motivo_descuento text,
  p_subtotal_bruto numeric,
  p_descuento_autorizado_por bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION 'No autorizado para registrar ventas' USING ERRCODE = '42501';
  END IF;
  IF coalesce(p_descuento_global_monto, 0) > 0
     AND NOT public.app_tiene_permiso('sales.discount') THEN
    RAISE EXCEPTION 'No autorizado para aplicar descuentos' USING ERRCODE = '42501';
  END IF;

  RETURN public.process_sale_with_units_v3(
    p_request_id,p_cliente_id,p_total,p_fecha,p_es_credito,p_monto_abono,
    p_detalles,p_pagos,p_cotizacion_id,p_vendedor_id,p_tipo_comprobante,
    p_descuento_global_porcentaje,p_descuento_global_monto,p_motivo_descuento,
    p_subtotal_bruto,p_descuento_autorizado_por
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_ingreso_mercaderia_scaled_v2(
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
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF NOT public.app_tiene_permiso('inventory.receive') THEN
    RAISE EXCEPTION 'No autorizado para registrar ingresos de inventario' USING ERRCODE = '42501';
  END IF;
  RETURN public.registrar_ingreso_mercaderia_scaled_v1(
    p_request_id,p_producto_id,p_fecha,p_tipo_ingreso,p_documento,
    p_proveedor_id,p_observaciones,p_almacenes,p_ingreso_costo,
    p_ingreso_p_unit,p_ingreso_p_caja,p_ingreso_p_c_comp
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_merma_scaled_v2(
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
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF NOT public.app_tiene_permiso('inventory.adjust') THEN
    RAISE EXCEPTION 'No autorizado para registrar mermas' USING ERRCODE = '42501';
  END IF;
  RETURN public.registrar_merma_scaled_v1(
    p_request_id,p_producto_id,p_almacen_id,p_cantidad_base,p_motivo,p_fecha
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.trasladar_stock_scaled_v2(
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
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF NOT public.app_tiene_permiso('inventory.adjust') THEN
    RAISE EXCEPTION 'No autorizado para trasladar stock' USING ERRCODE = '42501';
  END IF;
  RETURN public.trasladar_stock_scaled_v1(
    p_request_id,p_producto_id,p_origen_id,p_destino_id,p_cantidad_base,p_motivo,p_fecha
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.ajustar_stock_scaled_v2(
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
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF NOT public.app_tiene_permiso('inventory.adjust') THEN
    RAISE EXCEPTION 'No autorizado para ajustar stock' USING ERRCODE = '42501';
  END IF;
  PERFORM public.ajustar_stock_scaled_v1(
    p_producto_id,p_almacen_id,p_delta_base,p_tipo_movimiento,p_motivo,
    p_ingreso_costo,p_ingreso_p_unit,p_ingreso_p_caja,p_ingreso_p_c_comp,
    p_salida_cliente,p_salida_p_unit,p_salida_total
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.save_product_unit_profile_v6(
  p_product_id bigint,
  p_expected_revision bigint,
  p_profile jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  IF NOT public.app_tiene_permiso('products.update') THEN
    RAISE EXCEPTION 'No autorizado para modificar presentaciones del producto' USING ERRCODE = '42501';
  END IF;
  -- Keep the fiscal validation introduced by 20260905232000. This wrapper adds
  -- authorization; it must not weaken the final fiscal-unit contract.
  PERFORM public._validate_product_unit_fiscal_codes_v1(p_profile);
  RETURN public.save_product_unit_profile_v5(
    p_product_id,p_expected_revision,p_profile
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.process_sale_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.process_sale_with_units_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.registrar_ingreso_mercaderia_scaled_v2(uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.registrar_merma_scaled_v2(uuid,bigint,bigint,numeric,text,timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.trasladar_stock_scaled_v2(uuid,bigint,bigint,bigint,numeric,text,timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ajustar_stock_scaled_v2(bigint,bigint,numeric,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.save_product_unit_profile_v6(bigint,bigint,jsonb) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.process_sale_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_sale_with_units_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_ingreso_mercaderia_scaled_v2(uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_merma_scaled_v2(uuid,bigint,bigint,numeric,text,timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.trasladar_stock_scaled_v2(uuid,bigint,bigint,bigint,numeric,text,timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ajustar_stock_scaled_v2(bigint,bigint,numeric,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_product_unit_profile_v6(bigint,bigint,jsonb) TO authenticated;

COMMIT;
