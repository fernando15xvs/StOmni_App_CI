CREATE OR REPLACE FUNCTION public.gre_finalizar(p_guia_id uuid, p_bloqueo_token uuid, p_estado text, p_resultado jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_guia public.guias_remision%ROWTYPE;
  v_estado text := lower(trim(COALESCE(p_estado, '')));
  v_intento_id uuid;
  v_codigo_http integer;
  v_duracion integer;
  v_mensaje text;
BEGIN
  IF v_estado NOT IN (
    'pendiente_envio', 'ticket_pendiente', 'pendiente_reintento',
    'resultado_incierto', 'xml_validado_prueba', 'aceptado', 'rechazado'
  ) THEN
    RAISE EXCEPTION 'Estado final GRE inválido: %', v_estado;
  END IF;

  SELECT * INTO v_guia FROM public.guias_remision
  WHERE id = p_guia_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Guía no encontrada'; END IF;

  IF v_guia.estado = 'aceptado' AND v_estado <> 'aceptado' THEN
    RETURN jsonb_build_object('success', true, 'estado', 'aceptado', 'idempotent', true);
  END IF;

  IF v_guia.bloqueo_token IS DISTINCT FROM p_bloqueo_token THEN
    IF v_guia.estado = 'aceptado' AND v_estado = 'aceptado' THEN
      RETURN jsonb_build_object('success', true, 'estado', 'aceptado', 'idempotent', true);
    END IF;
    RAISE EXCEPTION 'El bloqueo de la guía ya no es válido';
  END IF;

  v_intento_id := NULLIF(p_resultado->>'intento_id', '')::uuid;
  v_codigo_http := NULLIF(p_resultado->>'codigo_http', '')::integer;
  v_duracion := NULLIF(p_resultado->>'duracion_ms', '')::integer;
  v_mensaje := NULLIF(trim(p_resultado->>'mensaje_error'), '');

  UPDATE public.guias_remision
  SET estado = v_estado,
      payload_json = COALESCE(p_resultado->'payload_json', payload_json),
      respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
      ticket_sunat = COALESCE(NULLIF(p_resultado->>'ticket_sunat', ''), ticket_sunat),
      codigo_sunat = COALESCE(NULLIF(p_resultado->>'codigo_sunat', ''), codigo_sunat),
      descripcion_sunat = COALESCE(NULLIF(p_resultado->>'descripcion_sunat', ''), v_mensaje, descripcion_sunat),
      observaciones_sunat = COALESCE(p_resultado->'observaciones_sunat', observaciones_sunat),
      xml_path = COALESCE(NULLIF(p_resultado->>'xml_path', ''), xml_path),
      cdr_path = COALESCE(NULLIF(p_resultado->>'cdr_path', ''), cdr_path),
      pdf_path = COALESCE(NULLIF(p_resultado->>'pdf_path', ''), pdf_path),
      hash_documento = COALESCE(NULLIF(p_resultado->>'hash_documento', ''), hash_documento),
      ambiente_emision = COALESCE(NULLIF(p_resultado->>'ambiente_emision', ''), ambiente_emision),
      es_prueba = COALESCE(NULLIF(p_resultado->>'es_prueba', '')::boolean, es_prueba),
      ultimo_http_status = v_codigo_http,
      ultimo_error_tipo = CASE WHEN v_estado IN ('aceptado', 'xml_validado_prueba') THEN NULL
        ELSE COALESCE(NULLIF(p_resultado->>'error_tipo', ''), ultimo_error_tipo) END,
      enviado_at = CASE WHEN v_estado IN ('ticket_pendiente', 'aceptado', 'rechazado', 'resultado_incierto')
        AND COALESCE(NULLIF(p_resultado->>'ambiente_emision', ''), ambiente_emision) = 'produccion'
        THEN COALESCE(enviado_at, now()) ELSE enviado_at END,
      aceptado_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now()) ELSE aceptado_at END,
      consultado_at = CASE WHEN COALESCE((p_resultado->>'fue_consulta')::boolean, false)
        THEN now() ELSE consultado_at END,
      procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
  WHERE id = p_guia_id;

  IF v_intento_id IS NOT NULL THEN
    UPDATE public.guias_remision_intentos
    SET resultado = v_estado, codigo_http = v_codigo_http,
        codigo_error = NULLIF(p_resultado->>'codigo_error', ''),
        mensaje_error = v_mensaje,
        payload_json = COALESCE(p_resultado->'payload_json', payload_json),
        respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
        fecha_fin = now(),
        duracion_ms = COALESCE(v_duracion,
          GREATEST(0, floor(extract(epoch FROM (now() - fecha_inicio)) * 1000)::integer))
    WHERE id = v_intento_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'guia_id', p_guia_id, 'estado', v_estado);
END;
$function$
