CREATE OR REPLACE FUNCTION public.resolver_resultado_incierto_v1(p_tipo_documento text, p_documento_id uuid, p_decision text, p_motivo text, p_referencia_externa text, p_usuario_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_tipo text := lower(trim(COALESCE(p_tipo_documento, '')));
  v_decision text := lower(trim(COALESCE(p_decision, '')));
  v_motivo text := trim(COALESCE(p_motivo, ''));
  v_estado text;
  v_ticket text;
  v_nuevo_estado text;
  v_venta_id bigint;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.empleados e
    WHERE e.auth_id = p_usuario_id
      AND COALESCE(e.activo, false) = true
      AND e.rol = 'admin'
  ) THEN
    RAISE EXCEPTION 'Solo un administrador puede resolver resultados inciertos';
  END IF;

  IF v_tipo NOT IN ('comprobante', 'nota_credito', 'guia', 'proceso') THEN
    RAISE EXCEPTION 'Tipo documental inválido';
  END IF;
  IF v_decision NOT IN ('habilitar_reintento', 'mantener_incierto') THEN
    RAISE EXCEPTION 'Decisión inválida';
  END IF;
  IF char_length(v_motivo) < 10 OR char_length(v_motivo) > 500 THEN
    RAISE EXCEPTION 'El motivo debe tener entre 10 y 500 caracteres';
  END IF;

  IF v_tipo = 'comprobante' THEN
    SELECT estado, ticket_sunat, venta_id INTO v_estado, v_ticket, v_venta_id
    FROM public.comprobantes_electronicos
    WHERE id = p_documento_id FOR UPDATE;
  ELSIF v_tipo = 'nota_credito' THEN
    SELECT estado, ticket_sunat, venta_id INTO v_estado, v_ticket, v_venta_id
    FROM public.notas_credito
    WHERE id = p_documento_id FOR UPDATE;
  ELSIF v_tipo = 'guia' THEN
    SELECT estado, ticket_sunat INTO v_estado, v_ticket
    FROM public.guias_remision
    WHERE id = p_documento_id FOR UPDATE;
  ELSE
    SELECT estado, ticket_sunat INTO v_estado, v_ticket
    FROM public.procesos_tributarios
    WHERE id = p_documento_id FOR UPDATE;
  END IF;

  IF NOT FOUND THEN RAISE EXCEPTION 'Documento no encontrado'; END IF;
  IF v_estado <> 'resultado_incierto' THEN
    RAISE EXCEPTION 'El documento no está en resultado_incierto sino en %', v_estado;
  END IF;

  IF v_decision = 'habilitar_reintento' AND NULLIF(trim(COALESCE(v_ticket, '')), '') IS NOT NULL THEN
    RAISE EXCEPTION 'El documento tiene ticket. Debe consultarse el ticket y no habilitar un reenvío';
  END IF;

  v_nuevo_estado := CASE
    WHEN v_decision = 'habilitar_reintento' THEN 'pendiente_reintento'
    ELSE 'resultado_incierto'
  END;

  IF v_tipo = 'comprobante' THEN
    UPDATE public.comprobantes_electronicos
    SET estado = v_nuevo_estado,
        descripcion_sunat = CASE
          WHEN v_decision = 'habilitar_reintento'
            THEN 'Reintento habilitado por administrador tras verificar que el documento no fue recibido. ' || v_motivo
          ELSE COALESCE(descripcion_sunat, 'Resultado incierto') || ' Revisión: ' || v_motivo
        END,
        ultimo_error_tipo = CASE
          WHEN v_decision = 'habilitar_reintento' THEN 'reintento_habilitado_por_reconciliacion'
          ELSE 'resultado_incierto_revisado'
        END,
        procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
    WHERE id = p_documento_id;
    UPDATE public.ventas SET estado_facturacion = v_nuevo_estado
    WHERE id = v_venta_id;
  ELSIF v_tipo = 'nota_credito' THEN
    UPDATE public.notas_credito
    SET estado = v_nuevo_estado,
        descripcion_sunat = CASE
          WHEN v_decision = 'habilitar_reintento'
            THEN 'Reintento habilitado por administrador tras verificar que la nota no fue recibida. ' || v_motivo
          ELSE COALESCE(descripcion_sunat, 'Resultado incierto') || ' Revisión: ' || v_motivo
        END,
        ultimo_error_tipo = CASE
          WHEN v_decision = 'habilitar_reintento' THEN 'reintento_habilitado_por_reconciliacion'
          ELSE 'resultado_incierto_revisado'
        END,
        procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
    WHERE id = p_documento_id;
  ELSIF v_tipo = 'guia' THEN
    UPDATE public.guias_remision
    SET estado = v_nuevo_estado,
        descripcion_sunat = CASE
          WHEN v_decision = 'habilitar_reintento'
            THEN 'Reintento habilitado por administrador tras verificar que la GRE no fue recibida. ' || v_motivo
          ELSE COALESCE(descripcion_sunat, 'Resultado incierto') || ' Revisión: ' || v_motivo
        END,
        ultimo_error_tipo = CASE
          WHEN v_decision = 'habilitar_reintento' THEN 'reintento_habilitado_por_reconciliacion'
          ELSE 'resultado_incierto_revisado'
        END,
        procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
    WHERE id = p_documento_id;
  ELSE
    UPDATE public.procesos_tributarios
    SET estado = v_nuevo_estado,
        descripcion_sunat = CASE
          WHEN v_decision = 'habilitar_reintento'
            THEN 'Reintento habilitado por administrador tras verificar que el proceso no fue recibido. ' || v_motivo
          ELSE COALESCE(descripcion_sunat, 'Resultado incierto') || ' Revisión: ' || v_motivo
        END,
        ultimo_error_tipo = CASE
          WHEN v_decision = 'habilitar_reintento' THEN 'reintento_habilitado_por_reconciliacion'
          ELSE 'resultado_incierto_revisado'
        END,
        procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
    WHERE id = p_documento_id;

    UPDATE public.solicitudes_baja_tributaria
    SET estado = v_nuevo_estado
    WHERE proceso_id = p_documento_id;
    UPDATE public.comprobantes_electronicos ce
    SET estado_baja_tributaria = v_nuevo_estado
    FROM public.solicitudes_baja_tributaria s
    WHERE s.proceso_id = p_documento_id AND s.comprobante_id = ce.id;
    UPDATE public.notas_credito nc
    SET estado_baja_tributaria = v_nuevo_estado
    FROM public.solicitudes_baja_tributaria s
    WHERE s.proceso_id = p_documento_id AND s.nota_credito_id = nc.id;
  END IF;

  INSERT INTO public.documentos_tributarios_reconciliaciones(
    tipo_documento, documento_id, decision,
    estado_anterior, estado_nuevo, motivo,
    referencia_externa, realizado_por
  ) VALUES (
    v_tipo, p_documento_id, v_decision,
    v_estado, v_nuevo_estado, v_motivo,
    NULLIF(trim(COALESCE(p_referencia_externa, '')), ''), p_usuario_id
  );

  RETURN jsonb_build_object(
    'success', true,
    'tipo_documento', v_tipo,
    'documento_id', p_documento_id,
    'estado_anterior', v_estado,
    'estado', v_nuevo_estado,
    'decision', v_decision
  );
END;
$function$
