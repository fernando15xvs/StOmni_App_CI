-- Actualización masiva de roles: vendedor a operador

CREATE OR REPLACE FUNCTION public.ajustar_stock_y_kardex(p_producto_id bigint, p_almacen_id bigint, p_delta integer, p_tipo_movimiento text, p_motivo text, p_ingreso_costo numeric DEFAULT 0, p_ingreso_p_unit numeric DEFAULT 0, p_ingreso_p_caja numeric DEFAULT 0, p_ingreso_p_c_comp numeric DEFAULT 0, p_salida_cliente text DEFAULT NULL::text, p_salida_p_unit numeric DEFAULT 0, p_salida_total numeric DEFAULT 0, p_unidad_label text DEFAULT 'AUTO'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: usuario no autenticado.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.empleados AS e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'operador')
  ) THEN
    RAISE EXCEPTION 'Acceso denegado: rol no autorizado.';
  END IF;

  PERFORM public._aplicar_movimiento_inventario_v2(
    p_producto_id := p_producto_id,
    p_almacen_id := p_almacen_id,
    p_delta := p_delta,
    p_tipo_movimiento := p_tipo_movimiento,
    p_motivo := p_motivo,
    p_fecha := now(),
    p_ingreso_costo := p_ingreso_costo,
    p_ingreso_p_unit := p_ingreso_p_unit,
    p_ingreso_p_caja := p_ingreso_p_caja,
    p_ingreso_p_c_comp := p_ingreso_p_c_comp,
    p_salida_cliente := p_salida_cliente,
    p_salida_p_unit := p_salida_p_unit,
    p_salida_total := p_salida_total
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.anular_venta(p_venta_id bigint, p_detalles jsonb DEFAULT '[]'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_detalle record;
  v_venta record;
  v_saldo integer;
  v_unidad_base text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: usuario no autenticado';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.empleados AS e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND LOWER(COALESCE(e.rol, '')) IN (
        'admin',
        'administrador',
        'supervisor',
        'operador',
        'almacenero'
      )
  ) THEN
    RAISE EXCEPTION 'Acceso denegado: rol no autorizado para anular ventas';
  END IF;

  SELECT v.id, v.request_id
  INTO v_venta
  FROM public.ventas AS v
  WHERE v.id = p_venta_id
  FOR UPDATE;

  IF NOT FOUND THEN
    IF EXISTS (
      SELECT 1
      FROM public.ventas_requests_anulados AS vra
      WHERE vra.venta_id_original = p_venta_id
    ) THEN
      RETURN;
    END IF;

    RAISE EXCEPTION 'La venta % no existe', p_venta_id;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.comprobantes_electronicos AS ce
    WHERE ce.venta_id = p_venta_id
      AND LOWER(COALESCE(ce.estado, '')) IN ('aceptado', 'accepted')
  ) THEN
    RAISE EXCEPTION
      'No se puede eliminar una venta con comprobante aceptado. Debe emitirse una nota de crédito.';
  END IF;

  IF v_venta.request_id IS NOT NULL THEN
    INSERT INTO public.ventas_requests_anulados (
      request_id,
      venta_id_original,
      anulada_por
    )
    VALUES (
      v_venta.request_id,
      p_venta_id,
      auth.uid()
    )
    ON CONFLICT (request_id) DO NOTHING;
  END IF;

  FOR v_detalle IN
    SELECT
      dv.producto_id,
      dv.almacen_id,
      COALESCE(
        NULLIF(dv.piezas_reales, 0),
        CASE
          WHEN LOWER(TRIM(COALESCE(
            dv.tipo_venta_snapshot,
            p.tipo_venta,
            ''
          ))) IN ('paquetes', 'paquete', 'caja', 'solo_cajas')
            THEN dv.cantidad
          WHEN LOWER(TRIM(COALESCE(
            dv.tipo_venta_snapshot,
            p.tipo_venta,
            ''
          ))) IN (
            'caja_paquetes',
            'caja_unidades',
            'ambos',
            'caja_unidad',
            'cajas_unidades'
          )
          AND LOWER(TRIM(COALESCE(dv.tipo_unidad, 'unidad'))) IN (
            'caja', 'cajas', 'box', 'bx'
          )
            THEN dv.cantidad * GREATEST(
              COALESCE(dv.pcs_snapshot, p.cantidad_por_caja, 1),
              1
            )
          ELSE dv.cantidad
        END
      ) AS piezas_reales,
      COALESCE(dv.precio_unitario, 0) AS precio_unitario,
      COALESCE(dv.tipo_venta_snapshot, UPPER(p.tipo_venta)) AS tipo_venta,
      COALESCE(dv.pcs_snapshot, p.cantidad_por_caja, 1) AS pcs,
      COALESCE(
        dv.unidad_base_snapshot,
        CASE
          WHEN UPPER(COALESCE(p.tipo_venta, '')) IN
            ('PAQUETES', 'PAQUETE', 'CAJA_PAQUETES') THEN 'Paquete'
          WHEN UPPER(COALESCE(p.tipo_venta, '')) IN
            ('CAJA', 'SOLO_CAJAS') THEN 'Caja'
          ELSE 'Unidad'
        END
      ) AS unidad_base,
      p.nombre AS producto_nombre,
      COALESCE(pr.nombre, 'Generico') AS proveedor,
      a.nombre AS almacen_nombre
    FROM public.detalle_ventas AS dv
    JOIN public.productos AS p ON p.id = dv.producto_id
    LEFT JOIN public.proveedores AS pr ON pr.id = p.proveedor_id
    JOIN public.almacenes AS a ON a.id = dv.almacen_id
    WHERE dv.venta_id = p_venta_id
    ORDER BY dv.producto_id, dv.almacen_id
  LOOP
    IF v_detalle.piezas_reales <= 0 THEN
      RAISE EXCEPTION
        'La venta % contiene una línea sin piezas_reales válidas', p_venta_id;
    END IF;

    PERFORM pg_advisory_xact_lock(v_detalle.producto_id);

    INSERT INTO public.inventario_almacen(producto_id, almacen_id, cantidad)
    VALUES(v_detalle.producto_id, v_detalle.almacen_id, v_detalle.piezas_reales)
    ON CONFLICT(producto_id, almacen_id)
    DO UPDATE SET cantidad = public.inventario_almacen.cantidad + EXCLUDED.cantidad
    RETURNING cantidad INTO v_saldo;

    v_unidad_base := v_detalle.unidad_base;

    INSERT INTO public.inventario_movimientos(
      fecha, producto_id, producto_nombre, pcs, proveedor,
      tipo, saldo, almacen_id, almacen_nombre, observaciones,
      ingreso_cant, ingreso_und, ingreso_p_unit,
      tipo_venta_snapshot, unidad_base_snapshot, request_id
    ) VALUES (
      now(), v_detalle.producto_id, v_detalle.producto_nombre,
      v_detalle.pcs, v_detalle.proveedor,
      'ENTRADA', v_saldo, v_detalle.almacen_id,
      COALESCE(v_detalle.almacen_nombre, ''),
      'Anulación Venta #' || p_venta_id,
      v_detalle.piezas_reales, v_unidad_base,
      v_detalle.precio_unitario,
      v_detalle.tipo_venta, v_unidad_base, v_venta.request_id
    );
  END LOOP;

  -- Los comprobantes aceptados ya fueron bloqueados. Los pendientes pueden
  -- eliminarse junto con la venta; el correlativo utilizado no se reutiliza.
  DELETE FROM public.constancias_descuento WHERE venta_id = p_venta_id;
  DELETE FROM public.comprobantes_electronicos WHERE venta_id = p_venta_id;
  DELETE FROM public.pagos_venta WHERE venta_id = p_venta_id;
  DELETE FROM public.detalle_ventas WHERE venta_id = p_venta_id;
  DELETE FROM public.ventas WHERE id = p_venta_id;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.anular_venta_v2(p_venta_id bigint, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_detalle record;
  v_venta public.ventas%ROWTYPE;
  v_saldo integer;
  v_unidad_base text;
  v_actor_id bigint;
  v_actor_nombre text;
  v_actor_rol text;
  v_vendedor_nombre text;
  v_comprobantes_snapshot jsonb := '[]'::jsonb;
  v_facturacion_intentos_snapshot jsonb := '[]'::jsonb;
  v_constancias_snapshot jsonb := '[]'::jsonb;
  v_motivo text := TRIM(COALESCE(p_motivo, ''));
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  SELECT e.id, e.nombre, LOWER(COALESCE(e.rol, ''))
  INTO v_actor_id, v_actor_nombre, v_actor_rol
  FROM public.empleados e
  WHERE e.auth_id = auth.uid()
    AND COALESCE(e.activo, false) = true
    AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'operador')
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Rol no autorizado para anular ventas';
  END IF;

  IF LENGTH(v_motivo) < 3 THEN
    RAISE EXCEPTION 'El motivo de anulación debe tener al menos 3 caracteres';
  END IF;
  IF LENGTH(v_motivo) > 250 THEN
    RAISE EXCEPTION 'El motivo de anulación no puede superar 250 caracteres';
  END IF;

  SELECT * INTO v_venta
  FROM public.ventas
  WHERE id = p_venta_id
  FOR UPDATE;

  IF NOT FOUND THEN
    IF EXISTS (
      SELECT 1 FROM public.ventas_requests_anulados
      WHERE venta_id_original = p_venta_id
    ) THEN
      RETURN jsonb_build_object('success', true, 'idempotent', true);
    END IF;
    RAISE EXCEPTION 'La venta % no existe', p_venta_id;
  END IF;

  SELECT e.nombre INTO v_vendedor_nombre
  FROM public.empleados e
  WHERE e.id = v_venta.vendedor_id;

  IF EXISTS (
    SELECT 1 FROM public.comprobantes_electronicos ce
    WHERE ce.venta_id = p_venta_id
      AND LOWER(COALESCE(ce.estado, '')) IN (
        'pendiente',
        'pendiente_envio',
        'procesando',
        'pendiente_reintento',
        'ticket_pendiente'
      )
  ) THEN
    RAISE EXCEPTION
      'No se puede anular la venta mientras el comprobante tenga un resultado tributario pendiente. Consulte primero su estado en SUNAT';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.comprobantes_electronicos ce
    WHERE ce.venta_id = p_venta_id
      AND LOWER(COALESCE(ce.estado, '')) IN ('aceptado', 'accepted')
  ) THEN
    RAISE EXCEPTION 'La venta tiene un comprobante aceptado. Debe emitirse una nota de crédito';
  END IF;

  -- Conserva la evidencia del comprobante rechazado y de todos sus intentos
  -- antes de retirar las filas operativas. Así la anulación local no falla por
  -- la FK de facturacion_intentos y tampoco pierde la trazabilidad tributaria.
  SELECT COALESCE(
    jsonb_agg(to_jsonb(ce) ORDER BY ce.created_at, ce.id),
    '[]'::jsonb
  )
  INTO v_comprobantes_snapshot
  FROM public.comprobantes_electronicos ce
  WHERE ce.venta_id = p_venta_id;

  SELECT COALESCE(
    jsonb_agg(to_jsonb(fi) ORDER BY fi.created_at, fi.id),
    '[]'::jsonb
  )
  INTO v_facturacion_intentos_snapshot
  FROM public.facturacion_intentos fi
  JOIN public.comprobantes_electronicos ce
    ON ce.id = fi.comprobante_id
  WHERE ce.venta_id = p_venta_id;

  SELECT COALESCE(
    jsonb_agg(to_jsonb(cd) ORDER BY cd.id),
    '[]'::jsonb
  )
  INTO v_constancias_snapshot
  FROM public.constancias_descuento cd
  WHERE cd.venta_id = p_venta_id;

  IF v_venta.request_id IS NOT NULL THEN
    INSERT INTO public.ventas_requests_anulados(
      request_id,
      venta_id_original,
      anulada_por,
      vendedor_id_original,
      vendedor_nombre_snapshot,
      anulada_por_empleado_id,
      anulada_por_nombre_snapshot,
      motivo,
      anulada_at,
      venta_snapshot
    ) VALUES (
      v_venta.request_id,
      p_venta_id,
      auth.uid(),
      v_venta.vendedor_id,
      v_vendedor_nombre,
      v_actor_id,
      v_actor_nombre,
      v_motivo,
      clock_timestamp(),
      to_jsonb(v_venta) || jsonb_build_object(
        'comprobantes_electronicos', v_comprobantes_snapshot,
        'facturacion_intentos', v_facturacion_intentos_snapshot,
        'constancias_descuento', v_constancias_snapshot
      )
    )
    ON CONFLICT (request_id) DO UPDATE SET
      motivo = EXCLUDED.motivo,
      anulada_por = EXCLUDED.anulada_por,
      anulada_por_empleado_id = EXCLUDED.anulada_por_empleado_id,
      anulada_por_nombre_snapshot = EXCLUDED.anulada_por_nombre_snapshot,
      anulada_at = EXCLUDED.anulada_at;
  END IF;

  FOR v_detalle IN
    SELECT
      dv.producto_id,
      dv.almacen_id,
      COALESCE(
        NULLIF(dv.piezas_reales, 0),
        CASE
          WHEN LOWER(TRIM(COALESCE(dv.tipo_venta_snapshot, p.tipo_venta, ''))) IN ('paquetes','paquete','caja','solo_cajas')
            THEN dv.cantidad
          WHEN LOWER(TRIM(COALESCE(dv.tipo_venta_snapshot, p.tipo_venta, ''))) IN ('caja_paquetes','caja_unidades','ambos','caja_unidad','cajas_unidades')
           AND LOWER(TRIM(COALESCE(dv.tipo_unidad, 'unidad'))) IN ('caja','cajas','box','bx')
            THEN dv.cantidad * GREATEST(COALESCE(dv.pcs_snapshot, p.cantidad_por_caja, 1), 1)
          ELSE dv.cantidad
        END
      ) AS piezas_reales,
      COALESCE(dv.precio_unitario, 0) AS precio_unitario,
      COALESCE(dv.tipo_venta_snapshot, UPPER(p.tipo_venta)) AS tipo_venta,
      COALESCE(dv.pcs_snapshot, p.cantidad_por_caja, 1) AS pcs,
      COALESCE(
        dv.unidad_base_snapshot,
        CASE
          WHEN UPPER(COALESCE(p.tipo_venta, '')) IN ('PAQUETES','PAQUETE','CAJA_PAQUETES') THEN 'Paquete'
          WHEN UPPER(COALESCE(p.tipo_venta, '')) IN ('CAJA','SOLO_CAJAS') THEN 'Caja'
          ELSE 'Unidad'
        END
      ) AS unidad_base,
      p.nombre AS producto_nombre,
      COALESCE(pr.nombre, 'Generico') AS proveedor,
      a.nombre AS almacen_nombre
    FROM public.detalle_ventas dv
    JOIN public.productos p ON p.id = dv.producto_id
    LEFT JOIN public.proveedores pr ON pr.id = p.proveedor_id
    JOIN public.almacenes a ON a.id = dv.almacen_id
    WHERE dv.venta_id = p_venta_id
    ORDER BY dv.producto_id, dv.almacen_id
  LOOP
    IF v_detalle.piezas_reales <= 0 THEN
      RAISE EXCEPTION 'La venta contiene una línea sin cantidad base válida';
    END IF;

    PERFORM pg_advisory_xact_lock(v_detalle.producto_id);

    INSERT INTO public.inventario_almacen(producto_id, almacen_id, cantidad)
    VALUES(v_detalle.producto_id, v_detalle.almacen_id, v_detalle.piezas_reales)
    ON CONFLICT(producto_id, almacen_id)
    DO UPDATE SET cantidad = public.inventario_almacen.cantidad + EXCLUDED.cantidad
    RETURNING cantidad INTO v_saldo;

    v_unidad_base := v_detalle.unidad_base;

    INSERT INTO public.inventario_movimientos(
      fecha, producto_id, producto_nombre, pcs, proveedor,
      tipo, saldo, almacen_id, almacen_nombre, observaciones,
      ingreso_cant, ingreso_und, ingreso_p_unit,
      venta_id, venta_id_original, vendedor_id, vendedor_nombre_snapshot,
      anulado_por_id, anulado_por_nombre_snapshot, motivo_anulacion,
      tipo_venta_snapshot, unidad_base_snapshot, request_id
    ) VALUES (
      clock_timestamp(), v_detalle.producto_id, v_detalle.producto_nombre,
      v_detalle.pcs, v_detalle.proveedor,
      'ANULACION_VENTA', v_saldo, v_detalle.almacen_id,
      COALESCE(v_detalle.almacen_nombre, ''),
      'Anulación Venta #' || p_venta_id,
      v_detalle.piezas_reales, v_unidad_base, v_detalle.precio_unitario,
      p_venta_id, p_venta_id, v_venta.vendedor_id, v_vendedor_nombre,
      v_actor_id, v_actor_nombre, v_motivo,
      v_detalle.tipo_venta, v_unidad_base, v_venta.request_id
    );
  END LOOP;

  DELETE FROM public.facturacion_intentos
  WHERE comprobante_id IN (
    SELECT ce.id
    FROM public.comprobantes_electronicos ce
    WHERE ce.venta_id = p_venta_id
  );
  DELETE FROM public.constancias_descuento WHERE venta_id = p_venta_id;
  DELETE FROM public.comprobantes_electronicos WHERE venta_id = p_venta_id;
  DELETE FROM public.pagos_venta WHERE venta_id = p_venta_id;
  DELETE FROM public.detalle_ventas WHERE venta_id = p_venta_id;
  DELETE FROM public.ventas WHERE id = p_venta_id;

  RETURN jsonb_build_object(
    'success', true,
    'venta_id_original', p_venta_id,
    'operador', v_vendedor_nombre,
    'anulada_por', v_actor_nombre,
    'motivo', v_motivo
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.crear_nota_credito_v1(p_request_id uuid, p_comprobante_id uuid, p_motivo_codigo text, p_motivo_descripcion text DEFAULT NULL::text, p_detalles jsonb DEFAULT '[]'::jsonb, p_monto_descuento numeric DEFAULT NULL::numeric, p_reponer_stock boolean DEFAULT true, p_fecha timestamp with time zone DEFAULT now())
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

  IF NOT EXISTS (
    SELECT 1
    FROM public.empleados AS e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'operador')
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
  WHERE request_id = p_request_id;

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
  JOIN public.ventas AS v ON v.id = ce.venta_id
  WHERE ce.id = p_comprobante_id
  FOR UPDATE OF ce, v;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Comprobante no encontrado';
  END IF;

  IF LOWER(COALESCE(v_comp.estado, '')) <> 'aceptado' THEN
    RAISE EXCEPTION
      'Solo se puede emitir una nota de crédito para un comprobante aceptado';
  END IF;

  IF LOWER(COALESCE(v_comp.tipo_documento_sunat, '')) = 'factura' THEN
    v_tipo_doc_afectado := '01';
    v_tipo_serie := 'nota_credito_factura';
    v_serie := 'FC01';
  ELSIF LOWER(COALESCE(v_comp.tipo_documento_sunat, '')) = 'boleta' THEN
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
  WHERE nc.comprobante_id = p_comprobante_id
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
  WHERE tipo_documento_sunat = v_tipo_serie
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
    LOWER(v_comp.tipo_documento_sunat),
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
$function$
;

CREATE OR REPLACE FUNCTION public.eliminar_cotizacion_v2(p_cotizacion_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_estado text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION
      'Acceso denegado: usuario no autenticado.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.empleados AS e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND LOWER(COALESCE(e.rol, '')) IN (
        'admin',
        'administrador',
        'operador',
        'supervisor'
      )
  ) THEN
    RAISE EXCEPTION
      'Acceso denegado: rol no autorizado para eliminar cotizaciones.';
  END IF;

  SELECT LOWER(COALESCE(c.estado, 'pendiente'))
  INTO v_estado
  FROM public.cotizaciones AS c
  WHERE c.id = p_cotizacion_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'La cotización % no existe.',
      p_cotizacion_id;
  END IF;

  IF v_estado <> 'pendiente' THEN
    RAISE EXCEPTION
      'Solo se pueden eliminar cotizaciones pendientes. Estado actual: %.',
      v_estado;
  END IF;

  DELETE FROM public.cotizaciones
  WHERE id = p_cotizacion_id;

  RETURN jsonb_build_object(
    'success', true,
    'cotizacion_id', p_cotizacion_id,
    'mensaje', 'Cotización eliminada correctamente'
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.eliminar_pago_venta_v1(p_pago_id bigint, p_venta_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_pago public.pagos_venta%ROWTYPE;
  v_venta public.ventas%ROWTYPE;
  v_total_pagado numeric(14,2);
  v_saldo numeric(14,2);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND LOWER(TRIM(COALESCE(e.rol, ''))) IN ('admin', 'operador')
  ) THEN
    RAISE EXCEPTION 'Empleado inactivo o no autorizado';
  END IF;

  SELECT *
  INTO v_pago
  FROM public.pagos_venta
  WHERE id = p_pago_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true);
  END IF;

  IF v_pago.venta_id IS DISTINCT FROM p_venta_id THEN
    RAISE EXCEPTION 'El pago no pertenece a la venta indicada';
  END IF;

  SELECT *
  INTO v_venta
  FROM public.ventas
  WHERE id = p_venta_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'La venta no existe';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.comprobantes_electronicos ce
    WHERE ce.venta_id = p_venta_id
  ) THEN
    RAISE EXCEPTION
      'No se pueden modificar pagos de una venta con comprobante electrónico reservado';
  END IF;

  DELETE FROM public.pagos_venta
  WHERE id = p_pago_id;

  SELECT COALESCE(SUM(monto), 0)
  INTO v_total_pagado
  FROM public.pagos_venta
  WHERE venta_id = p_venta_id;

  v_saldo := GREATEST(
    ROUND(COALESCE(v_venta.total, 0) - v_total_pagado, 2),
    0
  );

  UPDATE public.ventas
  SET
    saldo = v_saldo,
    estado = CASE
      WHEN v_saldo <= 0.01 THEN 'pagado'
      ELSE 'pendiente'
    END
  WHERE id = p_venta_id;

  RETURN jsonb_build_object(
    'success', true,
    'venta_id', p_venta_id,
    'pago_id', p_pago_id,
    'saldo', v_saldo
  );
