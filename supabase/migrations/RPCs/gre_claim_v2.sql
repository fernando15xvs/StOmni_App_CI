CREATE OR REPLACE FUNCTION public.gre_claim_v2(p_guia_id uuid, p_usuario_id uuid, p_accion text DEFAULT 'emitir'::text, p_forzar boolean DEFAULT false, p_sistema boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_guia public.guias_remision%ROWTYPE;
  v_bloqueo uuid := gen_random_uuid();
  v_intento_id uuid;
  v_numero integer;
  v_accion text := lower(trim(COALESCE(p_accion, 'emitir')));
  v_es_admin boolean := false;
BEGIN
  IF v_accion NOT IN ('emitir', 'reintentar', 'consultar') THEN
    RAISE EXCEPTION 'Acción GRE inválida';
  END IF;

  IF NOT COALESCE(p_sistema, false) THEN
    SELECT e.rol = 'admin' INTO v_es_admin
    FROM public.empleados e
    WHERE e.auth_id = p_usuario_id
      AND COALESCE(e.activo, false) = true
      AND e.rol IN ('admin', 'operador')
    LIMIT 1;
    IF NOT FOUND THEN RAISE EXCEPTION 'Rol no autorizado para procesar GRE'; END IF;
  END IF;

  IF COALESCE(p_forzar, false) AND (COALESCE(p_sistema, false) OR NOT v_es_admin) THEN
    RAISE EXCEPTION 'Solo un administrador puede forzar una GRE';
  END IF;

  SELECT * INTO v_guia
  FROM public.guias_remision
  WHERE id = p_guia_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Guía no encontrada'; END IF;

  IF v_guia.estado = 'borrador' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'borrador',
      'mensaje', 'Completa y prepara la guía antes de emitir.');
  END IF;
  IF v_guia.serie IS NULL OR v_guia.correlativo IS NULL THEN
    RETURN jsonb_build_object('claimed', false, 'estado', v_guia.estado,
      'mensaje', 'La guía todavía no tiene serie y correlativo.');
  END IF;
  IF v_guia.estado = 'aceptado' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'aceptado',
      'mensaje', 'La guía ya fue aceptada.');
  END IF;
  IF v_guia.estado = 'xml_validado_prueba' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'xml_validado_prueba',
      'mensaje', 'La guía ya fue validada como prueba. Crea una nueva para producción.');
  END IF;

  IF v_guia.estado = 'procesando'
     AND v_guia.bloqueo_expira_at IS NOT NULL
     AND v_guia.bloqueo_expira_at > now() THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'procesando',
      'mensaje', 'La guía está siendo procesada.');
  END IF;

  IF v_guia.estado = 'procesando'
     AND (v_guia.bloqueo_expira_at IS NULL OR v_guia.bloqueo_expira_at <= now())
     AND v_accion <> 'consultar' THEN
    UPDATE public.guias_remision
    SET estado = 'resultado_incierto', procesando_at = NULL,
        bloqueo_token = NULL, bloqueo_expira_at = NULL,
        ultimo_error_tipo = 'bloqueo_vencido_resultado_incierto',
        descripcion_sunat = COALESCE(descripcion_sunat,
          'El proceso anterior quedó interrumpido. Debe reconciliarse antes de reenviar.')
    WHERE id = p_guia_id;
    RETURN jsonb_build_object('claimed', false, 'estado', 'resultado_incierto',
      'mensaje', 'El bloqueo venció con resultado desconocido. No reenvíe la GRE.');
  END IF;

  IF v_guia.estado = 'resultado_incierto' AND v_accion <> 'consultar' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'resultado_incierto',
      'mensaje', 'La GRE tiene resultado incierto y requiere reconciliación administrativa.');
  END IF;

  IF v_guia.ticket_sunat IS NOT NULL AND v_accion <> 'consultar' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'ticket_pendiente',
      'mensaje', 'La GRE tiene ticket y solo debe consultarse.');
  END IF;

  IF v_guia.estado = 'rechazado' AND v_accion <> 'consultar'
     AND NOT COALESCE(p_forzar, false) THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'rechazado',
      'mensaje', COALESCE(v_guia.descripcion_sunat,
        'Corrige los datos antes de volver a emitir.'));
  END IF;

  IF v_accion = 'consultar' THEN
    IF v_guia.ticket_sunat IS NULL THEN
      RETURN jsonb_build_object('claimed', false, 'estado', v_guia.estado,
        'mensaje', 'La GRE no tiene ticket. Si el envío fue incierto, debe reconciliarse manualmente.');
    END IF;
  ELSIF v_guia.estado NOT IN (
    'pendiente_envio', 'pendiente_reintento', 'procesando', 'rechazado'
  ) THEN
    RAISE EXCEPTION 'Estado GRE no procesable: %', v_guia.estado;
  END IF;

  SELECT COALESCE(max(numero_intento), 0) + 1 INTO v_numero
  FROM public.guias_remision_intentos
  WHERE guia_id = p_guia_id;

  INSERT INTO public.guias_remision_intentos(
    guia_id, numero_intento, accion, resultado, usuario_id, lock_token
  ) VALUES (
    p_guia_id, v_numero, v_accion, 'procesando', p_usuario_id, v_bloqueo
  ) RETURNING id INTO v_intento_id;

  UPDATE public.guias_remision
  SET estado = 'procesando', procesando_at = now(),
      bloqueo_token = v_bloqueo, bloqueo_expira_at = now() + interval '3 minutes',
      ultimo_intento_at = now(), ultimo_intento_por = p_usuario_id,
      ultimo_error_tipo = NULL, ultimo_http_status = NULL
  WHERE id = p_guia_id;

  RETURN jsonb_build_object(
    'claimed', true, 'guia_id', p_guia_id,
    'estado_anterior', v_guia.estado,
    'bloqueo_token', v_bloqueo, 'intento_id', v_intento_id,
    'numero_intento', v_numero, 'ticket_sunat', v_guia.ticket_sunat
  );
END;
$function$
