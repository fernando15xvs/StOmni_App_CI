BEGIN;

-- Final ordering guard. Earlier pricing migrations introduce the resolver and
-- rules, while later historical permission migrations redefine v4 wrappers.
-- Reinstall the public wrappers last so both permission and authoritative
-- pricing checks are present in a clean migration run.
CREATE OR REPLACE FUNCTION public.process_sale_v4(
  p_request_id uuid,p_cliente_id bigint,p_total numeric,p_fecha timestamptz,
  p_es_credito boolean,p_monto_abono numeric,p_detalles jsonb,p_pagos jsonb,
  p_cotizacion_id bigint,p_vendedor_id bigint,p_tipo_comprobante text,
  p_descuento_global_porcentaje numeric,p_descuento_global_monto numeric,
  p_motivo_descuento text,p_subtotal_bruto numeric,p_descuento_autorizado_por bigint
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public
AS $function$
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION 'No autorizado para registrar ventas' USING ERRCODE='42501';
  END IF;
  IF coalesce(p_descuento_global_monto,0)>0
     AND NOT public.app_tiene_permiso('sales.discount') THEN
    RAISE EXCEPTION 'No autorizado para aplicar descuentos' USING ERRCODE='42501';
  END IF;
  PERFORM public._assert_authorized_sale_prices_v1(
    p_detalles,p_fecha,p_cotizacion_id
  );
  RETURN public.process_sale_v3(
    p_request_id,p_cliente_id,p_total,p_fecha,p_es_credito,p_monto_abono,
    p_detalles,p_pagos,p_cotizacion_id,p_vendedor_id,p_tipo_comprobante,
    p_descuento_global_porcentaje,p_descuento_global_monto,p_motivo_descuento,
    p_subtotal_bruto,p_descuento_autorizado_por
  );
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
BEGIN
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION 'No autorizado para registrar ventas' USING ERRCODE='42501';
  END IF;
  IF coalesce(p_descuento_global_monto,0)>0
     AND NOT public.app_tiene_permiso('sales.discount') THEN
    RAISE EXCEPTION 'No autorizado para aplicar descuentos' USING ERRCODE='42501';
  END IF;
  PERFORM public._assert_authorized_sale_prices_v1(
    p_detalles,p_fecha,p_cotizacion_id
  );
  RETURN public.process_sale_with_units_v3(
    p_request_id,p_cliente_id,p_total,p_fecha,p_es_credito,p_monto_abono,
    p_detalles,p_pagos,p_cotizacion_id,p_vendedor_id,p_tipo_comprobante,
    p_descuento_global_porcentaje,p_descuento_global_monto,p_motivo_descuento,
    p_subtotal_bruto,p_descuento_autorizado_por
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.process_sale_v4(
  uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,
  text,numeric,numeric,text,numeric,bigint
) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.process_sale_with_units_v4(
  uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,
  text,numeric,numeric,text,numeric,bigint
) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.process_sale_v4(
  uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,
  text,numeric,numeric,text,numeric,bigint
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_sale_with_units_v4(
  uuid,bigint,numeric,timestamptz,boolean,numeric,jsonb,jsonb,bigint,bigint,
  text,numeric,numeric,text,numeric,bigint
) TO authenticated;

COMMIT;