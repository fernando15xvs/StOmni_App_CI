BEGIN;

CREATE OR REPLACE FUNCTION public.process_sale_authorized_v4(
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
DECLARE
  v_configured boolean := false;
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION 'No tienes permiso para registrar ventas' USING ERRCODE = '42501';
  END IF;
  IF coalesce(p_descuento_global_monto, 0) > 0
     AND NOT public.app_tiene_permiso('sales.discount') THEN
    RAISE EXCEPTION 'No tienes permiso para aplicar descuentos' USING ERRCODE = '42501';
  END IF;

  IF p_detalles IS NOT NULL AND jsonb_typeof(p_detalles) = 'array' THEN
    SELECT EXISTS (
      SELECT 1
      FROM jsonb_array_elements(p_detalles) AS detail
      WHERE detail ? 'unit_profile_revision'
    ) INTO v_configured;
  END IF;

  IF v_configured THEN
    RETURN public.process_sale_with_units_v3(
      p_request_id,p_cliente_id,p_total,p_fecha,p_es_credito,p_monto_abono,
      p_detalles,p_pagos,p_cotizacion_id,p_vendedor_id,p_tipo_comprobante,
      p_descuento_global_porcentaje,p_descuento_global_monto,p_motivo_descuento,
      p_subtotal_bruto,p_descuento_autorizado_por
    );
  END IF;

  RETURN public.process_sale_v3(
    p_request_id,p_cliente_id,p_total,p_fecha,p_es_credito,p_monto_abono,
    p_detalles,p_pagos,p_cotizacion_id,p_vendedor_id,p_tipo_comprobante,
    p_descuento_global_porcentaje,p_descuento_global_monto,p_motivo_descuento,
    p_subtotal_bruto,p_descuento_autorizado_por
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
    RAISE EXCEPTION 'No tienes permiso para registrar mermas' USING ERRCODE = '42501';
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
    RAISE EXCEPTION 'No tienes permiso para trasladar stock' USING ERRCODE = '42501';
  END IF;
  RETURN public.trasladar_stock_scaled_v1(
    p_request_id,p_producto_id,p_origen_id,p_destino_id,p_cantidad_base,p_motivo,p_fecha
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
DECLARE
  v_permission text;
BEGIN
  v_permission := CASE
    WHEN lower(trim(coalesce(p_tipo_ingreso, ''))) LIKE '%ajuste%'
      THEN 'inventory.adjust'
    ELSE 'inventory.receive'
  END;
  IF NOT public.app_tiene_permiso(v_permission) THEN
    RAISE EXCEPTION 'No tienes permiso para registrar este ingreso de inventario'
      USING ERRCODE = '42501';
  END IF;
  RETURN public.registrar_ingreso_mercaderia_scaled_v1(
    p_request_id,p_producto_id,p_fecha,p_tipo_ingreso,p_documento,p_proveedor_id,
    p_observaciones,p_almacenes,p_ingreso_costo,p_ingreso_p_unit,p_ingreso_p_caja,
    p_ingreso_p_c_comp
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
    RAISE EXCEPTION 'No tienes permiso para ajustar stock' USING ERRCODE = '42501';
  END IF;
  PERFORM public.ajustar_stock_scaled_v1(
    p_producto_id,p_almacen_id,p_delta_base,p_tipo_movimiento,p_motivo,
    p_ingreso_costo,p_ingreso_p_unit,p_ingreso_p_caja,p_ingreso_p_c_comp,
    p_salida_cliente,p_salida_p_unit,p_salida_total
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.process_sale_authorized_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.registrar_merma_scaled_v2(uuid,bigint,bigint,numeric,text,timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.trasladar_stock_scaled_v2(uuid,bigint,bigint,bigint,numeric,text,timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.registrar_ingreso_mercaderia_scaled_v2(uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.ajustar_stock_scaled_v2(bigint,bigint,numeric,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_sale_authorized_v4(uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_merma_scaled_v2(uuid,bigint,bigint,numeric,text,timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.trasladar_stock_scaled_v2(uuid,bigint,bigint,bigint,numeric,text,timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.registrar_ingreso_mercaderia_scaled_v2(uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.ajustar_stock_scaled_v2(bigint,bigint,numeric,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric) TO authenticated;

COMMIT;
