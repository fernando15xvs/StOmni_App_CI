CREATE OR REPLACE FUNCTION public.nota_credito_claim(p_nota_credito_id uuid, p_usuario_id uuid, p_accion text DEFAULT 'emitir'::text, p_forzar boolean DEFAULT false, p_sistema boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_nota record;
  v_accion text := LOWER(TRIM(COALESCE(p_accion, 'emitir')));
  v_token uuid := gen_random_uuid();
  v_numero integer;
  v_intento_id uuid;
  v_total_original numeric(14,2);
  v_total_otros numeric(14,2);
  v_det_check record;
  v_cantidad_otros integer;
  v_es_admin boolean := false;
BEGIN
  IF v_accion NOT IN ('emitir', 'reintentar') THEN
    RAISE EXCEPTION 'Acción inválida: %', v_accion;
  END IF;

  IF NOT COALESCE(p_sistema, false) THEN
    IF p_usuario_id IS NULL THEN
      RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    SELECT e.rol = 'admin'
    INTO v_es_admin
    FROM public.empleados AS e
    WHERE e.auth_id = p_usuario_id
      AND COALESCE(e.activo, false) = true
      AND e.rol IN ('admin', 'operador')
    LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Rol no autorizado para notas de crédito';
    END IF;
  END IF;

  SELECT *
  INTO v_nota
  FROM public.notas_credito
  WHERE id = p_nota_credito_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nota de crédito no encontrada';
  END IF;

  IF v_nota.estado = 'aceptado' THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'aceptado',
      'mensaje', 'La nota de crédito ya fue aceptada'
    );
  END IF;

  IF v_nota.estado = 'procesando'
     AND v_nota.bloqueo_expira_at IS NOT NULL
     AND v_nota.bloqueo_expira_at > now() THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'procesando',
      'mensaje', 'La nota ya está siendo procesada'
    );
  END IF;

  IF v_nota.estado = 'procesando'
     AND (v_nota.bloqueo_expira_at IS NULL OR v_nota.bloqueo_expira_at <= now()) THEN
    UPDATE public.notas_credito
    SET estado = 'resultado_incierto',
        procesando_at = NULL,
        bloqueo_token = NULL,
        bloqueo_expira_at = NULL,
        ultimo_error_tipo = 'bloqueo_vencido_resultado_incierto',
        descripcion_sunat = COALESCE(
          descripcion_sunat,
          'El proceso anterior quedó interrumpido. Reconcilie la nota antes de reenviar.'
        )
    WHERE id = p_nota_credito_id;

    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'resultado_incierto',
      'mensaje', 'El bloqueo venció con resultado desconocido. La nota debe reconciliarse.'
    );
  END IF;

  IF v_nota.estado = 'resultado_incierto' THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'resultado_incierto',
      'mensaje', COALESCE(
        v_nota.descripcion_sunat,
        'El resultado remoto es incierto. Un administrador debe reconciliar la nota antes de habilitar otro intento.'
      )
    );
  END IF;

  IF v_nota.estado = 'rechazado' AND NOT COALESCE(p_forzar, false) THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'rechazado',
      'mensaje', COALESCE(
        v_nota.descripcion_sunat,
        'La nota fue rechazada y requiere revisión'
      )
    );
  END IF;

  IF v_nota.estado = 'rechazado'
     AND COALESCE(p_forzar, false)
     AND (COALESCE(p_sistema, false) OR NOT v_es_admin) THEN
    RAISE EXCEPTION 'Solo un administrador puede forzar una nota rechazada';
  END IF;

  -- Antes de forzar una nota rechazada o incierta volvemos a validar que
  -- otras notas posteriores no hayan consumido el saldo o las cantidades.
  IF v_nota.estado = 'rechazado'
     AND COALESCE(p_forzar, false) THEN
    IF v_nota.afecta_dinero = true THEN
      SELECT
        ce.total,
        COALESCE(SUM(nc.total), 0)
      INTO v_total_original, v_total_otros
      FROM public.comprobantes_electronicos AS ce
      LEFT JOIN public.notas_credito AS nc
        ON nc.comprobante_id = ce.id
       AND nc.id <> v_nota.id
       AND nc.afecta_dinero = true
       AND nc.estado IN (
         'pendiente_envio',
         'procesando',
         'pendiente_reintento',
         'resultado_incierto',
         'aceptado'
       )
      WHERE ce.id = v_nota.comprobante_id
      GROUP BY ce.total;

      IF COALESCE(v_total_otros, 0) + COALESCE(v_nota.total, 0)
          > COALESCE(v_total_original, 0) + 0.02 THEN
        RAISE EXCEPTION
          'No se puede reintentar: otras notas consumieron el saldo tributario disponible';
      END IF;
    END IF;

    IF v_nota.afecta_stock = true THEN
      FOR v_det_check IN
        SELECT ncd.detalle_venta_id, ncd.cantidad_visual, dv.cantidad
        FROM public.notas_credito_detalles AS ncd
        JOIN public.detalle_ventas AS dv ON dv.id = ncd.detalle_venta_id
        WHERE ncd.nota_credito_id = v_nota.id
          AND ncd.detalle_venta_id IS NOT NULL
      LOOP
        SELECT COALESCE(SUM(ncd2.cantidad_visual), 0)::integer
        INTO v_cantidad_otros
        FROM public.notas_credito_detalles AS ncd2
        JOIN public.notas_credito AS nc2 ON nc2.id = ncd2.nota_credito_id
        WHERE ncd2.detalle_venta_id = v_det_check.detalle_venta_id
          AND nc2.id <> v_nota.id
          AND nc2.afecta_stock = true
          AND nc2.estado IN (
            'pendiente_envio',
            'procesando',
            'pendiente_reintento',
            'resultado_incierto',
            'aceptado'
          );

        IF COALESCE(v_cantidad_otros, 0) + v_det_check.cantidad_visual
            > v_det_check.cantidad THEN
          RAISE EXCEPTION
            'No se puede reintentar: otra nota consumió la cantidad disponible del detalle %',
            v_det_check.detalle_venta_id;
        END IF;
      END LOOP;
    END IF;
  END IF;

  IF v_nota.estado NOT IN (
    'pendiente_envio',
    'pendiente_reintento',
    'procesando',
    'rechazado'
  ) THEN
    RAISE EXCEPTION 'Estado no procesable: %', v_nota.estado;
  END IF;

  v_numero := COALESCE(v_nota.numero_reintentos, 0) + 1;

  UPDATE public.notas_credito
  SET
    estado = 'procesando',
    numero_reintentos = v_numero,
    ultimo_intento_at = now(),
    procesando_at = now(),
    bloqueo_token = v_token,
    bloqueo_expira_at = now() + interval '3 minutes',
    ultimo_intento_por = p_usuario_id,
    ultimo_error_tipo = NULL,
    ultimo_http_status = NULL
  WHERE id = p_nota_credito_id;

  INSERT INTO public.notas_credito_intentos(
    nota_credito_id,
    numero_intento,
    accion,
    resultado,
    usuario_id,
    lock_token,
    fecha_inicio
  )
  VALUES (
    p_nota_credito_id,
    v_numero,
    v_accion,
    'procesando',
    p_usuario_id,
    v_token,
    now()
  )
  RETURNING id INTO v_intento_id;

  RETURN jsonb_build_object(
    'claimed', true,
    'estado', 'procesando',
    'nota_credito_id', p_nota_credito_id,
    'bloqueo_token', v_token,
    'intento_id', v_intento_id,
    'numero_intento', v_numero
  );
END;
$function$
