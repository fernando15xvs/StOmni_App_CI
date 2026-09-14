CREATE OR REPLACE FUNCTION public.tributario_claim_proceso(p_proceso_id uuid, p_usuario_id uuid, p_accion text DEFAULT 'emitir'::text, p_forzar boolean DEFAULT false, p_sistema boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_proceso record;
  v_accion text := lower(trim(COALESCE(p_accion, 'emitir')));
  v_token uuid := gen_random_uuid();
  v_numero integer;
  v_intento_id uuid;
BEGIN
  IF v_accion NOT IN ('emitir', 'reintentar', 'consultar') THEN
    RAISE EXCEPTION 'Acción tributaria inválida';
  END IF;

  -- En la primera salida todos los procesos son manuales y administrativos.
  IF COALESCE(p_sistema, false) THEN
    RAISE EXCEPTION 'El procesamiento tributario automático está desactivado';
  END IF;

  IF p_usuario_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.empleados e
    WHERE e.auth_id = p_usuario_id
      AND COALESCE(e.activo, false) = true
      AND e.rol = 'admin'
  ) THEN
    RAISE EXCEPTION 'Solo un administrador puede procesar resúmenes y bajas';
  END IF;

  SELECT * INTO v_proceso
  FROM public.procesos_tributarios
  WHERE id = p_proceso_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proceso tributario no encontrado'; END IF;

  IF v_proceso.estado = 'aceptado' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'aceptado',
      'idempotent', true, 'mensaje', 'El proceso ya fue aceptado');
  END IF;

  IF v_proceso.estado = 'procesando'
     AND v_proceso.bloqueo_expira_at IS NOT NULL
     AND v_proceso.bloqueo_expira_at > now() THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'procesando',
      'mensaje', 'Otro proceso continúa trabajando');
  END IF;

  IF v_proceso.estado = 'procesando'
     AND (v_proceso.bloqueo_expira_at IS NULL OR v_proceso.bloqueo_expira_at <= now())
     AND v_accion <> 'consultar' THEN
    UPDATE public.procesos_tributarios
    SET estado = 'resultado_incierto', procesando_at = NULL,
        bloqueo_token = NULL, bloqueo_expira_at = NULL,
        ultimo_error_tipo = 'bloqueo_vencido_resultado_incierto',
        descripcion_sunat = COALESCE(descripcion_sunat,
          'El envío anterior quedó interrumpido. Debe reconciliarse antes de reenviar.')
    WHERE id = p_proceso_id;

    UPDATE public.solicitudes_baja_tributaria
    SET estado = 'resultado_incierto'
    WHERE proceso_id = p_proceso_id;

    RETURN jsonb_build_object('claimed', false, 'estado', 'resultado_incierto',
      'mensaje', 'El bloqueo venció con resultado desconocido. No reenvíe el proceso.');
  END IF;

  IF v_proceso.estado = 'resultado_incierto' AND v_accion <> 'consultar' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'resultado_incierto',
      'mensaje', 'El proceso debe reconciliarse antes de habilitar otro envío.');
  END IF;

  IF v_accion = 'consultar' AND v_proceso.ticket_sunat IS NULL THEN
    RETURN jsonb_build_object('claimed', false, 'estado', v_proceso.estado,
      'mensaje', 'El proceso no tiene ticket. Debe reconciliarse manualmente.');
  END IF;

  IF v_accion IN ('emitir', 'reintentar') AND v_proceso.ticket_sunat IS NOT NULL THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'ticket_pendiente',
      'mensaje', 'El proceso ya tiene ticket. Debe consultarse, no reenviarse.');
  END IF;

  IF v_proceso.estado = 'rechazado' AND v_accion <> 'consultar'
     AND NOT COALESCE(p_forzar, false) THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'rechazado',
      'mensaje', 'El proceso fue rechazado. Revise el error antes de forzar.');
  END IF;

  IF v_accion = 'consultar' THEN
    IF v_proceso.estado NOT IN ('ticket_pendiente', 'resultado_incierto', 'rechazado', 'procesando') THEN
      RAISE EXCEPTION 'Estado no consultable: %', v_proceso.estado;
    END IF;
  ELSIF v_proceso.estado NOT IN ('pendiente_envio', 'pendiente_reintento', 'procesando', 'rechazado') THEN
    RAISE EXCEPTION 'Estado no procesable: %', v_proceso.estado;
  END IF;

  v_numero := COALESCE(v_proceso.numero_reintentos, 0) + 1;
  UPDATE public.procesos_tributarios
  SET estado = 'procesando', numero_reintentos = v_numero,
      ultimo_intento_at = now(), procesando_at = now(),
      bloqueo_token = v_token, bloqueo_expira_at = now() + interval '3 minutes',
      ultimo_intento_por = p_usuario_id,
      ultimo_error_tipo = NULL, ultimo_http_status = NULL
  WHERE id = p_proceso_id;

  INSERT INTO public.procesos_tributarios_intentos(
    proceso_id, numero_intento, accion, resultado,
    usuario_id, lock_token, fecha_inicio
  ) VALUES (
    p_proceso_id, v_numero, v_accion, 'procesando',
    p_usuario_id, v_token, now()
  ) RETURNING id INTO v_intento_id;

  RETURN jsonb_build_object(
    'claimed', true, 'estado', 'procesando',
    'estado_anterior', v_proceso.estado,
    'proceso_id', p_proceso_id, 'bloqueo_token', v_token,
    'intento_id', v_intento_id, 'numero_intento', v_numero,
    'accion', v_accion
  );
END;
$function$
