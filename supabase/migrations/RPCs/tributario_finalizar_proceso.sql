CREATE OR REPLACE FUNCTION public.tributario_finalizar_proceso(p_proceso_id uuid, p_bloqueo_token uuid, p_estado text, p_resultado jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_proceso record;
  v_estado text := lower(trim(COALESCE(p_estado, '')));
  v_intento_id uuid;
  v_codigo_http integer;
  v_duracion integer;
  v_mensaje text;
  v_det record;
  v_stock_result jsonb;
BEGIN
  IF v_estado NOT IN (
    'ticket_pendiente', 'aceptado', 'rechazado',
    'pendiente_reintento', 'resultado_incierto'
  ) THEN
    RAISE EXCEPTION 'Estado final inválido: %', v_estado;
  END IF;

  SELECT * INTO v_proceso
  FROM public.procesos_tributarios
  WHERE id = p_proceso_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proceso tributario no encontrado'; END IF;

  IF v_proceso.estado = 'aceptado' AND v_estado <> 'aceptado' THEN
    RETURN jsonb_build_object('success', true, 'estado', 'aceptado',
      'idempotent', true, 'ignored_state', v_estado, 'proceso_id', p_proceso_id);
  END IF;

  IF v_proceso.bloqueo_token IS DISTINCT FROM p_bloqueo_token THEN
    IF v_proceso.estado = 'aceptado' AND v_estado = 'aceptado' THEN
      RETURN jsonb_build_object('success', true, 'estado', 'aceptado',
        'idempotent', true, 'proceso_id', p_proceso_id);
    END IF;
    RAISE EXCEPTION 'El bloqueo del proceso ya no es válido';
  END IF;

  v_intento_id := NULLIF(p_resultado->>'intento_id', '')::uuid;
  v_codigo_http := NULLIF(p_resultado->>'codigo_http', '')::integer;
  v_duracion := NULLIF(p_resultado->>'duracion_ms', '')::integer;
  v_mensaje := NULLIF(trim(p_resultado->>'mensaje_error'), '');

  UPDATE public.procesos_tributarios
  SET estado = v_estado,
      payload_json = COALESCE(p_resultado->'payload_json', payload_json),
      respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
      xml_path = COALESCE(NULLIF(p_resultado->>'xml_path', ''), xml_path),
      cdr_path = COALESCE(NULLIF(p_resultado->>'cdr_path', ''), cdr_path),
      pdf_path = COALESCE(NULLIF(p_resultado->>'pdf_path', ''), pdf_path),
      hash_documento = COALESCE(NULLIF(p_resultado->>'hash_documento', ''), hash_documento),
      ticket_sunat = COALESCE(NULLIF(p_resultado->>'ticket_sunat', ''), ticket_sunat),
      codigo_sunat = COALESCE(NULLIF(p_resultado->>'codigo_sunat', ''), codigo_sunat),
      descripcion_sunat = COALESCE(NULLIF(p_resultado->>'descripcion_sunat', ''), v_mensaje, descripcion_sunat),
      observaciones_sunat = COALESCE(p_resultado->'observaciones_sunat', observaciones_sunat),
      ultimo_error_tipo = CASE WHEN v_estado = 'aceptado' THEN NULL
        ELSE COALESCE(NULLIF(p_resultado->>'error_tipo', ''), ultimo_error_tipo) END,
      ultimo_http_status = v_codigo_http,
      enviado_at = CASE WHEN v_estado IN ('ticket_pendiente', 'aceptado', 'rechazado', 'resultado_incierto')
        THEN COALESCE(enviado_at, now()) ELSE enviado_at END,
      consultado_at = CASE WHEN COALESCE((p_resultado->>'fue_consulta')::boolean, false)
        THEN now() ELSE consultado_at END,
      aceptado_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now()) ELSE aceptado_at END,
      pdf_generado_at = CASE WHEN NULLIF(p_resultado->>'pdf_path', '') IS NOT NULL
        THEN now() ELSE pdf_generado_at END,
      procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
  WHERE id = p_proceso_id;

  IF v_intento_id IS NOT NULL THEN
    UPDATE public.procesos_tributarios_intentos
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

  UPDATE public.solicitudes_baja_tributaria
  SET estado = CASE v_estado
      WHEN 'ticket_pendiente' THEN 'ticket_pendiente'
      WHEN 'pendiente_reintento' THEN 'pendiente_reintento'
      WHEN 'resultado_incierto' THEN 'resultado_incierto'
      WHEN 'aceptado' THEN 'aceptada'
      WHEN 'rechazado' THEN 'rechazada'
      ELSE estado END,
      aceptado_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now()) ELSE aceptado_at END
  WHERE proceso_id = p_proceso_id;

  UPDATE public.comprobantes_electronicos ce
  SET estado_baja_tributaria = CASE v_estado
      WHEN 'ticket_pendiente' THEN 'ticket_pendiente'
      WHEN 'pendiente_reintento' THEN 'pendiente_reintento'
      WHEN 'resultado_incierto' THEN 'resultado_incierto'
      WHEN 'aceptado' THEN 'aceptada'
      WHEN 'rechazado' THEN 'rechazada'
      ELSE ce.estado_baja_tributaria END,
      baja_aceptada_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(ce.baja_aceptada_at, now()) ELSE ce.baja_aceptada_at END
  FROM public.solicitudes_baja_tributaria s
  WHERE s.proceso_id = p_proceso_id AND s.comprobante_id = ce.id;

  UPDATE public.notas_credito nc
  SET estado_baja_tributaria = CASE v_estado
      WHEN 'ticket_pendiente' THEN 'ticket_pendiente'
      WHEN 'pendiente_reintento' THEN 'pendiente_reintento'
      WHEN 'resultado_incierto' THEN 'resultado_incierto'
      WHEN 'aceptado' THEN 'aceptada'
      WHEN 'rechazado' THEN 'rechazada'
      ELSE nc.estado_baja_tributaria END,
      baja_aceptada_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(nc.baja_aceptada_at, now()) ELSE nc.baja_aceptada_at END
  FROM public.solicitudes_baja_tributaria s
  WHERE s.proceso_id = p_proceso_id AND s.nota_credito_id = nc.id;

  IF v_estado = 'aceptado' THEN
    UPDATE public.ventas v
    SET estado_tributario = 'baja_tributaria'
    FROM public.solicitudes_baja_tributaria s
    WHERE s.proceso_id = p_proceso_id
      AND s.tipo_origen = 'comprobante'
      AND s.venta_id = v.id;

    FOR v_det IN
      SELECT DISTINCT d.nota_credito_id, d.venta_id
      FROM public.procesos_tributarios_detalles d
      WHERE d.proceso_id = p_proceso_id AND d.nota_credito_id IS NOT NULL
    LOOP
      v_stock_result := public._revertir_stock_nota_credito_por_baja(v_det.nota_credito_id);
      PERFORM public.recalcular_estado_tributario_venta(v_det.venta_id);
    END LOOP;
  END IF;

  RETURN jsonb_build_object('success', true, 'estado', v_estado,
    'proceso_id', p_proceso_id, 'stock_resultado', v_stock_result);
END;
$function$
