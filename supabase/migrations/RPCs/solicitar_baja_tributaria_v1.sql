CREATE OR REPLACE FUNCTION public.solicitar_baja_tributaria_v1(p_request_id uuid, p_tipo_origen text, p_origen_id uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_tipo_origen text := lower(trim(COALESCE(p_tipo_origen, '')));
  v_motivo text := upper(trim(COALESCE(p_motivo, '')));
  v_existing record;
  v_source record;
  v_solicitud_id uuid;
  v_tipo_proceso text;
  v_tipo_doc text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND lower(COALESCE(e.rol, '')) IN (
        'admin'
      )
  ) THEN
    RAISE EXCEPTION 'Solo un administrador activo puede solicitar una baja tributaria';
  END IF;

  IF p_request_id IS NULL OR p_origen_id IS NULL THEN
    RAISE EXCEPTION 'request_id y origen_id son obligatorios';
  END IF;

  IF v_tipo_origen NOT IN ('comprobante', 'nota_credito') THEN
    RAISE EXCEPTION 'Tipo de origen inválido';
  END IF;

  IF length(v_motivo) < 3 OR length(v_motivo) > 250 THEN
    RAISE EXCEPTION 'El motivo debe tener entre 3 y 250 caracteres';
  END IF;

  SELECT * INTO v_existing
  FROM public.solicitudes_baja_tributaria
  WHERE request_id = p_request_id;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'idempotent', true,
      'solicitud_id', v_existing.id,
      'estado', v_existing.estado,
      'tipo_proceso', v_existing.tipo_proceso
    );
  END IF;

  IF v_tipo_origen = 'comprobante' THEN
    SELECT
      ce.id,
      ce.venta_id,
      ce.tipo_documento_sunat,
      ce.serie,
      ce.correlativo,
      ce.fecha_emision,
      ce.moneda,
      ce.base_imponible,
      ce.igv,
      ce.total,
      ce.cliente_tipo_documento,
      ce.cliente_numero_documento,
      ce.estado,
      ce.estado_baja_tributaria
    INTO v_source
    FROM public.comprobantes_electronicos ce
    WHERE ce.id = p_origen_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Comprobante electrónico no encontrado';
    END IF;

    IF v_source.estado <> 'aceptado' THEN
      RAISE EXCEPTION 'Solo puede darse de baja un comprobante aceptado por SUNAT';
    END IF;

    IF COALESCE(v_source.estado_baja_tributaria, 'ninguna') <> 'ninguna' THEN
      RAISE EXCEPTION 'El comprobante ya tiene una solicitud o proceso de baja';
    END IF;

    -- Una baja del documento original exige resolver primero las notas activas.
    IF EXISTS (
      SELECT 1
      FROM public.notas_credito nc
      WHERE nc.comprobante_id = p_origen_id
        AND nc.estado = 'aceptado'
        AND COALESCE(nc.estado_baja_tributaria, 'ninguna') <> 'aceptada'
    ) THEN
      RAISE EXCEPTION 'El comprobante tiene notas de crédito activas. Da de baja primero esas notas';
    END IF;

    v_tipo_doc := CASE lower(trim(COALESCE(v_source.tipo_documento_sunat, '')))
      WHEN 'factura' THEN '01'
      WHEN '01' THEN '01'
      WHEN 'boleta' THEN '03'
      WHEN '03' THEN '03'
      ELSE NULL
    END;

    IF v_tipo_doc IS NULL THEN
      RAISE EXCEPTION 'Tipo de comprobante no admitido para baja';
    END IF;

    v_tipo_proceso := CASE
      WHEN v_tipo_doc = '03' THEN 'resumen_boletas'
      ELSE 'comunicacion_baja'
    END;

    INSERT INTO public.solicitudes_baja_tributaria(
      request_id, tipo_origen, comprobante_id, venta_id,
      tipo_proceso, tipo_doc, serie, correlativo, fecha_documento,
      motivo, moneda, base_imponible, igv, total,
      cliente_tipo, cliente_numero, creado_por
    ) VALUES (
      p_request_id, 'comprobante', p_origen_id, v_source.venta_id,
      v_tipo_proceso, v_tipo_doc, v_source.serie, v_source.correlativo,
      v_source.fecha_emision, v_motivo, COALESCE(v_source.moneda, 'PEN'),
      COALESCE(v_source.base_imponible, 0), COALESCE(v_source.igv, 0),
      COALESCE(v_source.total, 0), v_source.cliente_tipo_documento,
      v_source.cliente_numero_documento, auth.uid()
    )
    RETURNING id INTO v_solicitud_id;

    UPDATE public.comprobantes_electronicos
    SET
      estado_baja_tributaria = 'solicitada',
      solicitud_baja_id = v_solicitud_id,
      baja_motivo = v_motivo
    WHERE id = p_origen_id;

  ELSE
    SELECT
      nc.id,
      nc.venta_id,
      nc.tipo_doc_afectado,
      nc.serie,
      nc.correlativo,
      nc.fecha_emision,
      nc.moneda,
      nc.base_imponible,
      nc.igv,
      nc.total,
      nc.cliente_tipo_documento,
      nc.cliente_numero_documento,
      nc.estado,
      nc.estado_baja_tributaria
    INTO v_source
    FROM public.notas_credito nc
    WHERE nc.id = p_origen_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Nota de crédito no encontrada';
    END IF;

    IF v_source.estado <> 'aceptado' THEN
      RAISE EXCEPTION 'Solo puede darse de baja una nota aceptada por SUNAT';
    END IF;

    IF COALESCE(v_source.estado_baja_tributaria, 'ninguna') <> 'ninguna' THEN
      RAISE EXCEPTION 'La nota ya tiene una solicitud o proceso de baja';
    END IF;

    v_tipo_doc := '07';
    v_tipo_proceso := CASE
      WHEN v_source.tipo_doc_afectado = '03'
        THEN 'resumen_boletas'
      ELSE 'comunicacion_baja'
    END;

    INSERT INTO public.solicitudes_baja_tributaria(
      request_id, tipo_origen, nota_credito_id, venta_id,
      tipo_proceso, tipo_doc, serie, correlativo, fecha_documento,
      motivo, moneda, base_imponible, igv, total,
      cliente_tipo, cliente_numero, creado_por
    ) VALUES (
      p_request_id, 'nota_credito', p_origen_id, v_source.venta_id,
      v_tipo_proceso, v_tipo_doc, v_source.serie, v_source.correlativo,
      v_source.fecha_emision, v_motivo, COALESCE(v_source.moneda, 'PEN'),
      COALESCE(v_source.base_imponible, 0), COALESCE(v_source.igv, 0),
      COALESCE(v_source.total, 0), v_source.cliente_tipo_documento,
      v_source.cliente_numero_documento, auth.uid()
    )
    RETURNING id INTO v_solicitud_id;

    UPDATE public.notas_credito
    SET
      estado_baja_tributaria = 'solicitada',
      solicitud_baja_id = v_solicitud_id,
      baja_motivo = v_motivo
    WHERE id = p_origen_id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'solicitud_id', v_solicitud_id,
    'estado', 'pendiente',
    'tipo_proceso', v_tipo_proceso
  );
END;
$function$
