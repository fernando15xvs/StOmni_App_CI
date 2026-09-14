CREATE OR REPLACE FUNCTION public.listar_documentos_electronicos_v1(p_fecha_inicio timestamp with time zone, p_fecha_fin_exclusiva timestamp with time zone, p_limite integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS TABLE(categoria text, tipo_label text, id text, venta_id bigint, numero text, estado text, total numeric, tercero text, fecha_documento timestamp with time zone, descripcion_sunat text, pdf_path text, xml_path text, cdr_path text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_limite integer := LEAST(GREATEST(COALESCE(p_limite, 50), 10), 100);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND LOWER(COALESCE(e.rol, '')) IN (
        'admin', 'operador'
      )
  ) THEN
    RAISE EXCEPTION 'Empleado inactivo o rol no autorizado';
  END IF;

  IF p_fecha_inicio IS NULL OR p_fecha_fin_exclusiva IS NULL
     OR p_fecha_fin_exclusiva <= p_fecha_inicio THEN
    RAISE EXCEPTION 'Rango de fechas inválido';
  END IF;

  RETURN QUERY
  WITH documentos AS (
    SELECT
      CASE
        WHEN LOWER(COALESCE(ce.tipo_documento_sunat, '')) IN ('factura', '01')
          THEN 'factura'
        ELSE 'boleta'
      END::text AS categoria,
      CASE
        WHEN LOWER(COALESCE(ce.tipo_documento_sunat, '')) IN ('factura', '01')
          THEN 'Factura'
        ELSE 'Boleta'
      END::text AS tipo_label,
      ce.id::text AS id,
      ce.venta_id,
      (ce.serie || '-' || ce.correlativo)::text AS numero,
      ce.estado::text,
      ce.total::numeric AS total,
      COALESCE(NULLIF(ce.cliente_razon_social, ''), 'Cliente general')::text
        AS tercero,
      COALESCE(
        ce.fecha_emision_ts,
        ce.fecha_emision::timestamp AT TIME ZONE 'America/Lima',
        ce.created_at
      ) AS fecha_documento,
      ce.descripcion_sunat::text,
      ce.pdf_path::text,
      ce.xml_path::text,
      ce.cdr_path::text
    FROM public.comprobantes_electronicos ce

    UNION ALL

    SELECT
      'nota'::text,
      'Nota de crédito'::text,
      nc.id::text,
      nc.venta_id,
      (nc.serie || '-' || nc.correlativo)::text,
      nc.estado::text,
      nc.total::numeric,
      COALESCE(NULLIF(nc.motivo_descripcion, ''), 'Nota de crédito')::text,
      COALESCE(
        nc.fecha_emision_ts,
        nc.fecha_emision::timestamp AT TIME ZONE 'America/Lima',
        nc.created_at
      ),
      nc.descripcion_sunat::text,
      nc.pdf_path::text,
      nc.xml_path::text,
      nc.cdr_path::text
    FROM public.notas_credito nc

    UNION ALL

    SELECT
      'guia'::text,
      CASE
        WHEN g.tipo_guia = 'transportista' THEN 'GRE Transportista'
        ELSE 'GRE Remitente'
      END::text,
      g.id::text,
      g.venta_id,
      (g.serie || '-' || g.correlativo)::text,
      g.estado::text,
      NULL::numeric,
      COALESCE(NULLIF(g.destinatario_razon_social, ''), 'Destinatario')::text,
      COALESCE(g.fecha_emision, g.created_at),
      g.descripcion_sunat::text,
      g.pdf_path::text,
      g.xml_path::text,
      g.cdr_path::text
    FROM public.guias_remision g
  )
  SELECT
    d.categoria,
    d.tipo_label,
    d.id,
    d.venta_id,
    d.numero,
    d.estado,
    d.total,
    d.tercero,
    d.fecha_documento,
    d.descripcion_sunat,
    d.pdf_path,
    d.xml_path,
    d.cdr_path
  FROM documentos d
  WHERE d.fecha_documento >= p_fecha_inicio
    AND d.fecha_documento < p_fecha_fin_exclusiva
  ORDER BY d.fecha_documento DESC, d.id DESC
  LIMIT v_limite
  OFFSET v_offset;
END;
$function$
