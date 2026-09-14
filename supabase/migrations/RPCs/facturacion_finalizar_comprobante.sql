CREATE OR REPLACE FUNCTION public.facturacion_finalizar_comprobante(p_comprobante_id uuid, p_bloqueo_token uuid, p_estado text, p_resultado jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_comp record;
  v_estado text := lower(trim(COALESCE(p_estado, '')));
  v_intento_id uuid;
  v_codigo_http integer;
  v_duracion integer;
  v_mensaje text;
BEGIN
  IF v_estado NOT IN (
    'aceptado', 'rechazado', 'pendiente_reintento',
    'resultado_incierto', 'ticket_pendiente'
  ) THEN
    RAISE EXCEPTION 'Estado final inválido: %', v_estado;
  END IF;

  SELECT * INTO v_comp
  FROM public.comprobantes_electronicos
  WHERE id = p_comprobante_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Comprobante no encontrado'; END IF;

  IF v_comp.estado = 'aceptado' AND v_estado <> 'aceptado' THEN
    RETURN jsonb_build_object('success', true, 'estado', 'aceptado',
      'idempotent', true, 'ignored_state', v_estado,
      'comprobante_id', p_comprobante_id, 'venta_id', v_comp.venta_id);
  END IF;

  IF v_comp.bloqueo_token IS DISTINCT FROM p_bloqueo_token THEN
    IF v_comp.estado = 'aceptado' AND v_estado = 'aceptado' THEN
      RETURN jsonb_build_object('success', true, 'estado', 'aceptado',
        'idempotent', true, 'comprobante_id', p_comprobante_id,
        'venta_id', v_comp.venta_id);
    END IF;
    RAISE EXCEPTION 'El bloqueo del comprobante ya no es válido';
  END IF;

  v_intento_id := NULLIF(p_resultado->>'intento_id', '')::uuid;
  v_codigo_http := NULLIF(p_resultado->>'codigo_http', '')::integer;
  v_duracion := NULLIF(p_resultado->>'duracion_ms', '')::integer;
  v_mensaje := NULLIF(trim(p_resultado->>'mensaje_error'), '');

  UPDATE public.comprobantes_electronicos
  SET estado = v_estado,
      payload_json = COALESCE(p_resultado->'payload_json', payload_json),
      respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
      xml_path = COALESCE(NULLIF(p_resultado->>'xml_path', ''), xml_path),
      cdr_path = COALESCE(NULLIF(p_resultado->>'cdr_path', ''), cdr_path),
      pdf_path = COALESCE(NULLIF(p_resultado->>'pdf_path', ''), pdf_path),
      hash_documento = COALESCE(NULLIF(p_resultado->>'hash_documento', ''), hash_documento),
      codigo_sunat = COALESCE(NULLIF(p_resultado->>'codigo_sunat', ''), codigo_sunat),
      descripcion_sunat = COALESCE(NULLIF(p_resultado->>'descripcion_sunat', ''), v_mensaje, descripcion_sunat),
      observaciones_sunat = COALESCE(p_resultado->'observaciones_sunat', observaciones_sunat),
      ticket_sunat = COALESCE(NULLIF(p_resultado->>'ticket_sunat', ''), ticket_sunat),
      archivo_nombre_base = COALESCE(NULLIF(p_resultado->>'archivo_nombre_base', ''), archivo_nombre_base),
      ultimo_error_tipo = CASE WHEN v_estado = 'aceptado' THEN NULL
        ELSE COALESCE(NULLIF(p_resultado->>'error_tipo', ''), ultimo_error_tipo) END,
      ultimo_http_status = v_codigo_http,
      enviado_at = CASE
        WHEN v_estado IN ('aceptado', 'rechazado', 'ticket_pendiente', 'resultado_incierto')
          OR COALESCE((p_resultado->>'remoto_iniciado')::boolean, false)
        THEN COALESCE(enviado_at, now()) ELSE enviado_at END,
      aceptado_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now()) ELSE aceptado_at END,
      consultado_at = CASE WHEN COALESCE((p_resultado->>'fue_consulta')::boolean, false)
        THEN now() ELSE consultado_at END,
      pdf_generado_at = CASE WHEN NULLIF(p_resultado->>'pdf_path', '') IS NOT NULL
        THEN now() ELSE pdf_generado_at END,
      procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
  WHERE id = p_comprobante_id;

  IF v_intento_id IS NOT NULL THEN
    UPDATE public.facturacion_intentos
    SET resultado = v_estado, codigo_http = v_codigo_http,
        codigo_error = NULLIF(p_resultado->>'codigo_error', ''),
        mensaje_error = v_mensaje,
        respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
        payload_json = COALESCE(p_resultado->'payload_json', payload_json),
        fecha_fin = now(),
        duracion_ms = COALESCE(v_duracion,
          GREATEST(0, floor(extract(epoch FROM (now() - fecha_inicio)) * 1000)::integer))
    WHERE id = v_intento_id;
  END IF;

  UPDATE public.ventas SET estado_facturacion = v_estado
  WHERE id = v_comp.venta_id;

  RETURN jsonb_build_object('success', true, 'estado', v_estado,
    'comprobante_id', p_comprobante_id, 'venta_id', v_comp.venta_id);
END;
$function$
