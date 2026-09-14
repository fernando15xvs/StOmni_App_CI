CREATE OR REPLACE FUNCTION public.nota_credito_finalizar(p_nota_credito_id uuid, p_bloqueo_token uuid, p_estado text, p_resultado jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_nota record;
  v_estado text := LOWER(TRIM(COALESCE(p_estado, '')));
  v_intento_id uuid;
  v_codigo_http integer;
  v_duracion integer;
  v_mensaje text;
  v_stock_result jsonb;
  v_total_nc numeric(14,2);
  v_venta_total numeric(14,2);
BEGIN
  IF v_estado NOT IN ('aceptado', 'rechazado', 'pendiente_reintento', 'resultado_incierto') THEN
    RAISE EXCEPTION 'Estado final inválido: %', v_estado;
  END IF;

  SELECT * INTO v_nota
  FROM public.notas_credito
  WHERE id = p_nota_credito_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nota de crédito no encontrada';
  END IF;

  IF v_nota.estado = 'aceptado' AND v_estado <> 'aceptado' THEN
    RETURN jsonb_build_object(
      'success', true, 'estado', 'aceptado', 'idempotent', true,
      'ignored_state', v_estado, 'nota_credito_id', p_nota_credito_id
    );
  END IF;

  IF v_nota.bloqueo_token IS DISTINCT FROM p_bloqueo_token THEN
    IF v_nota.estado = 'aceptado' AND v_estado = 'aceptado' THEN
      RETURN jsonb_build_object(
        'success', true, 'estado', 'aceptado', 'idempotent', true,
        'nota_credito_id', p_nota_credito_id
      );
    END IF;
    RAISE EXCEPTION 'El bloqueo de la nota ya no es válido';
  END IF;

  v_intento_id := NULLIF(p_resultado->>'intento_id', '')::uuid;
  v_codigo_http := NULLIF(p_resultado->>'codigo_http', '')::integer;
  v_duracion := NULLIF(p_resultado->>'duracion_ms', '')::integer;
  v_mensaje := NULLIF(TRIM(p_resultado->>'mensaje_error'), '');

  UPDATE public.notas_credito
  SET
    estado = v_estado,
    payload_json = COALESCE(p_resultado->'payload_json', payload_json),
    respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
    xml_path = COALESCE(NULLIF(p_resultado->>'xml_path', ''), xml_path),
    cdr_path = COALESCE(NULLIF(p_resultado->>'cdr_path', ''), cdr_path),
    pdf_path = COALESCE(NULLIF(p_resultado->>'pdf_path', ''), pdf_path),
    hash_documento = COALESCE(NULLIF(p_resultado->>'hash_documento', ''), hash_documento),
    codigo_sunat = COALESCE(NULLIF(p_resultado->>'codigo_sunat', ''), codigo_sunat),
    descripcion_sunat = COALESCE(NULLIF(p_resultado->>'descripcion_sunat', ''), v_mensaje, descripcion_sunat),
    observaciones_sunat = COALESCE(p_resultado->'observaciones_sunat', observaciones_sunat),
    archivo_nombre_base = COALESCE(NULLIF(p_resultado->>'archivo_nombre_base', ''), archivo_nombre_base),
    ticket_sunat = COALESCE(NULLIF(p_resultado->>'ticket_sunat', ''), ticket_sunat),
    ultimo_error_tipo = CASE
      WHEN v_estado = 'aceptado' THEN NULL
      ELSE COALESCE(NULLIF(p_resultado->>'error_tipo', ''), ultimo_error_tipo)
    END,
    ultimo_http_status = v_codigo_http,
    enviado_at = CASE
      WHEN v_estado IN ('aceptado', 'rechazado', 'resultado_incierto')
        THEN COALESCE(enviado_at, now())
      ELSE enviado_at
    END,
    aceptado_at = CASE
      WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now())
      ELSE aceptado_at
    END,
    pdf_generado_at = CASE
      WHEN NULLIF(p_resultado->>'pdf_path', '') IS NOT NULL THEN now()
      ELSE pdf_generado_at
    END,
    procesando_at = NULL,
    bloqueo_token = NULL,
    bloqueo_expira_at = NULL
  WHERE id = p_nota_credito_id;

  IF v_intento_id IS NOT NULL THEN
    UPDATE public.notas_credito_intentos
    SET
      resultado = v_estado,
      codigo_http = v_codigo_http,
      codigo_error = NULLIF(p_resultado->>'codigo_error', ''),
      mensaje_error = v_mensaje,
      payload_json = COALESCE(p_resultado->'payload_json', payload_json),
      respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
      fecha_fin = now(),
      duracion_ms = COALESCE(
        v_duracion,
        GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (now() - fecha_inicio)) * 1000)::integer)
      )
    WHERE id = v_intento_id;
  END IF;

  IF v_estado = 'aceptado'
     AND v_nota.reponer_stock = true
     AND v_nota.stock_aplicado = false THEN
    v_stock_result := public._aplicar_stock_nota_credito(p_nota_credito_id);
  END IF;

  SELECT
    COALESCE(SUM(nc.total), 0),
    v.total
  INTO v_total_nc, v_venta_total
  FROM public.ventas AS v
  LEFT JOIN public.notas_credito AS nc
    ON nc.venta_id = v.id
   AND nc.estado = 'aceptado'
   AND nc.afecta_dinero = true
   AND COALESCE(nc.estado_baja_tributaria, 'ninguna') <> 'aceptada'
  WHERE v.id = v_nota.venta_id
  GROUP BY v.total;

  UPDATE public.ventas
  SET
    monto_notas_credito = ROUND(COALESCE(v_total_nc, 0), 2),
    estado_tributario = CASE
      WHEN COALESCE(v_total_nc, 0) >= COALESCE(v_venta_total, 0) - 0.02 THEN 'anulada'
      WHEN COALESCE(v_total_nc, 0) > 0.01 THEN 'parcialmente_ajustada'
      ELSE 'vigente'
    END
  WHERE id = v_nota.venta_id;

  RETURN jsonb_build_object(
    'success', true,
    'estado', v_estado,
    'nota_credito_id', p_nota_credito_id,
    'venta_id', v_nota.venta_id,
    'stock_aplicado', CASE
      WHEN v_estado = 'aceptado' THEN (
        SELECT stock_aplicado FROM public.notas_credito
        WHERE id = p_nota_credito_id
      )
      ELSE false
    END,
    'stock_resultado', v_stock_result,
    'stock_error', (
      SELECT stock_error FROM public.notas_credito
      WHERE id = p_nota_credito_id
    )
  );
END;
$function$
