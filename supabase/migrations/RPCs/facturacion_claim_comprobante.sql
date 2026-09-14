CREATE OR REPLACE FUNCTION public.facturacion_claim_comprobante(p_comprobante_id uuid, p_usuario_id uuid, p_accion text DEFAULT 'emitir'::text, p_forzar boolean DEFAULT false, p_sistema boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_comp record;
  v_token uuid := gen_random_uuid();
  v_numero_intento integer;
  v_intento_id uuid;
  v_accion text := lower(trim(COALESCE(p_accion, 'emitir')));
  v_es_admin boolean := false;
BEGIN
  IF p_comprobante_id IS NULL THEN
    RAISE EXCEPTION 'comprobante_id es obligatorio';
  END IF;
  IF v_accion NOT IN ('emitir', 'reintentar', 'consultar') THEN
    RAISE EXCEPTION 'Acción de facturación inválida: %', v_accion;
  END IF;

  IF NOT COALESCE(p_sistema, false) THEN
    SELECT e.rol = 'admin'
    INTO v_es_admin
    FROM public.empleados e
    WHERE e.auth_id = p_usuario_id
      AND COALESCE(e.activo, false) = true
      AND e.rol IN ('admin', 'operador')
    LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Rol no autorizado para procesar comprobantes';
    END IF;
  END IF;

  IF COALESCE(p_forzar, false) AND (COALESCE(p_sistema, false) OR NOT v_es_admin) THEN
    RAISE EXCEPTION 'Solo un administrador puede forzar un reintento';
  END IF;

  SELECT ce.*, v.saldo AS venta_saldo, v.estado AS venta_estado,
         v.tipo_comprobante_solicitado
  INTO v_comp
  FROM public.comprobantes_electronicos ce
  JOIN public.ventas v ON v.id = ce.venta_id
  WHERE ce.id = p_comprobante_id
  FOR UPDATE OF ce, v;

  IF NOT FOUND THEN RAISE EXCEPTION 'Comprobante no encontrado'; END IF;

  IF lower(COALESCE(v_comp.tipo_documento_sunat, '')) NOT IN ('factura', 'boleta') THEN
    RAISE EXCEPTION 'El registro no corresponde a factura o boleta';
  END IF;

  IF COALESCE(v_comp.venta_saldo, 0) > 0.01
     OR lower(COALESCE(v_comp.venta_estado, '')) <> 'pagado' THEN
    RAISE EXCEPTION 'Las facturas y boletas electrónicas solo pueden emitirse al contado';
  END IF;

  IF lower(COALESCE(v_comp.tipo_comprobante_solicitado, ''))
     <> lower(COALESCE(v_comp.tipo_documento_sunat, '')) THEN
    RAISE EXCEPTION 'El tipo solicitado por la venta no coincide con el comprobante';
  END IF;

  IF v_comp.estado = 'aceptado' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'aceptado',
      'comprobante_id', v_comp.id, 'mensaje', 'El comprobante ya fue aceptado');
  END IF;

  IF v_comp.estado = 'procesando'
     AND v_comp.bloqueo_expira_at IS NOT NULL
     AND v_comp.bloqueo_expira_at > now() THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'procesando',
      'comprobante_id', v_comp.id, 'mensaje', 'El comprobante ya está siendo procesado');
  END IF;

  -- Un worker caído después de iniciar el envío puede haber llegado a SUNAT.
  IF v_comp.estado = 'procesando'
     AND (v_comp.bloqueo_expira_at IS NULL OR v_comp.bloqueo_expira_at <= now())
     AND v_accion <> 'consultar' THEN
    UPDATE public.comprobantes_electronicos
    SET estado = 'resultado_incierto',
        procesando_at = NULL,
        bloqueo_token = NULL,
        bloqueo_expira_at = NULL,
        ultimo_error_tipo = 'bloqueo_vencido_resultado_incierto',
        descripcion_sunat = COALESCE(
          descripcion_sunat,
          'El proceso anterior quedó interrumpido. Consulte SUNAT antes de reenviar.'
        )
    WHERE id = p_comprobante_id;
    UPDATE public.ventas SET estado_facturacion = 'resultado_incierto'
    WHERE id = v_comp.venta_id;
    RETURN jsonb_build_object('claimed', false, 'estado', 'resultado_incierto',
      'mensaje', 'El bloqueo venció con resultado desconocido. Debe consultarse antes de reenviar.');
  END IF;

  IF v_comp.estado = 'resultado_incierto' AND v_accion <> 'consultar' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'resultado_incierto',
      'mensaje', 'El resultado es incierto. Consulte o reconcilie el documento antes de habilitar un reintento.');
  END IF;

  IF v_comp.ticket_sunat IS NOT NULL AND v_accion <> 'consultar' THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'ticket_pendiente',
      'mensaje', 'El comprobante ya tiene ticket. Debe consultarse, no reenviarse.');
  END IF;

  IF v_comp.estado = 'rechazado' AND v_accion <> 'consultar'
     AND NOT COALESCE(p_forzar, false) THEN
    RETURN jsonb_build_object('claimed', false, 'estado', 'rechazado',
      'mensaje', COALESCE(v_comp.descripcion_sunat,
        'El comprobante fue rechazado y requiere revisión'));
  END IF;

  IF v_accion = 'consultar' THEN
    IF v_comp.estado NOT IN (
      'pendiente', 'pendiente_envio', 'pendiente_reintento', 'procesando',
      'resultado_incierto', 'ticket_pendiente', 'rechazado'
    ) THEN
      RAISE EXCEPTION 'Estado no consultable: %', v_comp.estado;
    END IF;
  ELSIF v_comp.estado NOT IN (
    'pendiente', 'pendiente_envio', 'pendiente_reintento', 'procesando', 'rechazado'
  ) THEN
    RAISE EXCEPTION 'Estado no procesable: %', v_comp.estado;
  END IF;

  v_numero_intento := COALESCE(v_comp.numero_reintentos, 0) + 1;

  UPDATE public.comprobantes_electronicos
  SET estado = 'procesando', numero_reintentos = v_numero_intento,
      ultimo_intento_at = now(), procesando_at = now(),
      bloqueo_token = v_token, bloqueo_expira_at = now() + interval '3 minutes',
      ultimo_intento_por = p_usuario_id,
      ultimo_error_tipo = NULL, ultimo_http_status = NULL
  WHERE id = p_comprobante_id;

  UPDATE public.ventas SET estado_facturacion = 'procesando'
  WHERE id = v_comp.venta_id;

  INSERT INTO public.facturacion_intentos(
    comprobante_id, numero_intento, resultado, accion,
    usuario_id, lock_token, fecha_inicio
  ) VALUES (
    p_comprobante_id, v_numero_intento, 'procesando', v_accion,
    p_usuario_id, v_token, now()
  ) RETURNING id INTO v_intento_id;

  RETURN jsonb_build_object(
    'claimed', true, 'estado', 'procesando',
    'estado_anterior', v_comp.estado,
    'comprobante_id', p_comprobante_id, 'venta_id', v_comp.venta_id,
    'bloqueo_token', v_token, 'intento_id', v_intento_id,
    'numero_intento', v_numero_intento
  );
END;
$function$