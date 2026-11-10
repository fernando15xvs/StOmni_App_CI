-- 2D-H: accepted e-invoices persist SUNAT document type codes '01' / '03'.
-- The private legacy credit-note writer only accepted words factura / boleta,
-- rejecting valid accepted tax documents. Normalize both forms while
-- preserving the semantic tipo_origen and the original SUNAT affected type.
-- This legacy helper remains EXECUTE-revoked to anon/authenticated.
CREATE OR REPLACE FUNCTION public.crear_nota_credito_v1_unscaled_legacy(p_request_id uuid, p_comprobante_id uuid, p_motivo_codigo text, p_motivo_descripcion text DEFAULT NULL::text, p_detalles jsonb DEFAULT '[]'::jsonb, p_monto_descuento numeric DEFAULT NULL::numeric, p_reponer_stock boolean DEFAULT true, p_fecha timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_comp record;
  v_nota_id uuid;
  v_existing record;
  v_tipo_serie text;
  v_serie text;
  v_correlativo bigint;
  v_tipo_doc_afectado text;
  v_codigo text := TRIM(COALESCE(p_motivo_codigo, ''));
  v_descripcion text;
  v_fecha_ts timestamp with time zone := COALESCE(p_fecha, now());
  v_fecha date;
  v_afecta_stock boolean;
  v_afecta_dinero boolean;
  v_repone_stock boolean;
  v_total numeric(14,2) := 0;
  v_base numeric(14,2) := 0;
  v_igv numeric(14,2) := 0;
  v_total_comprometido numeric(14,2) := 0;
  v_disponible numeric(14,2) := 0;
  v_item jsonb;
  v_det record;
  v_cantidad integer;
  v_reservado integer;
  v_piezas integer;
  v_linea_total numeric(14,2);
  v_linea_base numeric(14,2);
  v_linea_igv numeric(14,2);
  v_descripcion_corregida text;
  v_last_detail_id uuid;
  v_diff numeric(14,2);
  v_unidad_sunat text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT private.has_permission('tenant.write') OR NOT EXISTS (
    SELECT 1
    FROM public.empleados AS e
    WHERE e.organization_id = private.require_current_organization_id()
      AND (e.app_user_id = auth.uid() OR e.auth_id = auth.uid())
      AND COALESCE(e.activo, false) = true
  ) THEN
    RAISE EXCEPTION
      'Solo un administrador u operador activo puede emitir notas de crédito';
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'request_id es obligatorio';
  END IF;

  IF p_comprobante_id IS NULL THEN
    RAISE EXCEPTION 'comprobante_id es obligatorio';
  END IF;

  IF v_codigo NOT IN ('01', '03', '04', '07') THEN
    RAISE EXCEPTION 'Motivo de nota de crédito no permitido: %', v_codigo;
  END IF;

  IF jsonb_typeof(COALESCE(p_detalles, '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'detalles debe ser un arreglo JSON';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));

  SELECT *
  INTO v_existing
  FROM public.notas_credito
  WHERE organization_id = private.require_current_organization_id()
    AND request_id = p_request_id;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'idempotent', true,
      'nota_credito_id', v_existing.id,
      'serie', v_existing.serie,
      'correlativo', v_existing.correlativo,
      'estado', v_existing.estado
    );
  END IF;

  SELECT
    ce.*,
    v.total AS venta_total,
    v.estado AS venta_estado,
    v.estado_tributario,
    v.cliente_id
  INTO v_comp
  FROM public.comprobantes_electronicos AS ce
  JOIN public.ventas AS v ON v.organization_id = ce.organization_id AND v.id = ce.venta_id
  WHERE ce.organization_id = private.require_current_organization_id()
    AND ce.id = p_comprobante_id
  FOR UPDATE OF ce, v;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Comprobante no encontrado';
  END IF;

  IF LOWER(COALESCE(v_comp.estado, '')) <> 'aceptado' THEN
    RAISE EXCEPTION
      'Solo se puede emitir una nota de crédito para un comprobante aceptado';
  END IF;

  IF LOWER(COALESCE(v_comp.tipo_documento_sunat, '')) IN ('factura','01') THEN
    v_tipo_doc_afectado := '01';
    v_tipo_serie := 'nota_credito_factura';
    v_serie := 'FC01';
  ELSIF LOWER(COALESCE(v_comp.tipo_documento_sunat, '')) IN ('boleta','03') THEN
    v_tipo_doc_afectado := '03';
    v_tipo_serie := 'nota_credito_boleta';
    v_serie := 'BC01';
  ELSE
    RAISE EXCEPTION
      'El comprobante original no es una factura o boleta electrónica';
  END IF;

  -- SUNAT no permite utilizar el motivo 04 (descuento global)
  -- para boletas de venta electrónica emitidas a consumidores finales.
  IF v_tipo_doc_afectado = '03' AND v_codigo = '04' THEN
    RAISE EXCEPTION
      'SUNAT no permite el motivo 04 (descuento global) para boletas de venta electrónica';
  END IF;

  v_descripcion := COALESCE(
    NULLIF(TRIM(p_motivo_descripcion), ''),
    CASE v_codigo
      WHEN '01' THEN 'ANULACION DE LA OPERACION'
      WHEN '03' THEN 'CORRECCION POR ERROR EN LA DESCRIPCION'
      WHEN '04' THEN 'DESCUENTO GLOBAL'
      WHEN '07' THEN 'DEVOLUCION POR ITEM'
    END
  );

  v_afecta_stock := v_codigo IN ('01', '07');
  v_afecta_dinero := v_codigo IN ('01', '04', '07');

  -- Reglas confirmadas del negocio:
  -- 01 (anulación total) y 07 (devolución por ítem) siempre reponen stock.
  -- El parámetro se conserva únicamente por compatibilidad de la firma RPC.
  v_repone_stock := v_afecta_stock;
  v_fecha := (v_fecha_ts AT TIME ZONE 'America/Lima')::date;

  IF v_fecha > (now() AT TIME ZONE 'America/Lima')::date THEN
    RAISE EXCEPTION
      'La fecha de emisión de la nota no puede estar en el futuro';
  END IF;

  IF v_tipo_doc_afectado = '01'
     AND v_fecha < (now() AT TIME ZONE 'America/Lima')::date - 3 THEN
    RAISE EXCEPTION
      'La nota vinculada a factura supera el plazo máximo de tres días calendario posteriores a su fecha de emisión';
  END IF;

  SELECT COALESCE(SUM(nc.total), 0)
  INTO v_total_comprometido
  FROM public.notas_credito AS nc
  WHERE nc.organization_id = private.require_current_organization_id()
    AND nc.comprobante_id = p_comprobante_id
    AND nc.afecta_dinero = true
    AND nc.estado IN (
      'pendiente_envio',
      'procesando',
      'pendiente_reintento',
      'resultado_incierto',
      'aceptado'
    );

  v_disponible := GREATEST(
    ROUND(COALESCE(v_comp.total, 0) - v_total_comprometido, 2),
    0
  );

  IF v_codigo = '01' AND v_total_comprometido > 0.01 THEN
    RAISE EXCEPTION
      'No se puede hacer anulación total porque ya existen devoluciones o descuentos por S/ %',
      v_total_comprometido;
  END IF;

  UPDATE public.series_comprobantes
  SET
    ultimo_correlativo = ultimo_correlativo + 1,
    updated_at = now()
  WHERE organization_id = private.require_current_organization_id()
    AND tipo_documento_sunat = v_tipo_serie
    AND serie = v_serie
    AND activo = true
  RETURNING ultimo_correlativo INTO v_correlativo;

  IF v_correlativo IS NULL THEN
    RAISE EXCEPTION 'No existe una serie activa para %', v_tipo_serie;
  END IF;

  INSERT INTO public.notas_credito(
    request_id,
    comprobante_id,
    venta_id,
    tipo_origen,
    tipo_doc_afectado,
    serie_afectada,
    correlativo_afectado,
    motivo_codigo,
    motivo_descripcion,
    serie,
    correlativo,
    fecha_emision,
    fecha_emision_ts,
    estado,
    afecta_stock,
    afecta_dinero,
    reponer_stock,

    cliente_tipo_documento,
    cliente_numero_documento,
    cliente_razon_social,
    cliente_direccion,

    empresa_ruc,
    empresa_razon_social,
    empresa_nombre_comercial,
    empresa_direccion,
    empresa_ubigeo,
    empresa_departamento,
    empresa_provincia,
    empresa_distrito,
    empresa_cod_local,
    empresa_telefono,
    empresa_logo_url,
    creado_por
  )
  VALUES (
    p_request_id,
    p_comprobante_id,
    v_comp.venta_id,
    CASE WHEN v_tipo_doc_afectado='01' THEN 'factura' ELSE 'boleta' END,
    v_tipo_doc_afectado,
    v_comp.serie,
    v_comp.correlativo,
    v_codigo,
    v_descripcion,
    v_serie,
    v_correlativo,
    v_fecha,
    v_fecha_ts,
    'pendiente_envio',
    v_afecta_stock,
    v_afecta_dinero,
    v_repone_stock,

    v_comp.cliente_tipo_documento,
    v_comp.cliente_numero_documento,
    v_comp.cliente_razon_social,
    v_comp.cliente_direccion,

    v_comp.empresa_ruc,
    v_comp.empresa_razon_social,
    v_comp.empresa_nombre_comercial,
    v_comp.empresa_direccion,
    v_comp.empresa_ubigeo,
    v_comp.empresa_departamento,
    v_comp.empresa_provincia,
    v_comp.empresa_distrito,
    v_comp.empresa_cod_local,
    v_comp.empresa_telefono,
    v_comp.empresa_logo_url,
    auth.uid()
  )
  RETURNING id INTO v_nota_id;

  -- ---------------------------------------------------------------------------
  -- 01: ANULACIÓN TOTAL
  -- ---------------------------------------------------------------------------
  IF v_codigo = '01' THEN
    FOR v_det IN
      SELECT
        dv.*,
        p.codigo,
        p.nombre,
        COALESCE(NULLIF(dv.subtotal_final, 0), dv.subtotal) AS total_linea
      FROM public.detalle_ventas AS dv
      JOIN public.productos AS p ON p.id = dv.producto_id
      WHERE dv.venta_id = v_comp.venta_id
      ORDER BY dv.id
    LOOP
      v_linea_total := ROUND(v_det.total_linea, 2);
      v_linea_base := ROUND(v_linea_total / 1.18, 2);
      v_linea_igv := ROUND(v_linea_total - v_linea_base, 2);
      v_unidad_sunat := CASE LOWER(COALESCE(v_det.tipo_unidad, 'unidad'))
        WHEN 'caja' THEN 'BX'
        WHEN 'cajas' THEN 'BX'
        WHEN 'paquete' THEN 'PK'
        WHEN 'paquetes' THEN 'PK'
        ELSE 'NIU'
      END;

      INSERT INTO public.notas_credito_detalles(
        nota_credito_id,
        detalle_venta_id,
        producto_id,
        almacen_id,
        codigo_producto,
        descripcion_original,
        tipo_unidad,
        unidad_sunat,
        cantidad_visual,
        piezas_reales,
        precio_unitario_comercial,
        subtotal,
        base_imponible,
        igv,
        tipo_venta_snapshot,
        pcs_snapshot,
        unidad_base_snapshot,
        repone_stock
      )
      VALUES (
        v_nota_id,
        v_det.id,
        v_det.producto_id,
        v_det.almacen_id,
        v_det.codigo,
        v_det.nombre,
        COALESCE(v_det.tipo_unidad, 'unidad'),
        v_unidad_sunat,
        v_det.cantidad,
        COALESCE(v_det.piezas_reales, v_det.cantidad),
        COALESCE(
          v_det.precio_unitario_comercial,
          CASE WHEN v_det.cantidad > 0
            THEN v_linea_total / v_det.cantidad
            ELSE 0
          END
        ),
        v_linea_total,
        v_linea_base,
        v_linea_igv,
        v_det.tipo_venta_snapshot,
        v_det.pcs_snapshot,
        v_det.unidad_base_snapshot,
        v_repone_stock
      )
      RETURNING id INTO v_last_detail_id;

      v_total := v_total + v_linea_total;
    END LOOP;

    IF v_last_detail_id IS NULL THEN
      RAISE EXCEPTION 'La venta no tiene detalles';
    END IF;

    -- Ajuste final por redondeo para igualar exactamente al comprobante original.
    v_diff := ROUND(COALESCE(v_comp.total, 0) - v_total, 2);
    IF ABS(v_diff) > 0 THEN
      UPDATE public.notas_credito_detalles
      SET
        subtotal = ROUND(subtotal + v_diff, 2),
        base_imponible = ROUND((subtotal + v_diff) / 1.18, 2),
        igv = ROUND(
          (subtotal + v_diff) - ((subtotal + v_diff) / 1.18),
          2
        ),
        precio_unitario_comercial = ROUND(
          (subtotal + v_diff) / GREATEST(cantidad_visual, 1),
          6
        )
      WHERE id = v_last_detail_id;
    END IF;

    v_total := ROUND(COALESCE(v_comp.total, 0), 2);

  -- ---------------------------------------------------------------------------
  -- 07: DEVOLUCIÓN PARCIAL POR ÍTEM
  -- ---------------------------------------------------------------------------
  ELSIF v_codigo = '07' THEN
    IF jsonb_array_length(COALESCE(p_detalles, '[]'::jsonb)) = 0 THEN
      RAISE EXCEPTION 'Selecciona al menos un producto para devolver';
    END IF;

    FOR v_item IN
      SELECT value
      FROM jsonb_array_elements(p_detalles)
    LOOP
      v_cantidad := COALESCE(NULLIF(v_item->>'cantidad', '')::integer, 0);

      IF v_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad a devolver debe ser mayor a cero';
      END IF;

      SELECT
        dv.*,
        p.codigo,
        p.nombre,
        COALESCE(NULLIF(dv.subtotal_final, 0), dv.subtotal) AS total_linea
      INTO v_det
      FROM public.detalle_ventas AS dv
      JOIN public.productos AS p ON p.id = dv.producto_id
      WHERE dv.id = NULLIF(v_item->>'detalle_venta_id', '')::bigint
        AND dv.venta_id = v_comp.venta_id
      FOR UPDATE OF dv;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Detalle de venta inválido';
      END IF;

      SELECT COALESCE(SUM(ncd.cantidad_visual), 0)::integer
      INTO v_reservado
      FROM public.notas_credito_detalles AS ncd
      JOIN public.notas_credito AS nc ON nc.id = ncd.nota_credito_id
      WHERE ncd.detalle_venta_id = v_det.id
        AND nc.afecta_stock = true
        AND nc.estado IN (
          'pendiente_envio',
          'procesando',
          'pendiente_reintento',
          'resultado_incierto',
          'aceptado'
        );

      IF v_cantidad > (v_det.cantidad - v_reservado) THEN
        RAISE EXCEPTION
          'La cantidad solicitada de % supera la disponible de % para %',
          v_cantidad,
          GREATEST(v_det.cantidad - v_reservado, 0),
          v_det.nombre;
      END IF;

      IF MOD(
        COALESCE(v_det.piezas_reales, v_det.cantidad) * v_cantidad,
        GREATEST(v_det.cantidad, 1)
      ) <> 0 THEN
        RAISE EXCEPTION
          'No se puede convertir exactamente la cantidad comercial de % a stock base',
          v_det.nombre;
      END IF;

      v_piezas := (
        COALESCE(v_det.piezas_reales, v_det.cantidad) * v_cantidad
      ) / GREATEST(v_det.cantidad, 1);

      v_linea_total := ROUND(
        (v_det.total_linea / GREATEST(v_det.cantidad, 1)) * v_cantidad,
        2
      );
      v_linea_base := ROUND(v_linea_total / 1.18, 2);
      v_linea_igv := ROUND(v_linea_total - v_linea_base, 2);
      v_unidad_sunat := CASE LOWER(COALESCE(v_det.tipo_unidad, 'unidad'))
        WHEN 'caja' THEN 'BX'
        WHEN 'cajas' THEN 'BX'
        WHEN 'paquete' THEN 'PK'
        WHEN 'paquetes' THEN 'PK'
        ELSE 'NIU'
      END;

      INSERT INTO public.notas_credito_detalles(
        nota_credito_id,
        detalle_venta_id,
        producto_id,
        almacen_id,
        codigo_producto,
        descripcion_original,
        tipo_unidad,
        unidad_sunat,
        cantidad_visual,
        piezas_reales,
        precio_unitario_comercial,
        subtotal,
        base_imponible,
        igv,
        tipo_venta_snapshot,
        pcs_snapshot,
        unidad_base_snapshot,
        repone_stock
      )
      VALUES (
        v_nota_id,
        v_det.id,
        v_det.producto_id,
        v_det.almacen_id,
        v_det.codigo,
        v_det.nombre,
        COALESCE(v_det.tipo_unidad, 'unidad'),
        v_unidad_sunat,
        v_cantidad,
        v_piezas,
        ROUND(v_linea_total / v_cantidad, 6),
        v_linea_total,
        v_linea_base,
        v_linea_igv,
        v_det.tipo_venta_snapshot,
        v_det.pcs_snapshot,
        v_det.unidad_base_snapshot,
        v_repone_stock
      );

      v_total := v_total + v_linea_total;
    END LOOP;

    IF v_total <= 0 OR v_total > v_disponible + 0.02 THEN
      RAISE EXCEPTION
        'El total de la devolución S/ % supera el saldo tributario disponible S/ %',
        ROUND(v_total, 2),
        ROUND(v_disponible, 2);
    END IF;

  -- ---------------------------------------------------------------------------
  -- 04: DESCUENTO POSTERIOR / GLOBAL
  -- ---------------------------------------------------------------------------
  ELSIF v_codigo = '04' THEN
    v_total := ROUND(COALESCE(p_monto_descuento, 0), 2);

    IF v_total <= 0 THEN
      RAISE EXCEPTION 'El monto del descuento debe ser mayor a cero';
    END IF;

    IF v_total > v_disponible + 0.02 THEN
      RAISE EXCEPTION
        'El descuento S/ % supera el saldo tributario disponible S/ %',
        v_total,
        v_disponible;
    END IF;

    v_linea_base := ROUND(v_total / 1.18, 2);
    v_linea_igv := ROUND(v_total - v_linea_base, 2);

    INSERT INTO public.notas_credito_detalles(
      nota_credito_id,
      descripcion_original,
      tipo_unidad,
      unidad_sunat,
      cantidad_visual,
      piezas_reales,
      precio_unitario_comercial,
      subtotal,
      base_imponible,
      igv,
      repone_stock
    )
    VALUES (
      v_nota_id,
      'DESCUENTO POSTERIOR',
      'servicio',
      'ZZ',
      1,
      0,
      v_total,
      v_total,
      v_linea_base,
      v_linea_igv,
      false
    );

  -- ---------------------------------------------------------------------------
  -- 03: CORRECCIÓN DE DESCRIPCIÓN
  -- ---------------------------------------------------------------------------
  ELSIF v_codigo = '03' THEN
    IF jsonb_array_length(COALESCE(p_detalles, '[]'::jsonb)) <> 1 THEN
      RAISE EXCEPTION
        'Selecciona exactamente un producto para corregir su descripción';
    END IF;

    v_item := p_detalles->0;
    v_descripcion_corregida := NULLIF(
      TRIM(v_item->>'descripcion_corregida'),
      ''
    );

    IF v_descripcion_corregida IS NULL THEN
      RAISE EXCEPTION 'La descripción corregida es obligatoria';
    END IF;

    SELECT
      dv.*,
      p.codigo,
      p.nombre,
      COALESCE(NULLIF(dv.subtotal_final, 0), dv.subtotal) AS total_linea
    INTO v_det
    FROM public.detalle_ventas AS dv
    JOIN public.productos AS p ON p.id = dv.producto_id
    WHERE dv.id = NULLIF(v_item->>'detalle_venta_id', '')::bigint
      AND dv.venta_id = v_comp.venta_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Detalle de venta inválido';
    END IF;

    v_total := ROUND(v_det.total_linea, 2);
    v_linea_base := ROUND(v_total / 1.18, 2);
    v_linea_igv := ROUND(v_total - v_linea_base, 2);
    v_unidad_sunat := CASE LOWER(COALESCE(v_det.tipo_unidad, 'unidad'))
      WHEN 'caja' THEN 'BX'
      WHEN 'cajas' THEN 'BX'
      WHEN 'paquete' THEN 'PK'
      WHEN 'paquetes' THEN 'PK'
      ELSE 'NIU'
    END;

    INSERT INTO public.notas_credito_detalles(
      nota_credito_id,
      detalle_venta_id,
      producto_id,
      almacen_id,
      codigo_producto,
      descripcion_original,
      descripcion_corregida,
      tipo_unidad,
      unidad_sunat,
      cantidad_visual,
      piezas_reales,
      precio_unitario_comercial,
      subtotal,
      base_imponible,
      igv,
      tipo_venta_snapshot,
      pcs_snapshot,
      unidad_base_snapshot,
      repone_stock
    )
    VALUES (
      v_nota_id,
      v_det.id,
      v_det.producto_id,
      v_det.almacen_id,
      v_det.codigo,
      v_det.nombre,
      v_descripcion_corregida,
      COALESCE(v_det.tipo_unidad, 'unidad'),
      v_unidad_sunat,
      v_det.cantidad,
      0,
      COALESCE(
        v_det.precio_unitario_comercial,
        v_total / GREATEST(v_det.cantidad, 1)
      ),
      v_total,
      v_linea_base,
      v_linea_igv,
      v_det.tipo_venta_snapshot,
      v_det.pcs_snapshot,
      v_det.unidad_base_snapshot,
      false
    );
  END IF;

  SELECT
    ROUND(COALESCE(SUM(base_imponible), 0), 2),
    ROUND(COALESCE(SUM(igv), 0), 2),
    ROUND(COALESCE(SUM(subtotal), 0), 2)
  INTO v_base, v_igv, v_total
  FROM public.notas_credito_detalles
  WHERE nota_credito_id = v_nota_id;

  UPDATE public.notas_credito
  SET
    base_imponible = v_base,
    igv = v_igv,
    total = v_total
  WHERE id = v_nota_id;

  RETURN jsonb_build_object(
    'success', true,
    'idempotent', false,
    'nota_credito_id', v_nota_id,
    'venta_id', v_comp.venta_id,
    'comprobante_id', p_comprobante_id,
    'serie', v_serie,
    'correlativo', v_correlativo,
    'estado', 'pendiente_envio',
    'total', v_total,
    'reponer_stock', v_repone_stock
  );
END;
$function$;