END;
$function$
;

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
  v_accion text := LOWER(TRIM(COALESCE(p_accion, 'emitir')));
BEGIN
  IF p_comprobante_id IS NULL THEN
    RAISE EXCEPTION 'comprobante_id es obligatorio';
  END IF;

  IF v_accion NOT IN ('emitir', 'reintentar', 'consultar') THEN
    RAISE EXCEPTION 'Acción de facturación inválida: %', v_accion;
  END IF;

  IF NOT COALESCE(p_sistema, false) THEN
    IF p_usuario_id IS NULL THEN
      RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.empleados AS e
      WHERE e.auth_id = p_usuario_id
        AND COALESCE(e.activo, false) = true
        AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'operador')
    ) THEN
      RAISE EXCEPTION 'Rol no autorizado para emitir comprobantes';
    END IF;
  END IF;

  SELECT
    ce.*,
    v.saldo AS venta_saldo,
    v.estado AS venta_estado,
    v.tipo_comprobante_solicitado,
    v.estado_facturacion AS venta_estado_facturacion
  INTO v_comp
  FROM public.comprobantes_electronicos AS ce
  JOIN public.ventas AS v
    ON v.id = ce.venta_id
  WHERE ce.id = p_comprobante_id
  FOR UPDATE OF ce, v;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Comprobante no encontrado';
  END IF;

  IF LOWER(COALESCE(v_comp.tipo_documento_sunat, ''))
     NOT IN ('factura', 'boleta') THEN
    RAISE EXCEPTION 'El registro no corresponde a factura o boleta';
  END IF;

  IF COALESCE(v_comp.venta_saldo, 0) > 0.01
     OR LOWER(COALESCE(v_comp.venta_estado, '')) <> 'pagado' THEN
    RAISE EXCEPTION
      'Las facturas y boletas electrónicas solo pueden emitirse al contado';
  END IF;

  IF LOWER(COALESCE(v_comp.tipo_comprobante_solicitado, ''))
     <> LOWER(COALESCE(v_comp.tipo_documento_sunat, '')) THEN
    RAISE EXCEPTION 'El tipo solicitado por la venta no coincide con el comprobante';
  END IF;

  IF LOWER(COALESCE(v_comp.estado, '')) = 'aceptado' THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'aceptado',
      'comprobante_id', v_comp.id,
      'mensaje', 'El comprobante ya fue aceptado'
    );
  END IF;

  IF LOWER(COALESCE(v_comp.estado, '')) = 'procesando'
     AND v_comp.bloqueo_expira_at IS NOT NULL
     AND v_comp.bloqueo_expira_at > now() THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'procesando',
      'comprobante_id', v_comp.id,
      'mensaje', 'El comprobante ya está siendo procesado'
    );
  END IF;

  IF LOWER(COALESCE(v_comp.estado, '')) = 'rechazado'
     AND NOT COALESCE(p_forzar, false) THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'rechazado',
      'comprobante_id', v_comp.id,
      'mensaje', COALESCE(
        v_comp.descripcion_sunat,
        'El comprobante fue rechazado y requiere revisión'
      )
    );
  END IF;

  IF LOWER(COALESCE(v_comp.estado, '')) NOT IN (
       'pendiente',
       'pendiente_envio',
       'pendiente_reintento',
       'procesando',
       'rechazado'
     ) THEN
    RAISE EXCEPTION
      'El comprobante se encuentra en un estado no procesable: %',
      v_comp.estado;
  END IF;

  v_numero_intento := COALESCE(v_comp.numero_reintentos, 0) + 1;

  UPDATE public.comprobantes_electronicos
  SET
    estado = 'procesando',
    numero_reintentos = v_numero_intento,
    ultimo_intento_at = now(),
    procesando_at = now(),
    bloqueo_token = v_token,
    bloqueo_expira_at = now() + interval '3 minutes',
    ultimo_intento_por = p_usuario_id,
    ultimo_error_tipo = NULL,
    ultimo_http_status = NULL
  WHERE id = p_comprobante_id;

  UPDATE public.ventas
  SET estado_facturacion = 'procesando'
  WHERE id = v_comp.venta_id;

  INSERT INTO public.facturacion_intentos(
    comprobante_id,
    numero_intento,
    resultado,
    accion,
    usuario_id,
    lock_token,
    fecha_inicio
  )
  VALUES (
    p_comprobante_id,
    v_numero_intento,
    'procesando',
    v_accion,
    p_usuario_id,
    v_token,
    now()
  )
  RETURNING id INTO v_intento_id;

  RETURN jsonb_build_object(
    'claimed', true,
    'estado', 'procesando',
    'comprobante_id', p_comprobante_id,
    'venta_id', v_comp.venta_id,
    'bloqueo_token', v_token,
    'intento_id', v_intento_id,
    'numero_intento', v_numero_intento
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_user_role()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_rol text;
BEGIN
  SELECT rol INTO v_rol FROM public.empleados WHERE auth_id = auth.uid();
  RETURN COALESCE(v_rol, 'operador');
END;
$function$
;

CREATE OR REPLACE FUNCTION public.guardar_cotizacion_v2(p_request_id uuid, p_cliente_id bigint, p_total numeric, p_fecha timestamp with time zone, p_observaciones text, p_validez_dias integer, p_detalles jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_cotizacion_id bigint;
  v_resultado jsonb;

  v_detalle jsonb;
  v_producto_id bigint;
  v_almacen_id bigint;
  v_cantidad integer;
  v_tipo_unidad text;

  v_producto_nombre text;
  v_codigo text;
  v_tipo_venta text;
  v_pcs integer;
  v_unidad_base text;

  v_piezas_reales integer;
  v_piezas_enviadas integer;
  v_precio_comercial numeric;
  v_precio_base numeric;
  v_subtotal numeric;
  v_subtotal_calculado numeric := 0;

  v_clave_detalle text;
  v_claves_procesadas text[] := '{}';
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION
      'Acceso denegado: usuario no autenticado.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.empleados AS e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND LOWER(COALESCE(e.rol, '')) IN (
        'admin',
        'administrador',
        'operador',
        'supervisor',
        'almacenero'
      )
  ) THEN
    RAISE EXCEPTION
      'Acceso denegado: rol no autorizado para crear cotizaciones.';
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION
      'request_id es obligatorio.';
  END IF;

  IF p_cliente_id IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM public.clientes AS c
       WHERE c.id = p_cliente_id
     ) THEN
    RAISE EXCEPTION
      'El cliente seleccionado no existe.';
  END IF;

  IF p_total IS NULL OR p_total <= 0 THEN
    RAISE EXCEPTION
      'El total de la cotización debe ser mayor a cero.';
  END IF;

  IF COALESCE(p_validez_dias, 0) NOT BETWEEN 1 AND 3650 THEN
    RAISE EXCEPTION
      'La validez debe estar entre 1 y 3650 días.';
  END IF;

  IF p_detalles IS NULL
     OR jsonb_typeof(p_detalles) <> 'array'
     OR jsonb_array_length(p_detalles) = 0 THEN
    RAISE EXCEPTION
      'La cotización debe contener al menos un producto.';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_request_id::text, 0)
  );

  SELECT
    c.id,
    jsonb_build_object(
      'success', true,
      'cotizacion_id', c.id,
      'request_id', c.request_id,
      'mensaje', 'Cotización ya procesada previamente'
    )
  INTO
    v_cotizacion_id,
    v_resultado
  FROM public.cotizaciones AS c
  WHERE c.request_id = p_request_id;

  IF FOUND THEN
    RETURN v_resultado;
  END IF;

  INSERT INTO public.cotizaciones (
    cliente_id,
    fecha,
    total,
    estado,
    observaciones,
    validez_dias,
    request_id,
    creado_por
  )
  VALUES (
    p_cliente_id,
    COALESCE(p_fecha, now()),
    p_total,
    'pendiente',
    NULLIF(TRIM(COALESCE(p_observaciones, '')), ''),
    p_validez_dias,
    p_request_id,
    auth.uid()
  )
  RETURNING id INTO v_cotizacion_id;

  FOR v_detalle IN
    SELECT value
    FROM jsonb_array_elements(p_detalles)
  LOOP
    IF jsonb_typeof(v_detalle) <> 'object' THEN
      RAISE EXCEPTION
        'Cada detalle debe ser un objeto JSON.';
    END IF;

    v_producto_id :=
      NULLIF(v_detalle->>'producto_id', '')::bigint;

    v_almacen_id :=
      NULLIF(v_detalle->>'almacen_id', '')::bigint;

    v_cantidad :=
      COALESCE(
        NULLIF(v_detalle->>'cantidad', '')::integer,
        0
      );

    IF v_producto_id IS NULL
       OR v_almacen_id IS NULL
       OR v_cantidad <= 0 THEN
      RAISE EXCEPTION
        'Hay un detalle incompleto o con cantidad inválida.';
    END IF;

    SELECT
      p.nombre,
      p.codigo,
      public._normalizar_tipo_venta_documento(p.tipo_venta),
      GREATEST(COALESCE(p.cantidad_por_caja, 1), 1)
    INTO
      v_producto_nombre,
      v_codigo,
      v_tipo_venta,
      v_pcs
    FROM public.productos AS p
    WHERE p.id = v_producto_id
      AND COALESCE(p.activo, true) = true;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'El producto % no existe o está inactivo.',
        v_producto_id;
    END IF;

    IF v_tipo_venta NOT IN (
      'PAQUETES',
      'CAJA_PAQUETES',
      'CAJA_UNIDADES'
    ) THEN
      RAISE EXCEPTION
        'Tipo de venta no compatible para %: %.',
        v_producto_nombre,
        v_tipo_venta;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.almacenes AS a
      WHERE a.id = v_almacen_id
        AND COALESCE(a.activo, false) = true
    ) THEN
      RAISE EXCEPTION
        'El almacén % no existe o está inactivo.',
        v_almacen_id;
    END IF;

    v_tipo_unidad :=
      CASE LOWER(TRIM(COALESCE(v_detalle->>'tipo_unidad', '')))
        WHEN 'caja' THEN 'caja'
        WHEN 'cajas' THEN 'caja'
        WHEN 'box' THEN 'caja'
        WHEN 'paquete' THEN 'paquete'
        WHEN 'paquetes' THEN 'paquete'
        WHEN 'paq' THEN 'paquete'
        WHEN 'unidad' THEN 'unidad'
        WHEN 'unidades' THEN 'unidad'
        WHEN 'und' THEN 'unidad'
        ELSE ''
      END;

    IF v_tipo_unidad = '' THEN
      RAISE EXCEPTION
        'La presentación comercial de % no es válida.',
        v_producto_nombre;
    END IF;

    IF v_tipo_venta = 'PAQUETES'
       AND v_tipo_unidad <> 'paquete' THEN
      RAISE EXCEPTION
        '% solo puede cotizarse por paquete.',
        v_producto_nombre;
    END IF;

    IF v_tipo_venta = 'CAJA_PAQUETES'
       AND v_tipo_unidad NOT IN ('caja', 'paquete') THEN
      RAISE EXCEPTION
        '% solo puede cotizarse por caja o paquete.',
        v_producto_nombre;
    END IF;

    IF v_tipo_venta = 'CAJA_UNIDADES'
       AND v_tipo_unidad NOT IN ('caja', 'unidad') THEN
      RAISE EXCEPTION
        '% solo puede cotizarse por caja o unidad.',
        v_producto_nombre;
    END IF;

    v_piezas_reales :=
      CASE
        WHEN v_tipo_unidad = 'caja'
          THEN v_cantidad * v_pcs
        ELSE v_cantidad
      END;

    v_piezas_enviadas :=
      NULLIF(v_detalle->>'piezas_reales', '')::integer;

    IF v_piezas_enviadas IS NOT NULL
       AND v_piezas_enviadas <> v_piezas_reales THEN
      RAISE EXCEPTION
        'La cantidad base enviada para % no coincide. Esperado: %, recibido: %.',
        v_producto_nombre,
        v_piezas_reales,
        v_piezas_enviadas;
    END IF;

    v_subtotal :=
      COALESCE(
        NULLIF(v_detalle->>'subtotal', '')::numeric,
        0
      );

    v_precio_comercial :=
      COALESCE(
        NULLIF(v_detalle->>'precio_unitario_comercial', '')::numeric,
        CASE
          WHEN v_cantidad > 0 THEN v_subtotal / v_cantidad
          ELSE 0
        END
      );

    v_precio_base :=
      COALESCE(
        NULLIF(v_detalle->>'precio_unitario', '')::numeric,
        CASE
          WHEN v_piezas_reales > 0 THEN v_subtotal / v_piezas_reales
          ELSE 0
        END
      );

    IF v_subtotal <= 0
       OR v_precio_comercial <= 0
       OR v_precio_base <= 0 THEN
      RAISE EXCEPTION
        'Los precios de % deben ser mayores a cero.',
        v_producto_nombre;
    END IF;

    IF ABS(
      v_subtotal - (v_cantidad * v_precio_comercial)
    ) > 0.02 THEN
      RAISE EXCEPTION
        'El subtotal comercial de % es inconsistente.',
        v_producto_nombre;
    END IF;

    IF ABS(
      v_subtotal - (v_piezas_reales * v_precio_base)
    ) > 0.02 THEN
      RAISE EXCEPTION
        'El precio por unidad base de % es inconsistente.',
        v_producto_nombre;
    END IF;

    v_clave_detalle :=
      v_producto_id::text || ':' ||
      v_almacen_id::text || ':' ||
      v_tipo_unidad;

    IF v_clave_detalle = ANY(v_claves_procesadas) THEN
      RAISE EXCEPTION
        'El producto % está repetido para el mismo almacén y presentación.',
        v_producto_nombre;
    END IF;

    v_claves_procesadas :=
      array_append(v_claves_procesadas, v_clave_detalle);

    v_unidad_base :=
      CASE
        WHEN v_tipo_venta IN ('PAQUETES', 'CAJA_PAQUETES')
          THEN 'Paquete'
        ELSE 'Unidad'
      END;

    INSERT INTO public.detalle_cotizaciones (
      cotizacion_id,
      producto_id,
      cantidad,
      precio_unitario,
      precio_unitario_comercial,
      subtotal,
      almacen_id,
      tipo_unidad,
      piezas_reales,
      tipo_venta_snapshot,
      pcs_snapshot,
      unidad_base_snapshot,
      producto_nombre_snapshot,
      codigo_snapshot
    )
    VALUES (
      v_cotizacion_id,
      v_producto_id,
      v_cantidad,
      v_precio_base,
      v_precio_comercial,
      v_subtotal,
      v_almacen_id,
      v_tipo_unidad,
      v_piezas_reales,
      v_tipo_venta,
      v_pcs,
      v_unidad_base,
      v_producto_nombre,
      NULLIF(TRIM(v_codigo), '')
    );

    v_subtotal_calculado :=
      v_subtotal_calculado + v_subtotal;
  END LOOP;

  IF ABS(v_subtotal_calculado - p_total) > 0.02 THEN
    RAISE EXCEPTION
      'El total no coincide con los detalles. Cabecera: %, detalles: %.',
      p_total,
      v_subtotal_calculado;
  END IF;

  v_resultado := jsonb_build_object(
    'success', true,
    'cotizacion_id', v_cotizacion_id,
    'request_id', p_request_id,
    'total', v_subtotal_calculado,
    'mensaje', 'Cotización guardada correctamente'
  );

  RETURN v_resultado;
