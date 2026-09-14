-- F2.3/F3.7 hardening: resolver_resultado_incierto_v1 recibe documento_id desde
-- Edge. Aunque el EXECUTE es service_role-only, PostgreSQL debe exigir el tenant
-- verificado y nunca seleccionar/mutar un UUID global sin organization_id.
BEGIN;

CREATE OR REPLACE FUNCTION public.resolver_resultado_incierto_v1(
  p_tipo_documento text,
  p_documento_id uuid,
  p_decision text,
  p_motivo text,
  p_referencia_externa text,
  p_usuario_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_service_organization_id();
  v_tipo text := lower(btrim(COALESCE(p_tipo_documento, '')));
  v_decision text := lower(btrim(COALESCE(p_decision, '')));
  v_motivo text := btrim(COALESCE(p_motivo, ''));
  v_estado text;
  v_ticket text;
  v_nuevo_estado text;
  v_venta_id bigint;
BEGIN
  IF p_usuario_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.app_users au
    JOIN public.empleados e
      ON e.organization_id = au.organization_id
     AND (e.app_user_id = au.user_id OR e.auth_id = au.user_id)
    WHERE au.organization_id = v_org
      AND au.user_id = p_usuario_id
      AND au.status = 'active'
      AND au.base_role = 'admin'
      AND COALESCE(e.activo, false) = true
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Active tenant administrator required to resolve uncertain fiscal results';
  END IF;

  IF v_tipo NOT IN ('comprobante', 'nota_credito', 'guia', 'proceso') THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Tipo documental inválido';
  END IF;
  IF v_decision NOT IN ('habilitar_reintento', 'mantener_incierto') THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Decisión inválida';
  END IF;
  IF char_length(v_motivo) < 10 OR char_length(v_motivo) > 500 THEN
    RAISE EXCEPTION USING
      ERRCODE='22023',
      MESSAGE='El motivo debe tener entre 10 y 500 caracteres';
  END IF;

  IF v_tipo = 'comprobante' THEN
    SELECT estado, ticket_sunat, venta_id
    INTO v_estado, v_ticket, v_venta_id
    FROM public.comprobantes_electronicos
    WHERE organization_id = v_org
      AND id = p_documento_id
    FOR UPDATE;
  ELSIF v_tipo = 'nota_credito' THEN
    SELECT estado, ticket_sunat, venta_id
    INTO v_estado, v_ticket, v_venta_id
    FROM public.notas_credito
    WHERE organization_id = v_org
      AND id = p_documento_id
    FOR UPDATE;
  ELSIF v_tipo = 'guia' THEN
    SELECT estado, ticket_sunat
    INTO v_estado, v_ticket
    FROM public.guias_remision
    WHERE organization_id = v_org
      AND id = p_documento_id
    FOR UPDATE;
  ELSE
    SELECT estado, ticket_sunat
    INTO v_estado, v_ticket
    FROM public.procesos_tributarios
    WHERE organization_id = v_org
      AND id = p_documento_id
    FOR UPDATE;
  END IF;

  IF NOT FOUND THEN
    -- 404 lógico: no revela si el UUID existe en otra organización.
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Documento no encontrado';
  END IF;
  IF v_estado <> 'resultado_incierto' THEN
    RAISE EXCEPTION 'El documento no está en resultado_incierto sino en %', v_estado;
  END IF;

  IF v_decision = 'habilitar_reintento'
     AND NULLIF(btrim(COALESCE(v_ticket, '')), '') IS NOT NULL THEN
    RAISE EXCEPTION
      'El documento tiene ticket. Debe consultarse el ticket y no habilitar un reenvío';
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
        procesando_at = NULL,
        bloqueo_token = NULL,
        bloqueo_expira_at = NULL
    WHERE organization_id = v_org
      AND id = p_documento_id;

    UPDATE public.ventas
    SET estado_facturacion = v_nuevo_estado
    WHERE organization_id = v_org
      AND id = v_venta_id;

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
        procesando_at = NULL,
        bloqueo_token = NULL,
        bloqueo_expira_at = NULL
    WHERE organization_id = v_org
      AND id = p_documento_id;

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
        procesando_at = NULL,
        bloqueo_token = NULL,
        bloqueo_expira_at = NULL
    WHERE organization_id = v_org
      AND id = p_documento_id;

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
        procesando_at = NULL,
        bloqueo_token = NULL,
        bloqueo_expira_at = NULL
    WHERE organization_id = v_org
      AND id = p_documento_id;

    UPDATE public.solicitudes_baja_tributaria
    SET estado = v_nuevo_estado
    WHERE organization_id = v_org
      AND proceso_id = p_documento_id;

    UPDATE public.comprobantes_electronicos ce
    SET estado_baja_tributaria = v_nuevo_estado
    FROM public.solicitudes_baja_tributaria s
    WHERE s.organization_id = v_org
      AND s.proceso_id = p_documento_id
      AND s.comprobante_id = ce.id
      AND ce.organization_id = v_org;

    UPDATE public.notas_credito nc
    SET estado_baja_tributaria = v_nuevo_estado
    FROM public.solicitudes_baja_tributaria s
    WHERE s.organization_id = v_org
      AND s.proceso_id = p_documento_id
      AND s.nota_credito_id = nc.id
      AND nc.organization_id = v_org;
  END IF;

  INSERT INTO public.documentos_tributarios_reconciliaciones(
    organization_id,
    tipo_documento,
    documento_id,
    decision,
    estado_anterior,
    estado_nuevo,
    motivo,
    referencia_externa,
    realizado_por
  ) VALUES (
    v_org,
    v_tipo,
    p_documento_id,
    v_decision,
    v_estado,
    v_nuevo_estado,
    v_motivo,
    NULLIF(btrim(COALESCE(p_referencia_externa, '')), ''),
    p_usuario_id
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
$$;

REVOKE ALL ON FUNCTION public.resolver_resultado_incierto_v1(text,uuid,text,text,text,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.resolver_resultado_incierto_v1(text,uuid,text,text,text,uuid)
  TO service_role;

COMMENT ON FUNCTION public.resolver_resultado_incierto_v1(text,uuid,text,text,text,uuid) IS
  'Resuelve resultado_incierto sólo dentro del tenant verificado por Edge/service_role; valida admin en app_users y escribe reconciliación con organization_id explícito.';

COMMIT;