END;
$function$
;

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
        'admin', 'administrador', 'operador'
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
;

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
BEGIN
  IF v_accion NOT IN ('emitir', 'reintentar') THEN
    RAISE EXCEPTION 'Acción inválida: %', v_accion;
  END IF;

  IF NOT COALESCE(p_sistema, false) THEN
    IF p_usuario_id IS NULL THEN
      RAISE EXCEPTION 'Usuario no autenticado';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.empleados AS e
      WHERE e.auth_id = p_usuario_id
        AND COALESCE(e.activo, false) = true
        AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'operador')
    ) THEN
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

  IF v_nota.estado = 'resultado_incierto'
     AND NOT COALESCE(p_forzar, false) THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'resultado_incierto',
      'mensaje', COALESCE(
        v_nota.descripcion_sunat,
        'El resultado remoto es incierto. Verifique la validez antes de forzar un reenvío'
      )
    );
  END IF;

  IF v_nota.estado = 'resultado_incierto'
     AND COALESCE(p_forzar, false) THEN
    IF COALESCE(p_sistema, false) OR NOT EXISTS (
      SELECT 1
      FROM public.empleados AS e
      WHERE e.auth_id = p_usuario_id
        AND COALESCE(e.activo, false) = true
        AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'administrador')
    ) THEN
      RAISE EXCEPTION
        'Solo un administrador puede forzar el reenvío de una nota con resultado incierto';
    END IF;
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

  -- Antes de forzar una nota rechazada o incierta volvemos a validar que
  -- otras notas posteriores no hayan consumido el saldo o las cantidades.
  IF v_nota.estado IN ('rechazado', 'resultado_incierto')
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
    'resultado_incierto',
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
;

CREATE OR REPLACE FUNCTION public.obtener_disponibilidad_nota_credito(p_comprobante_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_comp record;
  v_detalles jsonb;
  v_notas jsonb;
  v_total_comprometido numeric(14,2);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.empleados AS e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND LOWER(COALESCE(e.rol, '')) IN (
        'admin', 'administrador', 'operador'
      )
  ) THEN
    RAISE EXCEPTION 'Empleado inactivo o rol no autorizado';
  END IF;

  SELECT
    ce.*,
    v.total AS venta_total,
    v.fecha AS venta_fecha,
    v.estado_tributario,
    c.id AS cliente_id,
    c.nombre AS cliente_nombre,
    c.dni_ruc AS cliente_documento,
    c.tipo_doc AS cliente_tipo_doc,
    c.direccion AS cliente_direccion
  INTO v_comp
  FROM public.comprobantes_electronicos AS ce
  JOIN public.ventas AS v ON v.id = ce.venta_id
  LEFT JOIN public.clientes AS c ON c.id = v.cliente_id
  WHERE ce.id = p_comprobante_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Comprobante no encontrado';
  END IF;

  SELECT COALESCE(SUM(nc.total), 0)
  INTO v_total_comprometido
  FROM public.notas_credito AS nc
  WHERE nc.comprobante_id = p_comprobante_id
    AND nc.afecta_dinero = true
    AND nc.estado IN (
      'pendiente_envio',
      'procesando',
      'pendiente_reintento',
      'resultado_incierto',
      'aceptado'
    );

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'detalle_venta_id', dv.id,
        'producto_id', dv.producto_id,
        'almacen_id', dv.almacen_id,
        'codigo', p.codigo,
        'nombre', p.nombre,
        'cantidad_original', dv.cantidad,
        'cantidad_comprometida', COALESCE(r.cantidad, 0),
        'cantidad_disponible', GREATEST(
          dv.cantidad - COALESCE(r.cantidad, 0),
          0
        ),
        'piezas_reales', COALESCE(dv.piezas_reales, dv.cantidad),
        'tipo_unidad', COALESCE(dv.tipo_unidad, 'unidad'),
        'precio_unitario_comercial', COALESCE(
          dv.precio_unitario_comercial,
          CASE
            WHEN dv.cantidad > 0 THEN
              COALESCE(NULLIF(dv.subtotal_final, 0), dv.subtotal) / dv.cantidad
            ELSE 0
          END
        ),
        'subtotal', COALESCE(NULLIF(dv.subtotal_final, 0), dv.subtotal),
        'tipo_venta_snapshot', dv.tipo_venta_snapshot,
        'pcs_snapshot', dv.pcs_snapshot,
        'unidad_base_snapshot', dv.unidad_base_snapshot
      )
      ORDER BY dv.id
    ),
    '[]'::jsonb
  )
  INTO v_detalles
  FROM public.detalle_ventas AS dv
  JOIN public.productos AS p ON p.id = dv.producto_id
  LEFT JOIN LATERAL (
    SELECT SUM(ncd.cantidad_visual)::integer AS cantidad
    FROM public.notas_credito_detalles AS ncd
    JOIN public.notas_credito AS nc
      ON nc.id = ncd.nota_credito_id
    WHERE ncd.detalle_venta_id = dv.id
      AND nc.afecta_stock = true
      AND nc.estado IN (
        'pendiente_envio',
        'procesando',
        'pendiente_reintento',
        'resultado_incierto',
        'aceptado'
      )
  ) AS r ON true
  WHERE dv.venta_id = v_comp.venta_id;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', nc.id,
        'serie', nc.serie,
        'correlativo', nc.correlativo,
        'motivo_codigo', nc.motivo_codigo,
        'motivo_descripcion', nc.motivo_descripcion,
        'estado', nc.estado,
        'total', nc.total,
        'codigo_sunat', nc.codigo_sunat,
        'descripcion_sunat', nc.descripcion_sunat,
        'aceptado_at', nc.aceptado_at
      )
      ORDER BY nc.created_at DESC
    ),
    '[]'::jsonb
  )
  INTO v_notas
  FROM public.notas_credito AS nc
  WHERE nc.comprobante_id = p_comprobante_id;

  RETURN jsonb_build_object(
    'comprobante', jsonb_build_object(
      'id', v_comp.id,
      'venta_id', v_comp.venta_id,
      'tipo_documento_sunat', v_comp.tipo_documento_sunat,
      'serie', v_comp.serie,
      'correlativo', v_comp.correlativo,
      'estado', v_comp.estado,
      'total', v_comp.total,
      'cliente_nombre', COALESCE(
        v_comp.cliente_razon_social,
        v_comp.cliente_nombre,
        'Cliente General'
      ),
      'cliente_documento', COALESCE(
        v_comp.cliente_numero_documento,
        v_comp.cliente_documento,
        ''
      )
    ),
    'detalles', v_detalles,
    'notas', v_notas,
    'total_comprometido', ROUND(v_total_comprometido, 2),
    'total_disponible', GREATEST(
      ROUND(COALESCE(v_comp.total, 0) - v_total_comprometido, 2),
      0
    )
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.process_sale(p_cliente_id bigint, p_total numeric, p_fecha timestamp with time zone, p_es_credito boolean, p_monto_abono numeric, p_detalles jsonb, p_pagos jsonb, p_cotizacion_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  venta_id BIGINT;
  detalle JSONB;
  pago JSONB;
  v_prod_id BIGINT;
  v_cantidad_visual INT;
  v_piezas_reales INT;
  v_almacen_id BIGINT;
  v_unidad_label TEXT;
  v_precio_unitario NUMERIC;
  v_subtotal NUMERIC;
  v_tipo_unidad TEXT;
  stock_actual INT;
  v_prod_nombre TEXT;
  v_prod_pcs INT;
  v_proveedor_nombre TEXT;
  v_almacen_nombre TEXT;
  v_cliente_nombre TEXT;
  v_saldo_actual INT;
  v_permitir_sin_stock BOOLEAN;
BEGIN
  -- 1. Crear venta
  INSERT INTO ventas (cliente_id, total, fecha, estado, saldo)
  VALUES (
    p_cliente_id,
    p_total,
    p_fecha,
    CASE WHEN p_es_credito THEN 'pendiente' ELSE 'pagado' END,
    CASE WHEN p_es_credito THEN p_total - p_monto_abono ELSE 0 END
  )
  RETURNING id INTO venta_id;

  -- 2. Si vino de una cotizacion, marcarla como aprobada
  IF p_cotizacion_id IS NOT NULL THEN
    UPDATE cotizaciones SET estado = 'aprobada' WHERE id = p_cotizacion_id;
  END IF;

  -- 3. Insertar pagos
  IF p_pagos IS NOT NULL THEN
    FOR pago IN SELECT * FROM jsonb_array_elements(p_pagos) LOOP
      INSERT INTO pagos_venta (venta_id, metodo, monto, fecha)
      VALUES (
        venta_id,
        pago->>'metodo',
        (pago->>'monto')::NUMERIC,
        p_fecha
      );
    END LOOP;
  END IF;

  -- Obtener nombre del cliente para Kardex
  SELECT nombre INTO v_cliente_nombre
  FROM clientes
  WHERE id = p_cliente_id;
  IF v_cliente_nombre IS NULL THEN
    v_cliente_nombre := 'Publico General';
  END IF;

  -- 4. Procesar detalles + descontar stock + registrar Kardex
  FOR detalle IN SELECT * FROM jsonb_array_elements(p_detalles) LOOP
    v_prod_id        := (detalle->>'producto_id')::BIGINT;
    v_cantidad_visual := (detalle->>'cantidad')::INT;
    v_almacen_id     := (detalle->>'almacen_id')::BIGINT;
    v_precio_unitario := (detalle->>'precio_unitario')::NUMERIC;
    v_subtotal       := (detalle->>'subtotal')::NUMERIC;
    v_tipo_unidad    := COALESCE(detalle->>'tipo_unidad', 'unidad');
    v_unidad_label   := COALESCE(detalle->>'unidadLabel', 'Und');

    -- Leer piezas_reales (nueva clave), fallback a cantidad si no existe
    v_piezas_reales  := COALESCE((detalle->>'piezas_reales')::INT, v_cantidad_visual);

    -- Insertar detalle de venta (cantidad visual para referencia)
    INSERT INTO detalle_ventas (venta_id, producto_id, cantidad, precio_unitario, subtotal, almacen_id, tipo_unidad)
    VALUES (
      venta_id,
      v_prod_id,
      v_cantidad_visual,
      v_precio_unitario,
      v_subtotal,
      v_almacen_id,
      v_tipo_unidad
    );

    -- Obtener datos del producto para Kardex y para saber si permite sin stock
    SELECT
      p.nombre,
      COALESCE(p.cantidad_por_caja, 1),
      COALESCE(pr.nombre, 'Generico'),
      COALESCE(p.permitir_sin_stock, false)
    INTO v_prod_nombre, v_prod_pcs, v_proveedor_nombre, v_permitir_sin_stock
    FROM productos p
    LEFT JOIN proveedores pr ON p.proveedor_id = pr.id
    WHERE p.id = v_prod_id;

    -- Verificar stock suficiente (con bloqueo de fila)
    SELECT cantidad INTO stock_actual
    FROM inventario_almacen
    WHERE producto_id = v_prod_id AND almacen_id = v_almacen_id
    FOR UPDATE;

    -- Si no existe fila en inventario_almacen
    IF stock_actual IS NULL THEN
      IF NOT v_permitir_sin_stock THEN
        RAISE EXCEPTION 'Stock no encontrado para producto % en almacen %', v_prod_id, v_almacen_id;
      ELSE
        -- Si permite sin stock, creamos la fila con 0 para luego descontar
        INSERT INTO inventario_almacen (producto_id, almacen_id, cantidad)
        VALUES (v_prod_id, v_almacen_id, 0);
        stock_actual := 0;
      END IF;
    END IF;

    -- Si el stock no alcanza
    IF stock_actual < v_piezas_reales THEN
      IF NOT v_permitir_sin_stock THEN
        RAISE EXCEPTION 'Stock insuficiente para producto %. Disponible: %, Requerido: %',
          v_prod_nombre, stock_actual, v_piezas_reales;
      END IF;
      -- Si permite sin stock, simplemente avanza y quedará negativo.
    END IF;

    -- Descontar stock con piezas_reales (cantidad real de piezas)
    UPDATE inventario_almacen
    SET cantidad = cantidad - v_piezas_reales
    WHERE producto_id = v_prod_id AND almacen_id = v_almacen_id;

    -- Obtener saldo despues del descuento
    v_saldo_actual := stock_actual - v_piezas_reales;

    -- Obtener nombre del almacen
    SELECT nombre INTO v_almacen_nombre
    FROM almacenes
    WHERE id = v_almacen_id;

    -- Registrar en Kardex (inventario_movimientos) - ATOMICO
    INSERT INTO inventario_movimientos (
      fecha,
      producto_id,
      producto_nombre,
      pcs,
      proveedor,
      tipo,
      saldo,
      almacen_id,
      almacen_nombre,
      observaciones,
      salida_cant,
      salida_und,
      salida_cliente,
      salida_p_unit,
      salida_total
    ) VALUES (
      NOW(),
      v_prod_id,
      v_prod_nombre,
      v_prod_pcs,
      v_proveedor_nombre,
      'SALIDA',
      v_saldo_actual,
      v_almacen_id,
      COALESCE(v_almacen_nombre, ''),
      'Venta #' || venta_id,
      v_piezas_reales,
      v_unidad_label,
      v_cliente_nombre,
      v_precio_unitario,
      v_subtotal
    );
  END LOOP;

  RETURN jsonb_build_object('success', true, 'venta_id', venta_id);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.process_sale(p_cliente_id bigint, p_total numeric, p_fecha timestamp without time zone, p_es_credito boolean, p_monto_abono numeric, p_detalles jsonb, p_pagos jsonb, p_cotizacion_id bigint DEFAULT NULL::bigint, p_vendedor_id bigint DEFAULT NULL::bigint, p_tipo_comprobante text DEFAULT 'ticket_interno'::text, p_descuento_global_porcentaje numeric DEFAULT 0, p_descuento_global_monto numeric DEFAULT 0, p_motivo_descuento text DEFAULT NULL::text, p_subtotal_bruto numeric DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  venta_id BIGINT;
  detalle JSONB;
  pago JSONB;
  v_prod_id BIGINT;
  v_cantidad_visual INT;
  v_piezas_reales INT;
  v_almacen_id BIGINT;
  v_unidad_label TEXT;
  v_precio_unitario NUMERIC;
  v_subtotal NUMERIC;
  v_tipo_unidad TEXT;
  stock_actual INT;
  v_prod_nombre TEXT;
  v_prod_pcs INT;
  v_proveedor_nombre TEXT;
  v_almacen_nombre TEXT;
  v_cliente_nombre TEXT;
  v_saldo_actual INT;
  v_permitir_sin_stock BOOLEAN;
  v_estado_facturacion TEXT;
  v_correlativo BIGINT;
  v_serie TEXT;
  v_comprobante_id UUID;
  v_constancia_codigo TEXT;
BEGIN
  -- Definir estado de facturacion
  IF p_tipo_comprobante = 'ticket_interno' THEN
    v_estado_facturacion := 'no_aplica';
  ELSE
    v_estado_facturacion := 'pendiente';
  END IF;

  -- Si no envían subtotal bruto, se asume que es igual al total (sin descuento)
  IF p_subtotal_bruto = 0 THEN
    p_subtotal_bruto := p_total;
  END IF;

  -- 1. Crear venta
  INSERT INTO ventas (
    cliente_id, 
    total, 
    fecha, 
    estado, 
    saldo,
    -- Nuevos campos de Facturación y Descuentos
    vendedor_id,
    tipo_comprobante_solicitado,
    estado_facturacion,
    subtotal_bruto,
    descuento_global_porcentaje,
    descuento_global_monto,
    motivo_descuento
  )
  VALUES (
    p_cliente_id,
    p_total,
    p_fecha,
    CASE WHEN p_es_credito THEN 'pendiente' ELSE 'pagado' END,
    CASE WHEN p_es_credito THEN p_total - p_monto_abono ELSE 0 END,
    -- Nuevos campos
    p_vendedor_id,
    p_tipo_comprobante,
    v_estado_facturacion,
    p_subtotal_bruto,
    p_descuento_global_porcentaje,
    p_descuento_global_monto,
    p_motivo_descuento
  )
  RETURNING id INTO venta_id;

  -- 2. Si vino de una cotizacion, marcarla como aprobada
  IF p_cotizacion_id IS NOT NULL THEN
    UPDATE cotizaciones SET estado = 'aprobada' WHERE id = p_cotizacion_id;
  END IF;

  -- 3. Insertar pagos
  IF p_pagos IS NOT NULL THEN
    FOR pago IN SELECT * FROM jsonb_array_elements(p_pagos) LOOP
      INSERT INTO pagos_venta (venta_id, metodo, monto, fecha)
      VALUES (
        venta_id,
        pago->>'metodo',
        (pago->>'monto')::NUMERIC,
        p_fecha
      );
    END LOOP;
  END IF;

  -- Obtener nombre del cliente para Kardex
  SELECT nombre INTO v_cliente_nombre
  FROM clientes
  WHERE id = p_cliente_id;
  IF v_cliente_nombre IS NULL THEN
    v_cliente_nombre := 'Publico General';
  END IF;

  -- 4. Procesar detalles + descontar stock + registrar Kardex
  FOR detalle IN SELECT * FROM jsonb_array_elements(p_detalles) LOOP
    v_prod_id        := (detalle->>'producto_id')::BIGINT;
    v_cantidad_visual := (detalle->>'cantidad')::INT;
    v_almacen_id     := (detalle->>'almacen_id')::BIGINT;
    v_precio_unitario := (detalle->>'precio_unitario')::NUMERIC;
    v_subtotal       := (detalle->>'subtotal')::NUMERIC;
    v_tipo_unidad    := COALESCE(detalle->>'tipo_unidad', 'unidad');
    v_unidad_label   := COALESCE(detalle->>'unidadLabel', 'Und');

    -- Leer piezas_reales (nueva clave), fallback a cantidad si no existe
    v_piezas_reales  := COALESCE((detalle->>'piezas_reales')::INT, v_cantidad_visual);

    -- Insertar detalle de venta (cantidad visual para referencia)
    INSERT INTO detalle_ventas (venta_id, producto_id, cantidad, precio_unitario, subtotal, almacen_id, tipo_unidad)
    VALUES (
      venta_id,
      v_prod_id,
      v_cantidad_visual,
      v_precio_unitario,
      v_subtotal,
      v_almacen_id,
      v_tipo_unidad
    );

    -- Obtener datos del producto para Kardex y saber si permite sin stock
    SELECT
      p.nombre,
      COALESCE(p.cantidad_por_caja, 1),
      COALESCE(pr.nombre, 'Generico'),
      COALESCE(p.permitir_sin_stock, false)
    INTO v_prod_nombre, v_prod_pcs, v_proveedor_nombre, v_permitir_sin_stock
    FROM productos p
    LEFT JOIN proveedores pr ON p.proveedor_id = pr.id
    WHERE p.id = v_prod_id;

    -- Verificar stock suficiente (con bloqueo de fila: FOR UPDATE)
    SELECT cantidad INTO stock_actual
    FROM inventario_almacen
    WHERE producto_id = v_prod_id AND almacen_id = v_almacen_id
    FOR UPDATE;

    -- Si no existe fila en inventario_almacen
    IF stock_actual IS NULL THEN
      IF NOT v_permitir_sin_stock THEN
        RAISE EXCEPTION 'Stock no encontrado para producto % en almacen %', v_prod_id, v_almacen_id;
      ELSE
        -- Si permite sin stock, creamos la fila con 0 para luego descontar
        INSERT INTO inventario_almacen (producto_id, almacen_id, cantidad)
        VALUES (v_prod_id, v_almacen_id, 0);
        stock_actual := 0;
      END IF;
    END IF;

    -- Si el stock no alcanza
    IF stock_actual < v_piezas_reales THEN
      IF NOT v_permitir_sin_stock THEN
        RAISE EXCEPTION 'Stock insuficiente para producto %. Disponible: %, Requerido: %',
          v_prod_nombre, stock_actual, v_piezas_reales;
      END IF;
    END IF;

    -- Descontar stock con piezas_reales (cantidad real de piezas)
    UPDATE inventario_almacen
    SET cantidad = cantidad - v_piezas_reales
    WHERE producto_id = v_prod_id AND almacen_id = v_almacen_id;

    -- Obtener saldo despues del descuento
    v_saldo_actual := stock_actual - v_piezas_reales;

    -- Obtener nombre del almacen
    SELECT nombre INTO v_almacen_nombre
    FROM almacenes
    WHERE id = v_almacen_id;

    -- Registrar en Kardex (inventario_movimientos) - ATOMICO
    INSERT INTO inventario_movimientos (
      fecha,
      producto_id,
      producto_nombre,
      pcs,
      proveedor,
      tipo,
      saldo,
      almacen_id,
      almacen_nombre,
      observaciones,
      salida_cant,
      salida_und,
      salida_cliente,
      salida_p_unit,
      salida_total
    ) VALUES (
      NOW(),
      v_prod_id,
      v_prod_nombre,
      v_prod_pcs,
      v_proveedor_nombre,
      'SALIDA',
      v_saldo_actual,
      v_almacen_id,
      COALESCE(v_almacen_nombre, ''),
      'Venta #' || venta_id,
      v_piezas_reales,
      v_unidad_label,
      v_cliente_nombre,
      v_precio_unitario,
      v_subtotal
    );
  END LOOP;

  -- 5. Generar Constancia Interna de Descuento (Si aplica)
  IF p_descuento_global_monto > 0 THEN
    v_constancia_codigo := 'DESC-' || to_char(NOW(), 'YYMMDD') || '-' || lpad(venta_id::text, 4, '0');
    
    INSERT INTO constancias_descuento (
      venta_id, 
      codigo, 
      subtotal_bruto, 
      descuento_porcentaje, 
      descuento_monto, 
      total_final, 
      motivo, 
      aplicado_por
    ) VALUES (
      venta_id, 
      v_constancia_codigo, 
      p_subtotal_bruto, 
      p_descuento_global_porcentaje, 
      p_descuento_global_monto, 
      p_total, 
      p_motivo_descuento, 
      p_vendedor_id
    );
  END IF;

  -- 6. Generar Comprobante Electrónico Pendiente y Reservar Correlativo (Si es Boleta/Factura)
  IF p_tipo_comprobante IN ('boleta', 'factura') THEN
    
    -- Leemos la serie activa bloqueando la fila
    SELECT serie, ultimo_correlativo INTO v_serie, v_correlativo
    FROM series_comprobantes
    WHERE tipo_documento_sunat = p_tipo_comprobante AND activo = true
    LIMIT 1
    FOR UPDATE;

    IF v_serie IS NULL THEN
       RAISE EXCEPTION 'No hay una serie activa configurada para %', p_tipo_comprobante;
    END IF;

    -- Incrementar el correlativo atómicamente
    v_correlativo := v_correlativo + 1;
    
    UPDATE series_comprobantes 
    SET ultimo_correlativo = v_correlativo 
    WHERE tipo_documento_sunat = p_tipo_comprobante AND serie = v_serie;

    -- Insertar en comprobantes_electronicos
    INSERT INTO comprobantes_electronicos (
      venta_id,
      tipo_documento_sunat,
      serie,
      correlativo,
      fecha_emision,
      estado,
      subtotal_bruto,
      descuento_global_porcentaje,
      descuento_global_monto,
      total
    ) VALUES (
      venta_id,
      p_tipo_comprobante,
      v_serie,
      v_correlativo,
      CURRENT_DATE,
      'pendiente',
      p_subtotal_bruto,
      p_descuento_global_porcentaje,
      p_descuento_global_monto,
      p_total
    ) RETURNING id INTO v_comprobante_id;
    
    -- Asociar la constancia de descuento al comprobante
    IF p_descuento_global_monto > 0 THEN
       UPDATE constancias_descuento SET comprobante_id = v_comprobante_id WHERE venta_id = venta_id;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'success', true, 
    'venta_id', venta_id, 
    'comprobante_id', v_comprobante_id
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.process_sale_v3(p_request_id uuid, p_cliente_id bigint, p_total numeric, p_fecha timestamp with time zone, p_es_credito boolean, p_monto_abono numeric, p_detalles jsonb, p_pagos jsonb, p_cotizacion_id bigint, p_vendedor_id bigint, p_tipo_comprobante text, p_descuento_global_porcentaje numeric, p_descuento_global_monto numeric, p_motivo_descuento text, p_subtotal_bruto numeric, p_descuento_autorizado_por bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  -- Datos normalizados
  v_detalles jsonb := COALESCE(p_detalles, '[]'::jsonb);
  v_pagos jsonb := COALESCE(p_pagos, '[]'::jsonb);

  v_tipo_comprobante text :=
    LOWER(TRIM(COALESCE(p_tipo_comprobante, 'ticket_interno')));

  v_fecha timestamp with time zone := COALESCE(p_fecha, now());
  v_fecha_emision date;

  -- Idempotencia
  v_existing_venta_id bigint;
  v_existing_total numeric;
  v_existing_tipo text;
  v_existing_comprobante_id uuid;
  v_existing_serie text;
  v_existing_correlativo bigint;
  v_existing_estado text;

  -- Venta
  v_venta_id bigint;
  v_comprobante_id uuid;
  v_vendedor_id bigint;
  v_vendedor_nombre text;
  v_vendedor_rol text;
  v_autorizado_por bigint;
  v_autorizador_rol text;

  v_estado_venta text;
  v_estado_facturacion text;
  v_saldo numeric(14,2);

  -- Totales
  v_subtotal_calculado numeric(14,2) := 0;
  v_subtotal_reportado numeric(14,2);
  v_descuento_porcentaje numeric(7,4) :=
    COALESCE(p_descuento_global_porcentaje, 0);
  v_descuento_monto numeric(14,2) :=
    COALESCE(p_descuento_global_monto, 0);
  v_descuento_esperado numeric(14,2);
  v_total_final numeric(14,2);

  v_total_pagos numeric(14,2) := 0;
  v_monto_abono numeric(14,2) := ROUND(COALESCE(p_monto_abono, 0), 2);

  v_base_imponible numeric(14,2) := 0;
  v_igv numeric(14,2) := 0;
  v_porcentaje_igv numeric(5,2) := 18.00;
  v_factor_igv numeric;

  -- Configuración
  v_config_encontrada boolean := false;
  v_facturacion_habilitada boolean := false;
  v_precios_incluyen_igv boolean := true;

  v_descuento_sin_autorizacion_hasta numeric(7,4) := 10.0000;
  v_descuento_con_motivo_desde numeric(7,4) := 10.0000;
  v_descuento_con_pin_desde numeric(7,4) := 30.0000;
  v_generar_constancia boolean := true;

  -- Empresa
  v_empresa_ruc text;
  v_empresa_razon_social text;
  v_empresa_nombre_comercial text;
  v_empresa_direccion text;
  v_empresa_ubigeo text;
  v_empresa_departamento text;
  v_empresa_provincia text;
  v_empresa_distrito text;
  v_empresa_cod_local text;
  v_empresa_telefono text;
  v_empresa_logo_url text;

  -- Cliente
  v_cliente_nombre text;
  v_cliente_documento text;
  v_cliente_tipo_doc_db text;
  v_cliente_tipo_sunat text;
  v_cliente_direccion text;

  -- Series
  v_serie_id uuid;
  v_serie text;
  v_correlativo bigint;

  -- Detalles
  v_detalle jsonb;
  v_ordinal integer;
  v_num_detalles integer;

  v_prod_id bigint;
  v_prod_nombre text;
  v_prod_pcs integer;
  v_prod_tipo_venta text;
  v_proveedor_nombre text;
  v_permitir_sin_stock boolean;

  v_almacen_id bigint;
  v_almacen_nombre text;

  v_cantidad_visual integer;
  v_piezas_calculadas integer;
  v_piezas_enviadas integer;

  v_tipo_unidad text;
  v_unidad_label text;

  -- Precio base por pieza/unidad mínima.
  v_precio_unitario numeric(14,4);

  -- Precio de la unidad comercial elegida:
  -- caja completa o unidad suelta.
  v_precio_unitario_comercial numeric(14,4);

  -- Precio de la unidad base de stock después del descuento global.
  v_precio_unitario_final numeric(14,4);
  v_precio_base_esperado numeric(14,4);

  v_subtotal_linea numeric(14,2);
  v_subtotal_linea_reportado numeric(14,2);
  v_descuento_linea numeric(14,2);
  v_subtotal_final_linea numeric(14,2);

  v_descuento_acumulado numeric(14,2) := 0;
  v_subtotal_final_acumulado numeric(14,2) := 0;

  -- Inventario
  v_stock_actual integer;
  v_saldo_actual integer;

  -- Pagos
  v_pago jsonb;
  v_metodo_pago text;
  v_monto_pago numeric(14,2);

  -- Constancia
  v_constancia_id uuid;
  v_constancia_codigo text;

BEGIN
  -- ===========================================================================
  -- 1. VALIDACIONES INICIALES
  -- ===========================================================================

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION
      'request_id es obligatorio para evitar ventas duplicadas';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_request_id::text, 0)
  );

  IF EXISTS (
    SELECT 1
    FROM public.ventas_requests_anulados AS vra
    WHERE vra.request_id = p_request_id
  ) THEN
    RAISE EXCEPTION
      'La venta asociada a este request_id fue anulada y no puede recrearse';
  END IF;

  IF v_tipo_comprobante = 'ticket' THEN
    v_tipo_comprobante := 'ticket_interno';
  END IF;

  IF v_tipo_comprobante NOT IN (
    'ticket_interno',
    'boleta',
    'factura'
  ) THEN
    RAISE EXCEPTION
      'Tipo de comprobante inválido: %',
      v_tipo_comprobante;
  END IF;


  -- Regla comercial: factura y boleta electrónica solo al contado.
  -- Las ventas a crédito continúan disponibles mediante Ticket Interno.
  IF COALESCE(p_es_credito, false)
     AND v_tipo_comprobante IN ('boleta', 'factura') THEN
    RAISE EXCEPTION
      'Las facturas y boletas electrónicas solo pueden emitirse al contado. Para una venta a crédito use Ticket Interno.';
  END IF;

  IF jsonb_typeof(v_detalles) <> 'array'
     OR jsonb_array_length(v_detalles) = 0 THEN
    RAISE EXCEPTION
      'La venta debe contener al menos un producto';
  END IF;

  IF jsonb_typeof(v_pagos) <> 'array' THEN
    RAISE EXCEPTION
      'El parámetro pagos debe ser un arreglo JSON';
  END IF;

  v_num_detalles := jsonb_array_length(v_detalles);
  v_fecha_emision :=
    (v_fecha AT TIME ZONE 'America/Lima')::date;

  IF v_tipo_comprobante IN ('boleta', 'factura') THEN
    IF v_fecha_emision > (now() AT TIME ZONE 'America/Lima')::date THEN
      RAISE EXCEPTION
        'La fecha de emisión electrónica no puede estar en el futuro';
    END IF;

    IF v_tipo_comprobante = 'factura'
       AND v_fecha_emision <
         (now() AT TIME ZONE 'America/Lima')::date - 3 THEN
      RAISE EXCEPTION
        'La factura supera el plazo máximo de tres días calendario posteriores a su fecha de emisión';
    END IF;
  END IF;

  -- ===========================================================================
  -- 2. IDEMPOTENCIA
  -- ===========================================================================

  SELECT
    v.id,
    ROUND(v.total, 2),
    v.tipo_comprobante_solicitado
  INTO
    v_existing_venta_id,
    v_existing_total,
    v_existing_tipo
  FROM public.ventas AS v
  WHERE v.request_id = p_request_id
  LIMIT 1;

  IF FOUND THEN
    IF ABS(v_existing_total - ROUND(COALESCE(p_total, 0), 2)) > 0.02
       OR COALESCE(v_existing_tipo, 'ticket_interno')
            <> v_tipo_comprobante THEN
      RAISE EXCEPTION
        'El request_id ya fue utilizado con datos diferentes';
    END IF;

    SELECT
      ce.id,
      ce.serie,
      ce.correlativo,
      ce.estado
    INTO
      v_existing_comprobante_id,
      v_existing_serie,
      v_existing_correlativo,
      v_existing_estado
    FROM public.comprobantes_electronicos AS ce
    WHERE ce.venta_id = v_existing_venta_id
    ORDER BY ce.created_at DESC
    LIMIT 1;

    RETURN jsonb_build_object(
      'success', true,
      'idempotent', true,
      'venta_id', v_existing_venta_id,
      'comprobante_id', v_existing_comprobante_id,
      'serie', v_existing_serie,
      'correlativo', v_existing_correlativo,
      'estado_facturacion', COALESCE(
        v_existing_estado,
        'no_aplica'
      )
    );
  END IF;

  -- ===========================================================================
  -- 3. CONFIGURACIÓN DEL NEGOCIO
  -- ===========================================================================

  SELECT
    true,
    COALESCE(cn.facturacion_habilitada, false),
    COALESCE(cn.precios_incluyen_igv, true),
    COALESCE(cn.porcentaje_igv, 18.00),

    COALESCE(cn.descuento_sin_autorizacion_hasta, 10.0000),
    COALESCE(cn.descuento_con_motivo_desde, 10.0000),
    COALESCE(cn.descuento_con_pin_desde, 30.0000),
    COALESCE(cn.generar_constancia_descuento, true),

    NULLIF(TRIM(cn.ruc), ''),
    NULLIF(TRIM(cn.razon_social), ''),
    NULLIF(TRIM(cn.nombre_comercial), ''),
    NULLIF(TRIM(cn.direccion), ''),
    NULLIF(TRIM(cn.ubigeo), ''),
    NULLIF(TRIM(cn.departamento), ''),
    NULLIF(TRIM(cn.provincia), ''),
    NULLIF(TRIM(cn.distrito), ''),
    COALESCE(NULLIF(TRIM(cn.cod_local), ''), '0000'),
    NULLIF(TRIM(cn.telefono), ''),
    NULLIF(TRIM(cn.logo_url), '')
  INTO
    v_config_encontrada,
    v_facturacion_habilitada,
    v_precios_incluyen_igv,
    v_porcentaje_igv,

    v_descuento_sin_autorizacion_hasta,
    v_descuento_con_motivo_desde,
    v_descuento_con_pin_desde,
    v_generar_constancia,

    v_empresa_ruc,
    v_empresa_razon_social,
    v_empresa_nombre_comercial,
    v_empresa_direccion,
    v_empresa_ubigeo,
    v_empresa_departamento,
    v_empresa_provincia,
    v_empresa_distrito,
    v_empresa_cod_local,
    v_empresa_telefono,
    v_empresa_logo_url
  FROM public.configuracion_negocio AS cn
  ORDER BY cn.id
  LIMIT 1;

  -- ===========================================================================
  -- 4. VENDEDOR / ACTOR AUTENTICADO
  -- ===========================================================================

  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: usuario no autenticado';
  END IF;

  SELECT
    e.id,
    LOWER(COALESCE(e.rol, 'operador')),
    e.nombre
  INTO
    v_vendedor_id,
    v_vendedor_rol,
    v_vendedor_nombre
  FROM public.empleados AS e
  WHERE e.auth_id = auth.uid()
    AND COALESCE(e.activo, false) = true
    AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'operador')
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Acceso denegado: empleado inactivo o rol no autorizado';
  END IF;

  -- Nunca se confía en p_vendedor_id ni p_descuento_autorizado_por.
  -- El actor real se obtiene exclusivamente de auth.uid().
  v_autorizado_por := NULL;

  -- ===========================================================================
  -- 5. RECALCULAR SUBTOTAL DESDE LOS DETALLES
  -- Usa precio_unitario_comercial, no el precio base por pieza.
  -- ===========================================================================

  FOR v_detalle, v_ordinal IN
    SELECT elemento, ordinalidad::integer
    FROM jsonb_array_elements(v_detalles)
      WITH ORDINALITY AS x(elemento, ordinalidad)
  LOOP
    v_cantidad_visual :=
      COALESCE(
        NULLIF(v_detalle->>'cantidad', '')::numeric,
        0
      )::integer;

    v_precio_unitario :=
      ROUND(
        COALESCE(
          NULLIF(v_detalle->>'precio_unitario', '')::numeric,
          0
        ),
        4
      );

    v_subtotal_linea_reportado :=
      ROUND(
        COALESCE(
          NULLIF(v_detalle->>'subtotal', '')::numeric,
          0
        ),
        2
      );

    IF v_cantidad_visual <= 0 THEN
      RAISE EXCEPTION
        'La cantidad del producto en la posición % debe ser mayor a cero',
        v_ordinal;
    END IF;

    IF v_precio_unitario < 0 THEN
      RAISE EXCEPTION
        'El precio base del producto en la posición % no puede ser negativo',
        v_ordinal;
    END IF;

    v_precio_unitario_comercial :=
      ROUND(
        COALESCE(
          NULLIF(
            v_detalle->>'precio_unitario_comercial',
            ''
          )::numeric,
          CASE
            WHEN v_cantidad_visual > 0
              THEN v_subtotal_linea_reportado / v_cantidad_visual
            ELSE 0
          END
        ),
        4
      );

    IF v_precio_unitario_comercial < 0 THEN
      RAISE EXCEPTION
        'El precio comercial del producto en la posición % no puede ser negativo',
        v_ordinal;
    END IF;

    v_subtotal_linea :=
      ROUND(
        v_cantidad_visual * v_precio_unitario_comercial,
        2
      );

    IF ABS(
      v_subtotal_linea - v_subtotal_linea_reportado
    ) > 0.02 THEN
      RAISE EXCEPTION
        'Subtotal inconsistente en el producto %. Esperado: %, recibido: %',
        v_ordinal,
        v_subtotal_linea,
        v_subtotal_linea_reportado;
    END IF;

    v_subtotal_calculado :=
      ROUND(v_subtotal_calculado + v_subtotal_linea, 2);
  END LOOP;

  IF v_subtotal_calculado <= 0 THEN
    RAISE EXCEPTION
      'El subtotal de la venta debe ser mayor a cero';
  END IF;

  v_subtotal_reportado :=
    ROUND(COALESCE(p_subtotal_bruto, 0), 2);

  IF v_subtotal_reportado > 0
     AND ABS(
       v_subtotal_reportado - v_subtotal_calculado
     ) > 0.02 THEN
    RAISE EXCEPTION
      'El subtotal bruto no coincide. Calculado: %, recibido: %',
      v_subtotal_calculado,
      v_subtotal_reportado;
  END IF;

  -- ===========================================================================
  -- 6. DESCUENTO GLOBAL
  -- ===========================================================================

  IF v_descuento_porcentaje < 0
     OR v_descuento_porcentaje > 100 THEN
    RAISE EXCEPTION
      'El descuento porcentual debe estar entre 0 y 100';
  END IF;

  IF v_descuento_monto < 0 THEN
    RAISE EXCEPTION
      'El monto de descuento no puede ser negativo';
  END IF;

  IF v_descuento_porcentaje > 0
     AND v_descuento_monto > 0 THEN

    v_descuento_esperado :=
      ROUND(
        v_subtotal_calculado
        * v_descuento_porcentaje
        / 100,
        2
      );

    IF ABS(
      v_descuento_esperado - v_descuento_monto
    ) > 0.02 THEN
      RAISE EXCEPTION
        'El porcentaje y monto del descuento no coinciden';
    END IF;

  ELSIF v_descuento_porcentaje > 0 THEN

    v_descuento_monto :=
      ROUND(
        v_subtotal_calculado
        * v_descuento_porcentaje
        / 100,
        2
      );

  ELSIF v_descuento_monto > 0 THEN

    v_descuento_porcentaje :=
      ROUND(
        v_descuento_monto
        / v_subtotal_calculado
        * 100,
        4
      );

  ELSE
    v_descuento_porcentaje := 0;
    v_descuento_monto := 0;
  END IF;

  IF v_descuento_monto > v_subtotal_calculado THEN
    RAISE EXCEPTION
      'El descuento no puede superar el subtotal de la venta';
  END IF;

  v_total_final :=
    ROUND(
      v_subtotal_calculado - v_descuento_monto,
      2
    );

  IF v_total_final <= 0 THEN
    RAISE EXCEPTION
      'El descuento no puede dejar la venta en S/ 0.00';
  END IF;

  IF ABS(
    v_total_final - ROUND(COALESCE(p_total, 0), 2)
  ) > 0.02 THEN
    RAISE EXCEPTION
      'El total enviado no coincide. Calculado: %, recibido: %',
      v_total_final,
      ROUND(COALESCE(p_total, 0), 2);
  END IF;

  -- ===========================================================================
  -- 7. AUTORIZACIÓN DE DESCUENTOS
  -- ===========================================================================

  IF v_descuento_porcentaje >= v_descuento_con_motivo_desde
     AND COALESCE(TRIM(p_motivo_descuento), '') = '' THEN
    RAISE EXCEPTION
      'Debe registrar el motivo del descuento';
  END IF;

  IF v_descuento_porcentaje
       > v_descuento_sin_autorizacion_hasta THEN

    IF v_autorizado_por IS NULL
       AND v_vendedor_id IS NOT NULL
       AND v_vendedor_rol = 'admin' THEN
      v_autorizado_por := v_vendedor_id;
    END IF;

    IF v_autorizado_por IS NULL THEN
      RAISE EXCEPTION
        'El descuento de % %% requiere autorización de un administrador',
        v_descuento_porcentaje;
    END IF;

    SELECT LOWER(COALESCE(e.rol, 'operador'))
    INTO v_autorizador_rol
    FROM public.empleados AS e
    WHERE e.id = v_autorizado_por
      AND COALESCE(e.activo, true) = true;

    IF NOT FOUND
       OR v_autorizador_rol <> 'admin' THEN
      RAISE EXCEPTION
        'El usuario autorizador no es un administrador activo';
    END IF;
  END IF;

  -- ===========================================================================
  -- 8. PAGOS
  -- ===========================================================================

  FOR v_pago IN
    SELECT value
    FROM jsonb_array_elements(v_pagos)
  LOOP
    v_metodo_pago :=
      TRIM(COALESCE(v_pago->>'metodo', ''));

    v_monto_pago :=
      ROUND(
        COALESCE(
          NULLIF(v_pago->>'monto', '')::numeric,
          0
        ),
        2
      );

    IF v_metodo_pago = '' THEN
      RAISE EXCEPTION
        'Todos los pagos deben tener un método';
    END IF;

    IF v_monto_pago <= 0 THEN
      RAISE EXCEPTION
        'Todos los pagos deben tener un monto mayor a cero';
    END IF;

    v_total_pagos :=
      ROUND(v_total_pagos + v_monto_pago, 2);
  END LOOP;

  IF COALESCE(p_es_credito, false) = false THEN
    IF ABS(v_total_pagos - v_total_final) > 0.02 THEN
      RAISE EXCEPTION
        'En venta al contado los pagos deben sumar exactamente %. Recibido: %',
        v_total_final,
        v_total_pagos;
    END IF;

    v_monto_abono := v_total_final;
    v_saldo := 0;
    v_estado_venta := 'pagado';

  ELSE
    IF v_monto_abono < 0
       OR v_monto_abono > v_total_final THEN
      RAISE EXCEPTION
        'El abono debe estar entre S/ 0.00 y S/ %',
        v_total_final;
    END IF;

    IF ABS(v_total_pagos - v_monto_abono) > 0.02 THEN
      RAISE EXCEPTION
        'Los pagos del crédito deben coincidir con el abono inicial';
    END IF;

    v_saldo :=
      ROUND(v_total_final - v_monto_abono, 2);

    v_estado_venta :=
      CASE
        WHEN v_saldo <= 0.01 THEN 'pagado'
        ELSE 'pendiente'
      END;
  END IF;

  -- ===========================================================================
  -- 9. CLIENTE
  -- ===========================================================================

  IF p_cliente_id IS NOT NULL THEN
    SELECT
      NULLIF(TRIM(c.nombre), ''),
      NULLIF(TRIM(c.dni_ruc), ''),
      LOWER(NULLIF(TRIM(c.tipo_doc), '')),
      NULLIF(TRIM(c.direccion), '')
    INTO
      v_cliente_nombre,
      v_cliente_documento,
      v_cliente_tipo_doc_db,
      v_cliente_direccion
    FROM public.clientes AS c
    WHERE c.id = p_cliente_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'El cliente seleccionado no existe';
    END IF;
  ELSE
    v_cliente_nombre := 'CLIENTE GENERAL';
    v_cliente_documento := NULL;
    v_cliente_tipo_doc_db := NULL;
    v_cliente_direccion := NULL;
  END IF;

  v_cliente_nombre :=
    COALESCE(v_cliente_nombre, 'CLIENTE GENERAL');

  -- ===========================================================================
  -- 10. VALIDACIONES TRIBUTARIAS
  -- ===========================================================================

  IF v_tipo_comprobante IN ('boleta', 'factura') THEN

    IF v_config_encontrada = false THEN
      RAISE EXCEPTION
        'No existe configuración del negocio';
    END IF;

    IF v_facturacion_habilitada = false THEN
      RAISE EXCEPTION
        'La facturación electrónica todavía está deshabilitada';
    END IF;

    IF v_precios_incluyen_igv = false THEN
      RAISE EXCEPTION
        'process_sale_v3 requiere precios que ya incluyan IGV';
    END IF;

    IF v_empresa_ruc IS NULL
       OR v_empresa_ruc !~ '^[0-9]{11}$' THEN
      RAISE EXCEPTION
        'El RUC del negocio debe tener exactamente 11 dígitos';
    END IF;

    IF v_empresa_razon_social IS NULL THEN
      RAISE EXCEPTION
        'Falta la razón social del negocio';
    END IF;

    IF v_empresa_direccion IS NULL THEN
      RAISE EXCEPTION
        'Falta la dirección fiscal del negocio';
    END IF;

    IF v_empresa_ubigeo IS NULL
       OR v_empresa_ubigeo !~ '^[0-9]{6}$' THEN
      RAISE EXCEPTION
        'El ubigeo del negocio debe tener 6 dígitos';
    END IF;

    IF v_empresa_departamento IS NULL
       OR v_empresa_provincia IS NULL
       OR v_empresa_distrito IS NULL THEN
      RAISE EXCEPTION
        'Falta completar departamento, provincia o distrito';
    END IF;

    IF v_tipo_comprobante = 'factura' THEN
      IF v_cliente_documento IS NULL
         OR v_cliente_documento !~ '^[0-9]{11}$' THEN
        RAISE EXCEPTION
          'La factura requiere un cliente con RUC de 11 dígitos';
      END IF;

      v_cliente_tipo_sunat := '6';

    ELSE
      IF v_total_final > 700.00 THEN
        IF v_cliente_documento IS NULL
           OR v_cliente_documento !~ '^[0-9]{8}$' THEN
          RAISE EXCEPTION
            'Para boletas mayores a S/ 700.00, el DNI de 8 dígitos es obligatorio';
        END IF;

        IF NULLIF(TRIM(COALESCE(v_cliente_nombre, '')), '') IS NULL
           OR UPPER(TRIM(v_cliente_nombre)) = 'CLIENTE GENERAL' THEN
          RAISE EXCEPTION
            'Para boletas mayores a S/ 700.00, el nombre completo del cliente es obligatorio';
        END IF;
      END IF;

      IF v_cliente_documento IS NULL
         OR v_cliente_documento = ''
         OR v_cliente_documento = '00000000' THEN

        v_cliente_tipo_sunat := '0';
        v_cliente_documento := '0';

      ELSIF v_cliente_documento ~ '^[0-9]{8}$' THEN
        v_cliente_tipo_sunat := '1';

      ELSE
        RAISE EXCEPTION
          'La boleta requiere DNI de 8 dígitos o cliente sin documento';
      END IF;
    END IF;
  ELSE
    IF v_cliente_documento ~ '^[0-9]{11}$' THEN
      v_cliente_tipo_sunat := '6';
    ELSIF v_cliente_documento ~ '^[0-9]{8}$' THEN
      v_cliente_tipo_sunat := '1';
    ELSE
      v_cliente_tipo_sunat := '0';
    END IF;
  END IF;

  -- ===========================================================================
  -- 11. BASE E IGV
  -- ===========================================================================

  v_factor_igv :=
    1 + (v_porcentaje_igv / 100);

  v_base_imponible :=
    ROUND(v_total_final / v_factor_igv, 2);

  v_igv :=
    ROUND(v_total_final - v_base_imponible, 2);

  v_estado_facturacion :=
    CASE
      WHEN v_tipo_comprobante = 'ticket_interno'
        THEN 'no_aplica'
      ELSE 'pendiente'
    END;

  -- ===========================================================================
  -- 12. CREAR VENTA
  -- ===========================================================================

  INSERT INTO public.ventas (
    cliente_id,
    total,
    estado,
    saldo,
    fecha,
    tipo_comprobante_solicitado,
    estado_facturacion,
    subtotal_bruto,
    descuento_global_porcentaje,
    descuento_global_monto,
    motivo_descuento,
    vendedor_id,
    request_id,
    descuento_autorizado_por,
    descuento_autorizado_at
  )
  VALUES (
    p_cliente_id,
    v_total_final,
    v_estado_venta,
    v_saldo,
    v_fecha,
    v_tipo_comprobante,
    v_estado_facturacion,
    v_subtotal_calculado,
    v_descuento_porcentaje,
    v_descuento_monto,
    NULLIF(TRIM(p_motivo_descuento), ''),
    v_vendedor_id,
    p_request_id,
    v_autorizado_por,
    CASE
      WHEN v_autorizado_por IS NOT NULL THEN now()
      ELSE NULL
    END
  )
  RETURNING id INTO v_venta_id;

  -- ===========================================================================
  -- 13. COTIZACIÓN
  -- ===========================================================================

  IF p_cotizacion_id IS NOT NULL THEN
    UPDATE public.cotizaciones
    SET estado = 'aprobada'
    WHERE id = p_cotizacion_id;
  END IF;

  -- ===========================================================================
  -- 14. PAGOS
  -- ===========================================================================

  FOR v_pago IN
    SELECT value
    FROM jsonb_array_elements(v_pagos)
  LOOP
    v_metodo_pago :=
      TRIM(v_pago->>'metodo');

    v_monto_pago :=
      ROUND((v_pago->>'monto')::numeric, 2);

    INSERT INTO public.pagos_venta (
      venta_id,
      metodo,
      monto,
      fecha
    )
    VALUES (
      v_venta_id,
      v_metodo_pago,
      v_monto_pago,
      v_fecha
    );
  END LOOP;

  -- ===========================================================================
  -- 15. DETALLES, STOCK Y KARDEX
  -- ===========================================================================

  FOR v_detalle, v_ordinal IN
    SELECT elemento, ordinalidad::integer
    FROM jsonb_array_elements(v_detalles)
      WITH ORDINALITY AS x(elemento, ordinalidad)
  LOOP
    v_prod_id :=
      (v_detalle->>'producto_id')::bigint;

    v_almacen_id :=
      (v_detalle->>'almacen_id')::bigint;

    v_cantidad_visual :=
      (v_detalle->>'cantidad')::numeric::integer;

    v_precio_unitario :=
      ROUND(
        (v_detalle->>'precio_unitario')::numeric,
        4
      );

    v_subtotal_linea_reportado :=
      ROUND(
        (v_detalle->>'subtotal')::numeric,
        2
      );

    v_precio_unitario_comercial :=
      ROUND(
        COALESCE(
          NULLIF(
            v_detalle->>'precio_unitario_comercial',
            ''
          )::numeric,
          CASE
            WHEN v_cantidad_visual > 0
              THEN v_subtotal_linea_reportado / v_cantidad_visual
            ELSE 0
          END
        ),
        4
      );

    v_tipo_unidad :=
      LOWER(TRIM(COALESCE(v_detalle->>'tipo_unidad', 'unidad')));

    IF v_tipo_unidad IN ('cajas', 'box', 'bx') THEN
      v_tipo_unidad := 'caja';
    ELSIF v_tipo_unidad IN ('paquetes', 'paq', 'pack', 'pk') THEN
      v_tipo_unidad := 'paquete';
    ELSIF v_tipo_unidad IN (
      'unidades', 'und', 'niu', 'pieza', 'piezas'
    ) THEN
      v_tipo_unidad := 'unidad';
    END IF;

    IF v_tipo_unidad NOT IN ('caja', 'paquete', 'unidad') THEN
      RAISE EXCEPTION
        'Tipo de unidad inválido en el producto %',
        v_prod_id;
    END IF;

    SELECT
      p.nombre,
      GREATEST(COALESCE(p.cantidad_por_caja, 1), 1),
      LOWER(COALESCE(p.tipo_venta, 'ambos')),
      COALESCE(pr.nombre, 'Generico'),
      COALESCE(p.permitir_sin_stock, false)
    INTO
      v_prod_nombre,
      v_prod_pcs,
      v_prod_tipo_venta,
      v_proveedor_nombre,
      v_permitir_sin_stock
    FROM public.productos AS p
    LEFT JOIN public.proveedores AS pr
      ON pr.id = p.proveedor_id
    WHERE p.id = v_prod_id
      AND COALESCE(p.activo, true) = true;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'El producto % no existe o está inactivo',
        v_prod_id;
    END IF;

    IF v_prod_tipo_venta IN ('paquetes', 'paquete')
       AND v_tipo_unidad <> 'paquete' THEN
      RAISE EXCEPTION
        'El producto % solo puede venderse por paquetes',
        v_prod_nombre;
    END IF;

    IF v_prod_tipo_venta = 'caja_paquetes'
       AND v_tipo_unidad NOT IN ('caja', 'paquete') THEN
      RAISE EXCEPTION
        'El producto % solo puede venderse por caja o paquete',
        v_prod_nombre;
    END IF;

    IF v_prod_tipo_venta = 'caja_unidades'
       AND v_tipo_unidad NOT IN ('caja', 'unidad') THEN
      RAISE EXCEPTION
        'El producto % solo puede venderse por caja o unidad',
        v_prod_nombre;
    END IF;

    -- Compatibilidad histórica.
    IF v_prod_tipo_venta IN ('solo_cajas', 'caja')
       AND v_tipo_unidad <> 'caja' THEN
      RAISE EXCEPTION 'El producto % solo puede venderse por cajas', v_prod_nombre;
    END IF;

    IF v_prod_tipo_venta IN ('solo_unidades', 'unidad')
       AND v_tipo_unidad <> 'unidad' THEN
      RAISE EXCEPTION 'El producto % solo puede venderse por unidades', v_prod_nombre;
    END IF;

    IF v_prod_tipo_venta IN ('ambos', 'caja_unidad', 'cajas_unidades')
       AND v_tipo_unidad NOT IN ('caja', 'unidad') THEN
      RAISE EXCEPTION 'El producto % solo puede venderse por caja o unidad', v_prod_nombre;
    END IF;

    -- La función central calcula la cantidad base real de inventario.
    v_piezas_calculadas :=
      public.calcular_piezas_reales_stock(
        v_prod_tipo_venta,
        v_tipo_unidad,
        v_cantidad_visual,
        v_prod_pcs
      );

    IF v_detalle ? 'piezas_reales'
       AND NULLIF(v_detalle->>'piezas_reales', '') IS NOT NULL THEN

      v_piezas_enviadas :=
        (v_detalle->>'piezas_reales')::numeric::integer;

      IF v_piezas_enviadas <> v_piezas_calculadas THEN
        RAISE EXCEPTION
          'Cantidad de stock inconsistente para %. Calculado: %, recibido: %',
          v_prod_nombre,
          v_piezas_calculadas,
          v_piezas_enviadas;
      END IF;
    END IF;

    v_precio_base_esperado :=
      CASE
        WHEN v_piezas_calculadas > 0
          THEN ROUND(v_subtotal_linea_reportado / v_piezas_calculadas, 4)
        ELSE 0
      END;

    IF ABS(v_precio_unitario - v_precio_base_esperado) > 0.02 THEN
      RAISE EXCEPTION
        'Precio base de stock inconsistente para %. Esperado: %, recibido: %',
        v_prod_nombre,
        v_precio_base_esperado,
        v_precio_unitario;
    END IF;

    -- Validación económica independiente de la validación de stock.
    v_subtotal_linea :=
      ROUND(
        v_cantidad_visual * v_precio_unitario_comercial,
        2
      );

    IF ABS(
      v_subtotal_linea - v_subtotal_linea_reportado
    ) > 0.02 THEN
      RAISE EXCEPTION
        'Subtotal comercial inconsistente para %. Esperado: %, recibido: %',
        v_prod_nombre,
        v_subtotal_linea,
        v_subtotal_linea_reportado;
    END IF;

    -- Distribución proporcional del descuento global.
    IF v_descuento_monto > 0 THEN
      IF v_ordinal = v_num_detalles THEN
        v_descuento_linea :=
          ROUND(
            v_descuento_monto - v_descuento_acumulado,
            2
          );
      ELSE
        v_descuento_linea :=
          ROUND(
            v_descuento_monto
            * v_subtotal_linea
            / v_subtotal_calculado,
            2
          );
      END IF;
    ELSE
      v_descuento_linea := 0;
    END IF;

    IF v_descuento_linea < 0
       OR v_descuento_linea > v_subtotal_linea THEN
      RAISE EXCEPTION
        'El descuento distribuido es inválido para %',
        v_prod_nombre;
    END IF;

    v_subtotal_final_linea :=
      ROUND(
        v_subtotal_linea - v_descuento_linea,
        2
      );

    v_descuento_acumulado :=
      ROUND(
        v_descuento_acumulado + v_descuento_linea,
        2
      );

    v_subtotal_final_acumulado :=
      ROUND(
        v_subtotal_final_acumulado
        + v_subtotal_final_linea,
        2
      );

    v_precio_unitario_final :=
      CASE
        WHEN v_piezas_calculadas > 0
          THEN ROUND(
            v_subtotal_final_linea / v_piezas_calculadas,
            4
          )
        ELSE 0
      END;

    SELECT a.nombre
    INTO v_almacen_nombre
    FROM public.almacenes AS a
    WHERE a.id = v_almacen_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'El almacén % no existe',
        v_almacen_id;
    END IF;

    SELECT COALESCE(ia.cantidad, 0)
    INTO v_stock_actual
    FROM public.inventario_almacen AS ia
    WHERE ia.producto_id = v_prod_id
      AND ia.almacen_id = v_almacen_id
    FOR UPDATE;

    IF NOT FOUND THEN
      IF v_permitir_sin_stock THEN
        INSERT INTO public.inventario_almacen (
          producto_id,
          almacen_id,
          cantidad
        )
        VALUES (
          v_prod_id,
          v_almacen_id,
          0
        )
        ON CONFLICT (producto_id, almacen_id)
        DO NOTHING;

        SELECT COALESCE(ia.cantidad, 0)
        INTO v_stock_actual
        FROM public.inventario_almacen AS ia
        WHERE ia.producto_id = v_prod_id
          AND ia.almacen_id = v_almacen_id
        FOR UPDATE;
      ELSE
        RAISE EXCEPTION
          'No existe inventario para % en el almacén %',
          v_prod_nombre,
          v_almacen_nombre;
      END IF;
    END IF;

    IF v_stock_actual < v_piezas_calculadas
       AND v_permitir_sin_stock = false THEN
      RAISE EXCEPTION
        'Stock insuficiente para %. Disponible: %, requerido: %',
        v_prod_nombre,
        v_stock_actual,
        v_piezas_calculadas;
    END IF;

    UPDATE public.inventario_almacen
    SET cantidad =
      COALESCE(cantidad, 0) - v_piezas_calculadas
    WHERE producto_id = v_prod_id
      AND almacen_id = v_almacen_id
    RETURNING cantidad INTO v_saldo_actual;

    INSERT INTO public.detalle_ventas (
      venta_id,
      producto_id,
      cantidad,
      piezas_reales,
      precio_unitario,
      precio_unitario_comercial,
      subtotal,
      almacen_id,
      tipo_unidad,
      descuento_global_asignado,
      subtotal_final,
      tipo_venta_snapshot,
      pcs_snapshot,
      unidad_base_snapshot
    )
    VALUES (
      v_venta_id,
      v_prod_id,
      v_cantidad_visual,
      v_piezas_calculadas,
      v_precio_unitario,
      v_precio_unitario_comercial,
      v_subtotal_linea,
      v_almacen_id,
      v_tipo_unidad,
      v_descuento_linea,
      v_subtotal_final_linea,
      UPPER(v_prod_tipo_venta),
      v_prod_pcs,
      CASE
        WHEN v_prod_tipo_venta IN ('paquetes', 'paquete', 'caja_paquetes')
          THEN 'Paquete'
        WHEN v_prod_tipo_venta IN ('solo_cajas', 'caja')
          THEN 'Caja'
        ELSE 'Unidad'
      END
    );

    v_unidad_label :=
      CASE
        WHEN v_prod_tipo_venta IN ('paquetes', 'paquete', 'caja_paquetes')
          THEN 'Paquete'
        WHEN v_prod_tipo_venta IN ('solo_cajas', 'caja')
          THEN 'Caja'
        ELSE 'Unidad'
      END;

    INSERT INTO public.inventario_movimientos (
      fecha,
      producto_id,
      producto_nombre,
      pcs,
      proveedor,
      tipo,
      saldo,
      almacen_id,
      almacen_nombre,
      observaciones,
      salida_cant,
      salida_und,
      salida_cliente,
      salida_p_unit,
      salida_total,
      venta_id,
      venta_id_original,
      vendedor_id,
      vendedor_nombre_snapshot,
      tipo_venta_snapshot,
      unidad_base_snapshot,
      request_id
    )
    VALUES (
      v_fecha,
      v_prod_id,
      v_prod_nombre,
      v_prod_pcs,
      v_proveedor_nombre,
      'SALIDA',
      v_saldo_actual,
      v_almacen_id,
      COALESCE(v_almacen_nombre, ''),
      'Venta #' || v_venta_id,
      v_piezas_calculadas,
      v_unidad_label,
      v_cliente_nombre,
      v_precio_unitario_final,
      v_subtotal_final_linea,
      v_venta_id,
      v_venta_id,
      v_vendedor_id,
      v_vendedor_nombre,
      UPPER(v_prod_tipo_venta),
      v_unidad_label,
      p_request_id
    );
  END LOOP;

  IF ABS(
    v_descuento_acumulado - v_descuento_monto
  ) > 0.02 THEN
    RAISE EXCEPTION
      'Error distribuyendo el descuento. Esperado: %, distribuido: %',
      v_descuento_monto,
      v_descuento_acumulado;
  END IF;

  IF ABS(
    v_subtotal_final_acumulado - v_total_final
  ) > 0.02 THEN
    RAISE EXCEPTION
      'Error en los totales finales. Esperado: %, calculado: %',
      v_total_final,
      v_subtotal_final_acumulado;
  END IF;

  -- ===========================================================================
  -- 16. CONSTANCIA DE DESCUENTO
  -- ===========================================================================

  IF v_descuento_monto > 0
     AND v_generar_constancia = true THEN

    v_constancia_codigo :=
      'DESC-'
      || TO_CHAR(
        v_fecha AT TIME ZONE 'America/Lima',
        'YYYYMMDD'
      )
      || '-'
      || LPAD(v_venta_id::text, 8, '0');

    INSERT INTO public.constancias_descuento (
      venta_id,
      comprobante_id,
      codigo,
      subtotal_bruto,
      descuento_porcentaje,
      descuento_monto,
      total_final,
      motivo,
      aplicado_por,
      autorizado_por,
      autorizado_at
    )
    VALUES (
      v_venta_id,
      NULL,
      v_constancia_codigo,
      v_subtotal_calculado,
      v_descuento_porcentaje,
      v_descuento_monto,
      v_total_final,
      NULLIF(TRIM(p_motivo_descuento), ''),
      v_vendedor_id,
      v_autorizado_por,
      CASE
        WHEN v_autorizado_por IS NOT NULL THEN now()
        ELSE NULL
      END
    )
    RETURNING id INTO v_constancia_id;
  END IF;

  -- ===========================================================================
  -- 17. COMPROBANTE ELECTRÓNICO PENDIENTE
  -- ===========================================================================

  IF v_tipo_comprobante IN ('boleta', 'factura') THEN

    SELECT
      sc.id,
      sc.serie
    INTO
      v_serie_id,
      v_serie
    FROM public.series_comprobantes AS sc
    WHERE sc.tipo_documento_sunat = v_tipo_comprobante
      AND sc.activo = true
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'No existe una serie activa para %',
        v_tipo_comprobante;
    END IF;

    UPDATE public.series_comprobantes
    SET ultimo_correlativo = ultimo_correlativo + 1
    WHERE id = v_serie_id
    RETURNING ultimo_correlativo
    INTO v_correlativo;

    INSERT INTO public.comprobantes_electronicos (
      venta_id,
      tipo_documento_sunat,
      serie,
      correlativo,
      fecha_emision,
      fecha_emision_ts,
      moneda,
      estado,
      subtotal_bruto,
      descuento_global_porcentaje,
      descuento_global_monto,
      base_imponible,
      igv,
      total,
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
      request_id
    )
    VALUES (
      v_venta_id,
      v_tipo_comprobante,
      v_serie,
      v_correlativo,
      v_fecha_emision,
      v_fecha,
      'PEN',
      'pendiente',
      v_subtotal_calculado,
      v_descuento_porcentaje,
      v_descuento_monto,
      v_base_imponible,
      v_igv,
      v_total_final,
      v_cliente_tipo_sunat,
      v_cliente_documento,
      v_cliente_nombre,
      v_cliente_direccion,
      v_empresa_ruc,
      v_empresa_razon_social,
      COALESCE(
        v_empresa_nombre_comercial,
        v_empresa_razon_social
      ),
      v_empresa_direccion,
      v_empresa_ubigeo,
      v_empresa_departamento,
      v_empresa_provincia,
      v_empresa_distrito,
      COALESCE(v_empresa_cod_local, '0000'),
      v_empresa_telefono,
      v_empresa_logo_url,
      p_request_id
    )
    RETURNING id INTO v_comprobante_id;

    IF v_constancia_id IS NOT NULL THEN
      UPDATE public.constancias_descuento AS cd
      SET comprobante_id = v_comprobante_id
      WHERE cd.id = v_constancia_id;
    END IF;
  END IF;

  -- ===========================================================================
  -- 18. RESPUESTA
  -- ===========================================================================

  RETURN jsonb_build_object(
    'success', true,
    'idempotent', false,
    'venta_id', v_venta_id,
    'request_id', p_request_id,
    'subtotal_bruto', v_subtotal_calculado,
    'descuento_global_porcentaje', v_descuento_porcentaje,
    'descuento_global_monto', v_descuento_monto,
    'total', v_total_final,
    'estado_venta', v_estado_venta,
    'saldo', v_saldo,
    'comprobante_id', v_comprobante_id,
    'serie', v_serie,
    'correlativo', v_correlativo,
    'estado_facturacion', v_estado_facturacion,
    'constancia_descuento_id', v_constancia_id,
    'constancia_descuento_codigo', v_constancia_codigo
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.registrar_ingreso_mercaderia_v2(p_request_id uuid, p_producto_id bigint, p_fecha timestamp with time zone, p_tipo_ingreso text, p_documento text, p_proveedor_id bigint, p_observaciones text, p_almacenes jsonb, p_ingreso_costo numeric, p_ingreso_p_unit numeric, p_ingreso_p_caja numeric, p_ingreso_p_c_comp numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_previo jsonb;
  v_tipo_previo text;
  v_producto_previo bigint;
  v_item jsonb;
  v_almacen_id bigint;
  v_cantidad integer;
  v_almacenes bigint[] := '{}';
  v_proveedor text;
  v_motivo text;
  v_mov_id bigint;
  v_movimientos jsonb := '[]'::jsonb;
  v_total integer := 0;
  v_contador integer := 0;
  v_resultado jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: usuario no autenticado.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.empleados AS e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'operador')
  ) THEN
    RAISE EXCEPTION 'Acceso denegado: rol no autorizado para ingresos.';
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'request_id es obligatorio.';
  END IF;

  IF p_almacenes IS NULL
     OR jsonb_typeof(p_almacenes) <> 'array'
     OR jsonb_array_length(p_almacenes) = 0 THEN
    RAISE EXCEPTION 'Debe enviar al menos un almacén.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));

  SELECT io.resultado, io.tipo_operacion, io.producto_id
  INTO v_previo, v_tipo_previo, v_producto_previo
  FROM public.inventario_operaciones_idempotentes AS io
  WHERE io.request_id = p_request_id;

  IF FOUND THEN
    IF v_tipo_previo <> 'INGRESO' OR v_producto_previo <> p_producto_id THEN
      RAISE EXCEPTION 'El request_id ya fue utilizado en otra operación.';
    END IF;
    RETURN v_previo;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.productos AS p
    WHERE p.id = p_producto_id AND COALESCE(p.activo, true) = true
  ) THEN
    RAISE EXCEPTION 'El producto % no existe o está inactivo.', p_producto_id;
  END IF;

  IF p_proveedor_id IS NOT NULL THEN
    SELECT pr.nombre INTO v_proveedor
    FROM public.proveedores AS pr
    WHERE pr.id = p_proveedor_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'El proveedor % no existe.', p_proveedor_id;
    END IF;
  END IF;

  v_motivo := COALESCE(
    NULLIF(TRIM(p_tipo_ingreso), ''),
    'Ingreso de mercadería'
  );

  IF NULLIF(TRIM(COALESCE(p_documento, '')), '') IS NOT NULL THEN
    v_motivo := v_motivo || ' | Doc: ' || TRIM(p_documento);
  END IF;

  IF NULLIF(TRIM(COALESCE(p_observaciones, '')), '') IS NOT NULL THEN
    v_motivo := v_motivo || ' | ' || TRIM(p_observaciones);
  END IF;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_almacenes)
  LOOP
    v_almacen_id := NULLIF(v_item->>'almacen_id', '')::bigint;
    v_cantidad := COALESCE(
      NULLIF(v_item->>'cantidad_base', '')::integer,
      0
    );

    IF v_almacen_id IS NULL THEN
      RAISE EXCEPTION 'almacen_id es obligatorio.';
    END IF;

    IF v_cantidad <= 0 THEN
      RAISE EXCEPTION
        'La cantidad del almacén % debe ser mayor a cero.',
        v_almacen_id;
    END IF;

    IF v_almacen_id = ANY(v_almacenes) THEN
      RAISE EXCEPTION 'El almacén % está duplicado.', v_almacen_id;
    END IF;

    v_almacenes := array_append(v_almacenes, v_almacen_id);

    v_mov_id := public._aplicar_movimiento_inventario_v2(
      p_producto_id := p_producto_id,
      p_almacen_id := v_almacen_id,
      p_delta := v_cantidad,
      p_tipo_movimiento := 'ENTRADA',
      p_motivo := v_motivo,
      p_fecha := COALESCE(p_fecha, now()),
      p_ingreso_costo := COALESCE(p_ingreso_costo, 0),
      p_ingreso_p_unit := COALESCE(p_ingreso_p_unit, 0),
      p_ingreso_p_caja := p_ingreso_p_caja,
      p_ingreso_p_c_comp := p_ingreso_p_c_comp,
      p_proveedor_nombre := v_proveedor,
      p_request_id := p_request_id
    );

    v_movimientos := v_movimientos || jsonb_build_array(v_mov_id);
    v_total := v_total + v_cantidad;
    v_contador := v_contador + 1;
  END LOOP;

  v_resultado := jsonb_build_object(
    'success', true,
    'request_id', p_request_id,
    'producto_id', p_producto_id,
    'movimientos', v_movimientos,
    'almacenes_procesados', v_contador,
    'cantidad_base_total', v_total
  );

  INSERT INTO public.inventario_operaciones_idempotentes(
    request_id, tipo_operacion, producto_id, resultado
  )
  VALUES (p_request_id, 'INGRESO', p_producto_id, v_resultado);

  RETURN v_resultado;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.registrar_merma_v2(p_request_id uuid, p_producto_id bigint, p_almacen_id bigint, p_cantidad integer, p_motivo text, p_fecha timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_previo jsonb;
  v_tipo_previo text;
  v_producto_previo bigint;
  v_mov_id bigint;
  v_resultado jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: usuario no autenticado.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.empleados AS e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'operador')
  ) THEN
    RAISE EXCEPTION 'Acceso denegado: rol no autorizado para mermas.';
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'request_id es obligatorio.';
  END IF;

  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad debe ser mayor a cero.';
  END IF;

  IF NULLIF(TRIM(COALESCE(p_motivo, '')), '') IS NULL THEN
    RAISE EXCEPTION 'El motivo de la merma es obligatorio.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));

  SELECT io.resultado, io.tipo_operacion, io.producto_id
  INTO v_previo, v_tipo_previo, v_producto_previo
  FROM public.inventario_operaciones_idempotentes AS io
  WHERE io.request_id = p_request_id;

  IF FOUND THEN
    IF v_tipo_previo <> 'MERMA' OR v_producto_previo <> p_producto_id THEN
      RAISE EXCEPTION 'El request_id ya fue utilizado en otra operación.';
    END IF;
    RETURN v_previo;
  END IF;

  v_mov_id := public._aplicar_movimiento_inventario_v2(
    p_producto_id := p_producto_id,
    p_almacen_id := p_almacen_id,
    p_delta := -p_cantidad,
    p_tipo_movimiento := 'MERMA',
    p_motivo := TRIM(p_motivo),
    p_fecha := COALESCE(p_fecha, now()),
    p_request_id := p_request_id
  );

  v_resultado := jsonb_build_object(
    'success', true,
    'request_id', p_request_id,
    'producto_id', p_producto_id,
    'movimiento_id', v_mov_id,
    'cantidad_base', p_cantidad
  );

  INSERT INTO public.inventario_operaciones_idempotentes(
    request_id, tipo_operacion, producto_id, resultado
  )
  VALUES (p_request_id, 'MERMA', p_producto_id, v_resultado);

  RETURN v_resultado;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.set_vendedor_observaciones_kardex()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_venta_id BIGINT;
    v_vendedor_nombre TEXT;
BEGIN
    -- Intentar extraer el ID de la venta de la observación 
    -- Casos esperados: 'Venta #123' o 'Venta Anulada #123'
    IF NEW.observaciones LIKE 'Venta #%' OR NEW.observaciones LIKE 'Venta Anulada #%' THEN
        IF NEW.observaciones NOT LIKE '%/%' THEN
            -- Extraer solo los digitos
            v_venta_id := substring(NEW.observaciones from '#([0-9]+)')::BIGINT;
            
            IF v_venta_id IS NOT NULL THEN
                -- Obtener el nombre del vendedor desde la tabla ventas (que ya insertamos)
                SELECT e.nombre INTO v_vendedor_nombre 
                FROM ventas v
                JOIN empleados e ON e.id = v.vendedor_id
                WHERE v.id = v_venta_id;

                -- Si existe el vendedor, lo concatenamos
                IF v_vendedor_nombre IS NOT NULL THEN
                    NEW.observaciones := NEW.observaciones || ' / Vendedor: ' || v_vendedor_nombre;
                END IF;
            END IF;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.trasladar_stock_v2(p_request_id uuid, p_producto_id bigint, p_origen_id bigint, p_destino_id bigint, p_cantidad integer, p_motivo text DEFAULT NULL::text, p_fecha timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_previo jsonb;
  v_tipo_previo text;
  v_producto_previo bigint;
  v_motivo_origen text;
  v_motivo_destino text;
  v_salida_id bigint;
  v_entrada_id bigint;
  v_transferencia_id bigint;
  v_resultado jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: usuario no autenticado.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.empleados AS e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND lower(COALESCE(e.rol, '')) IN ('admin', 'operador')
  ) THEN
    RAISE EXCEPTION 'Acceso denegado: rol no autorizado para traslados.';
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'request_id es obligatorio.';
  END IF;

  IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad debe ser mayor a cero.';
  END IF;

  IF p_origen_id IS NULL OR p_destino_id IS NULL THEN
    RAISE EXCEPTION 'Origen y destino son obligatorios.';
  END IF;

  IF p_origen_id = p_destino_id THEN
    RAISE EXCEPTION 'El origen y destino deben ser diferentes.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));

  SELECT io.resultado, io.tipo_operacion, io.producto_id
  INTO v_previo, v_tipo_previo, v_producto_previo
  FROM public.inventario_operaciones_idempotentes AS io
  WHERE io.request_id = p_request_id;

  IF FOUND THEN
    IF v_tipo_previo <> 'TRASLADO' OR v_producto_previo <> p_producto_id THEN
      RAISE EXCEPTION 'El request_id ya fue utilizado en otra operación.';
    END IF;
    RETURN v_previo;
  END IF;

  v_motivo_origen := CASE
    WHEN NULLIF(trim(COALESCE(p_motivo, '')), '') IS NULL
      THEN 'Traslado (origen)'
    ELSE 'Traslado (origen) - ' || trim(p_motivo)
  END;

  v_motivo_destino := CASE
    WHEN NULLIF(trim(COALESCE(p_motivo, '')), '') IS NULL
      THEN 'Traslado (destino)'
    ELSE 'Traslado (destino) - ' || trim(p_motivo)
  END;

  v_salida_id := public._aplicar_movimiento_inventario_v2(
    p_producto_id := p_producto_id,
    p_almacen_id := p_origen_id,
    p_delta := -p_cantidad,
    p_tipo_movimiento := 'TRASLADO_SALIDA',
    p_motivo := v_motivo_origen,
    p_fecha := COALESCE(p_fecha, now()),
    p_request_id := p_request_id
  );

  v_entrada_id := public._aplicar_movimiento_inventario_v2(
    p_producto_id := p_producto_id,
    p_almacen_id := p_destino_id,
    p_delta := p_cantidad,
    p_tipo_movimiento := 'TRASLADO_ENTRADA',
    p_motivo := v_motivo_destino,
    p_fecha := COALESCE(p_fecha, now()),
    p_request_id := p_request_id
  );

  INSERT INTO public.transferencias_stock(
    request_id,
    producto_id,
    almacen_origen_id,
    almacen_destino_id,
    cantidad,
    fecha,
    motivo,
    movimiento_salida_id,
    movimiento_entrada_id
  )
  VALUES (
    p_request_id,
    p_producto_id,
    p_origen_id,
    p_destino_id,
    p_cantidad,
    COALESCE(p_fecha, now()),
    NULLIF(trim(COALESCE(p_motivo, '')), ''),
    v_salida_id,
    v_entrada_id
  )
  RETURNING id INTO v_transferencia_id;

  v_resultado := jsonb_build_object(
    'success', true,
    'request_id', p_request_id,
    'producto_id', p_producto_id,
    'transferencia_id', v_transferencia_id,
    'movimiento_salida_id', v_salida_id,
    'movimiento_entrada_id', v_entrada_id,
    'cantidad_base', p_cantidad
  );

  INSERT INTO public.inventario_operaciones_idempotentes(
    request_id, tipo_operacion, producto_id, resultado
  )
  VALUES (p_request_id, 'TRASLADO', p_producto_id, v_resultado);

  RETURN v_resultado;
END;
$function$
;

