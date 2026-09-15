-- Bootstrap de StOmni para entorno nuevo de pruebas.
-- Sólo estructura; no contiene datos del proyecto original.

ALTER DEFAULT PRIVILEGES IN SCHEMA public
REVOKE ALL ON TABLES FROM anon, authenticated;
SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;
CREATE SCHEMA IF NOT EXISTS "public";
ALTER SCHEMA "public" OWNER TO "pg_database_owner";
COMMENT ON SCHEMA "public" IS 'standard public schema';
CREATE OR REPLACE FUNCTION "public"."_aplicar_movimiento_inventario_v2"("p_producto_id" bigint, "p_almacen_id" bigint, "p_delta" integer, "p_tipo_movimiento" "text", "p_motivo" "text", "p_fecha" timestamp with time zone, "p_ingreso_costo" numeric DEFAULT 0, "p_ingreso_p_unit" numeric DEFAULT 0, "p_ingreso_p_caja" numeric DEFAULT 0, "p_ingreso_p_c_comp" numeric DEFAULT 0, "p_salida_cliente" "text" DEFAULT NULL::"text", "p_salida_p_unit" numeric DEFAULT 0, "p_salida_total" numeric DEFAULT 0, "p_proveedor_nombre" "text" DEFAULT NULL::"text", "p_request_id" "uuid" DEFAULT NULL::"uuid") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_tipo text;
  v_es_ingreso boolean;
  v_nombre text;
  v_pcs integer;
  v_tipo_venta text;
  v_unidad_base text;
  v_proveedor text;
  v_almacen_nombre text;
  v_stock integer;
  v_saldo integer;
  v_movimiento_id bigint;
BEGIN
  IF p_producto_id IS NULL OR p_almacen_id IS NULL THEN
    RAISE EXCEPTION 'producto_id y almacen_id son obligatorios.';
  END IF;

  IF p_delta IS NULL OR p_delta = 0 THEN
    RAISE EXCEPTION 'La cantidad debe ser diferente de cero.';
  END IF;

  PERFORM pg_advisory_xact_lock(p_producto_id);

  v_tipo := UPPER(TRIM(COALESCE(p_tipo_movimiento, '')));
  v_es_ingreso := p_delta > 0;

  IF v_es_ingreso AND v_tipo NOT IN
    ('ENTRADA','INGRESO','AJUSTE_ENTRADA','TRASLADO_ENTRADA') THEN
    RAISE EXCEPTION 'Un delta positivo no puede registrarse como %.', v_tipo;
  END IF;

  IF NOT v_es_ingreso AND v_tipo NOT IN
    ('SALIDA','MERMA','AJUSTE_SALIDA','TRASLADO_SALIDA') THEN
    RAISE EXCEPTION 'Un delta negativo no puede registrarse como %.', v_tipo;
  END IF;

  SELECT
    p.nombre,
    GREATEST(COALESCE(p.cantidad_por_caja, 1), 1),
    UPPER(TRIM(COALESCE(p.tipo_venta, ''))),
    COALESCE(pr.nombre, 'Generico')
  INTO v_nombre, v_pcs, v_tipo_venta, v_proveedor
  FROM public.productos AS p
  LEFT JOIN public.proveedores AS pr ON pr.id = p.proveedor_id
  WHERE p.id = p_producto_id
    AND COALESCE(p.activo, true) = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El producto % no existe o está inactivo.', p_producto_id;
  END IF;

  v_unidad_base := CASE
    WHEN v_tipo_venta IN
      ('PAQUETES','PAQUETE','CAJA_PAQUETES','CAJA','SOLO_CAJAS')
      THEN 'Paquete'
    WHEN v_tipo_venta IN
      ('CAJA_UNIDADES','AMBOS','CAJA_UNIDAD','CAJAS_UNIDADES',
       'UNIDAD','SOLO_UNIDADES')
      THEN 'Unidad'
    ELSE NULL
  END;

  IF v_unidad_base IS NULL THEN
    RAISE EXCEPTION 'Tipo de venta no reconocido: %.', v_tipo_venta;
  END IF;

  SELECT a.nombre
  INTO v_almacen_nombre
  FROM public.almacenes AS a
  WHERE a.id = p_almacen_id AND COALESCE(a.activo, false) = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El almacén % no existe o está inactivo.', p_almacen_id;
  END IF;

  SELECT COALESCE(ia.cantidad, 0)
  INTO v_stock
  FROM public.inventario_almacen AS ia
  WHERE ia.producto_id = p_producto_id
    AND ia.almacen_id = p_almacen_id
  FOR UPDATE;

  IF NOT FOUND THEN
    IF p_delta < 0 THEN
      RAISE EXCEPTION
        'No existe stock para el producto % en el almacén %.',
        p_producto_id, p_almacen_id;
    END IF;

    INSERT INTO public.inventario_almacen(producto_id, almacen_id, cantidad)
    VALUES (p_producto_id, p_almacen_id, 0)
    ON CONFLICT (producto_id, almacen_id) DO NOTHING;

    SELECT COALESCE(ia.cantidad, 0)
    INTO v_stock
    FROM public.inventario_almacen AS ia
    WHERE ia.producto_id = p_producto_id
      AND ia.almacen_id = p_almacen_id
    FOR UPDATE;
  END IF;

  v_saldo := v_stock + p_delta;

  IF v_saldo < 0 THEN
    RAISE EXCEPTION
      'Stock insuficiente. Disponible: %, requerido: %.',
      v_stock, ABS(p_delta);
  END IF;

  UPDATE public.inventario_almacen
  SET cantidad = v_saldo
  WHERE producto_id = p_producto_id AND almacen_id = p_almacen_id;

  v_proveedor := COALESCE(
    NULLIF(TRIM(p_proveedor_nombre), ''),
    v_proveedor
  );

  INSERT INTO public.inventario_movimientos (
    fecha, producto_id, producto_nombre, pcs, proveedor,
    tipo, saldo, almacen_id, almacen_nombre, observaciones,
    ingreso_cant, ingreso_und, ingreso_costo, ingreso_p_unit,
    ingreso_p_caja, ingreso_p_c_comp,
    salida_cant, salida_und, salida_cliente, salida_p_unit, salida_total,
    tipo_venta_snapshot, unidad_base_snapshot, request_id
  )
  VALUES (
    COALESCE(p_fecha, now()),
    p_producto_id, v_nombre, v_pcs, v_proveedor,
    v_tipo, v_saldo, p_almacen_id, COALESCE(v_almacen_nombre, ''),
    NULLIF(TRIM(COALESCE(p_motivo, '')), ''),
    CASE WHEN v_es_ingreso THEN ABS(p_delta) END,
    CASE WHEN v_es_ingreso THEN v_unidad_base END,
    CASE WHEN v_es_ingreso THEN COALESCE(p_ingreso_costo, 0) END,
    CASE WHEN v_es_ingreso THEN COALESCE(p_ingreso_p_unit, 0) END,
    CASE WHEN v_es_ingreso THEN p_ingreso_p_caja END,
    CASE WHEN v_es_ingreso THEN p_ingreso_p_c_comp END,
    CASE WHEN NOT v_es_ingreso THEN ABS(p_delta) END,
    CASE WHEN NOT v_es_ingreso THEN v_unidad_base END,
    CASE WHEN NOT v_es_ingreso THEN p_salida_cliente END,
    CASE WHEN NOT v_es_ingreso THEN COALESCE(p_salida_p_unit, 0) END,
    CASE WHEN NOT v_es_ingreso THEN COALESCE(p_salida_total, 0) END,
    v_tipo_venta, v_unidad_base, p_request_id
  )
  RETURNING id INTO v_movimiento_id;

  RETURN v_movimiento_id;
END;
$$;
ALTER FUNCTION "public"."_aplicar_movimiento_inventario_v2"("p_producto_id" bigint, "p_almacen_id" bigint, "p_delta" integer, "p_tipo_movimiento" "text", "p_motivo" "text", "p_fecha" timestamp with time zone, "p_ingreso_costo" numeric, "p_ingreso_p_unit" numeric, "p_ingreso_p_caja" numeric, "p_ingreso_p_c_comp" numeric, "p_salida_cliente" "text", "p_salida_p_unit" numeric, "p_salida_total" numeric, "p_proveedor_nombre" "text", "p_request_id" "uuid") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."_aplicar_stock_nota_credito"("p_nota_credito_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_nota record;
  v_det record;
  v_movimiento_id bigint;
  v_error text;
  v_pendientes integer;
BEGIN
  SELECT *
  INTO v_nota
  FROM public.notas_credito
  WHERE id = p_nota_credito_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nota de crédito no encontrada';
  END IF;

  IF v_nota.estado <> 'aceptado' THEN
    RETURN jsonb_build_object(
      'success', false,
      'aplicado', false,
      'mensaje', 'La nota todavía no está aceptada'
    );
  END IF;

  IF v_nota.reponer_stock = false THEN
    RETURN jsonb_build_object(
      'success', true,
      'aplicado', false,
      'mensaje', 'La nota no afecta stock'
    );
  END IF;

  IF v_nota.stock_aplicado = true THEN
    RETURN jsonb_build_object(
      'success', true,
      'aplicado', true,
      'idempotent', true
    );
  END IF;

  BEGIN
    FOR v_det IN
      SELECT *
      FROM public.notas_credito_detalles
      WHERE nota_credito_id = p_nota_credito_id
        AND repone_stock = true
        AND stock_aplicado = false
        AND piezas_reales > 0
      ORDER BY id
      FOR UPDATE
    LOOP
      v_movimiento_id := public._aplicar_movimiento_inventario_v2(
        p_producto_id := v_det.producto_id,
        p_almacen_id := v_det.almacen_id,
        p_delta := v_det.piezas_reales,
        p_tipo_movimiento := 'AJUSTE_ENTRADA',
        p_motivo :=
          'Nota de crédito ' || v_nota.serie || '-' ||
          v_nota.correlativo || ' - ' || v_nota.motivo_descripcion,
        p_fecha := now(),
        p_request_id := v_det.id
      );

      UPDATE public.notas_credito_detalles
      SET
        stock_aplicado = true,
        movimiento_inventario_id = v_movimiento_id
      WHERE id = v_det.id;
    END LOOP;

    SELECT COUNT(*)
    INTO v_pendientes
    FROM public.notas_credito_detalles
    WHERE nota_credito_id = p_nota_credito_id
      AND repone_stock = true
      AND stock_aplicado = false;

    UPDATE public.notas_credito
    SET
      stock_aplicado = (v_pendientes = 0),
      stock_error = NULL,
      stock_ultimo_intento_at = now()
    WHERE id = p_nota_credito_id;

    RETURN jsonb_build_object(
      'success', true,
      'aplicado', v_pendientes = 0,
      'pendientes', v_pendientes
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;

    UPDATE public.notas_credito
    SET
      stock_aplicado = false,
      stock_error = v_error,
      stock_reintentos = stock_reintentos + 1,
      stock_ultimo_intento_at = now()
    WHERE id = p_nota_credito_id;

    RETURN jsonb_build_object(
      'success', false,
      'aplicado', false,
      'error', v_error
    );
  END;
END;
$$;
ALTER FUNCTION "public"."_aplicar_stock_nota_credito"("p_nota_credito_id" "uuid") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."_gre_agencia_set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
ALTER FUNCTION "public"."_gre_agencia_set_updated_at"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."_gre_empleado_activo"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND e.rol IN ('admin', 'operador')
  );
$$;
ALTER FUNCTION "public"."_gre_empleado_activo"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."_gre_supervisor"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.empleados AS e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND e.rol = 'admin'
  );
$$;
ALTER FUNCTION "public"."_gre_supervisor"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."_normalizar_tipo_unidad_documento"("p_tipo_unidad" "text", "p_tipo_venta_normalizado" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_unidad text := LOWER(TRIM(COALESCE(p_tipo_unidad, '')));
  v_tipo text := UPPER(TRIM(COALESCE(p_tipo_venta_normalizado, '')));
BEGIN
  IF v_tipo = 'PAQUETES' THEN
    RETURN 'paquete';
  END IF;

  IF v_unidad IN ('caja', 'cajas', 'box') THEN
    RETURN 'caja';
  END IF;

  IF v_tipo = 'CAJA_PAQUETES' THEN
    RETURN 'paquete';
  END IF;

  RETURN 'unidad';
END;
$$;
ALTER FUNCTION "public"."_normalizar_tipo_unidad_documento"("p_tipo_unidad" "text", "p_tipo_venta_normalizado" "text") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."_normalizar_tipo_venta_documento"("p_tipo_venta" "text") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_tipo text := UPPER(TRIM(COALESCE(p_tipo_venta, '')));
BEGIN
  IF v_tipo IN ('PAQUETES', 'PAQUETE', 'CAJA', 'SOLO_CAJAS') THEN
    RETURN 'PAQUETES';
  END IF;

  IF v_tipo IN ('CAJA_PAQUETES', 'CAJAS_PAQUETES') THEN
    RETURN 'CAJA_PAQUETES';
  END IF;

  IF v_tipo IN (
    'CAJA_UNIDADES',
    'CAJAS_UNIDADES',
    'CAJA_UNIDAD',
    'AMBOS',
    'UNIDAD',
    'SOLO_UNIDADES'
  ) THEN
    RETURN 'CAJA_UNIDADES';
  END IF;

  RETURN v_tipo;
END;
$$;
ALTER FUNCTION "public"."_normalizar_tipo_venta_documento"("p_tipo_venta" "text") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."_revertir_stock_nota_credito_por_baja"("p_nota_credito_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_nota record;
  v_det record;
  v_movimiento_id bigint;
  v_pendientes integer;
  v_error text;
BEGIN
  SELECT *
  INTO v_nota
  FROM public.notas_credito
  WHERE id = p_nota_credito_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nota de crédito no encontrada';
  END IF;

  IF COALESCE(v_nota.estado_baja_tributaria, 'ninguna') <> 'aceptada' THEN
    RETURN jsonb_build_object(
      'success', false,
      'aplicado', false,
      'mensaje', 'La baja tributaria de la nota todavía no está aceptada'
    );
  END IF;

  IF v_nota.baja_stock_revertido = true THEN
    RETURN jsonb_build_object(
      'success', true,
      'aplicado', true,
      'idempotent', true
    );
  END IF;

  -- Si la nota nunca repuso stock, no existe efecto físico que revertir.
  IF v_nota.reponer_stock = false OR v_nota.stock_aplicado = false THEN
    UPDATE public.notas_credito
    SET
      baja_stock_revertido = true,
      baja_stock_error = NULL,
      baja_stock_ultimo_intento_at = now()
    WHERE id = p_nota_credito_id;

    PERFORM public.recalcular_estado_tributario_venta(v_nota.venta_id);

    RETURN jsonb_build_object(
      'success', true,
      'aplicado', false,
      'mensaje', 'La nota no tenía reposición de stock que revertir'
    );
  END IF;

  BEGIN
    UPDATE public.notas_credito
    SET
      baja_stock_reintentos = baja_stock_reintentos + 1,
      baja_stock_ultimo_intento_at = now()
    WHERE id = p_nota_credito_id;

    FOR v_det IN
      SELECT *
      FROM public.notas_credito_detalles
      WHERE nota_credito_id = p_nota_credito_id
        AND repone_stock = true
        AND stock_aplicado = true
        AND baja_stock_revertido = false
        AND piezas_reales > 0
      ORDER BY id
      FOR UPDATE
    LOOP
      v_movimiento_id := public._aplicar_movimiento_inventario_v2(
        p_producto_id := v_det.producto_id,
        p_almacen_id := v_det.almacen_id,
        p_delta := -v_det.piezas_reales,
        p_tipo_movimiento := 'AJUSTE_SALIDA',
        p_motivo :=
          'Baja tributaria de nota de crédito ' ||
          v_nota.serie || '-' || v_nota.correlativo,
        p_fecha := now(),
        p_request_id := v_det.baja_request_id
      );

      UPDATE public.notas_credito_detalles
      SET
        baja_stock_revertido = true,
        movimiento_baja_id = v_movimiento_id
      WHERE id = v_det.id;
    END LOOP;

    SELECT COUNT(*)
    INTO v_pendientes
    FROM public.notas_credito_detalles
    WHERE nota_credito_id = p_nota_credito_id
      AND repone_stock = true
      AND stock_aplicado = true
      AND baja_stock_revertido = false;

    UPDATE public.notas_credito
    SET
      baja_stock_revertido = (v_pendientes = 0),
      baja_stock_error = NULL,
      baja_stock_ultimo_intento_at = now()
    WHERE id = p_nota_credito_id;

    PERFORM public.recalcular_estado_tributario_venta(v_nota.venta_id);

    RETURN jsonb_build_object(
      'success', true,
      'aplicado', v_pendientes = 0,
      'pendientes', v_pendientes
    );
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;

    UPDATE public.notas_credito
    SET
      baja_stock_revertido = false,
      baja_stock_error = v_error,
      baja_stock_ultimo_intento_at = now()
    WHERE id = p_nota_credito_id;

    PERFORM public.recalcular_estado_tributario_venta(v_nota.venta_id);

    RETURN jsonb_build_object(
      'success', false,
      'aplicado', false,
      'error', v_error
    );
  END;
END;
$$;
ALTER FUNCTION "public"."_revertir_stock_nota_credito_por_baja"("p_nota_credito_id" "uuid") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."_revertir_stock_venta_por_baja"("p_venta_id" bigint) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_detalle record;
  v_saldo integer;
  v_unidad_base text;
  v_venta record;
  v_actor_id bigint;
  v_actor_nombre text;
BEGIN
  -- Validar si la venta existe
  SELECT v.id, v.vendedor_id, e.nombre AS vendedor_nombre, v.request_id
  INTO v_venta
  FROM public.ventas v
  LEFT JOIN public.empleados e ON e.id = v.vendedor_id
  WHERE v.id = p_venta_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Intentar obtener el usuario que solicitó la baja originalmente
  SELECT e.id, e.nombre
  INTO v_actor_id, v_actor_nombre
  FROM public.solicitudes_baja_tributaria s
  JOIN public.empleados e ON e.auth_id = s.creado_por
  WHERE s.venta_id = p_venta_id
  LIMIT 1;

  -- Si no se encuentra (caso raro), obtener el usuario que está consultando
  IF NOT FOUND THEN
    SELECT id, nombre
    INTO v_actor_id, v_actor_nombre
    FROM public.empleados
    WHERE auth_id = auth.uid()
    LIMIT 1;
  END IF;

  -- Si todo falla, poner Sistema
  IF v_actor_nombre IS NULL THEN
    v_actor_nombre := 'Sistema (SUNAT)';
  END IF;

  -- Iterar sobre cada producto de la venta para devolverlo al almacén
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
      CONTINUE;
    END IF;

    -- Bloqueo consultivo para evitar race conditions
    PERFORM pg_advisory_xact_lock(v_detalle.producto_id);

    -- Devolver stock al almacén
    INSERT INTO public.inventario_almacen(producto_id, almacen_id, cantidad)
    VALUES(v_detalle.producto_id, v_detalle.almacen_id, v_detalle.piezas_reales)
    ON CONFLICT(producto_id, almacen_id)
    DO UPDATE SET cantidad = public.inventario_almacen.cantidad + EXCLUDED.cantidad
    RETURNING cantidad INTO v_saldo;

    v_unidad_base := v_detalle.unidad_base;

    -- Registrar en Kardex
    INSERT INTO public.inventario_movimientos(
      fecha, producto_id, producto_nombre, pcs, proveedor,
      tipo, saldo, almacen_id, almacen_nombre, observaciones,
      ingreso_cant, ingreso_und, ingreso_p_unit,
      venta_id, venta_id_original, vendedor_id, vendedor_nombre_snapshot,
      motivo_anulacion,
      anulado_por_id, anulado_por_nombre_snapshot,
      tipo_venta_snapshot, unidad_base_snapshot, request_id
    ) VALUES (
      clock_timestamp(), v_detalle.producto_id, v_detalle.producto_nombre,
      v_detalle.pcs, v_detalle.proveedor,
      'ANULACION_VENTA', v_saldo, v_detalle.almacen_id,
      COALESCE(v_detalle.almacen_nombre, ''),
      'Baja Tributaria Aceptada SUNAT - Venta #' || p_venta_id,
      v_detalle.piezas_reales, v_unidad_base, v_detalle.precio_unitario,
      p_venta_id, p_venta_id, v_venta.vendedor_id, v_venta.vendedor_nombre,
      'Baja Tributaria Aceptada',
      v_actor_id, v_actor_nombre,
      v_detalle.tipo_venta, v_unidad_base, v_venta.request_id
    );
  END LOOP;
END;
$$;
ALTER FUNCTION "public"."_revertir_stock_venta_por_baja"("p_venta_id" bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."_stock_alert_acumular_tx"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  IF NEW.cantidad IS NOT DISTINCT FROM OLD.cantidad THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.stock_alert_tx_context (
    txid,
    producto_id,
    delta_total
  )
  VALUES (
    txid_current(),
    NEW.producto_id,
    COALESCE(OLD.cantidad, 0) - COALESCE(NEW.cantidad, 0)
  )
  ON CONFLICT (txid, producto_id)
  DO UPDATE SET
    delta_total = public.stock_alert_tx_context.delta_total + EXCLUDED.delta_total;

  RETURN NEW;
END;
$$;
ALTER FUNCTION "public"."_stock_alert_acumular_tx"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."_validar_desactivacion_almacen_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_filas_con_stock bigint;
  v_stock_total bigint;
BEGIN
  IF OLD.activo IS NOT DISTINCT FROM NEW.activo
     OR COALESCE(NEW.activo, false) = true THEN
    RETURN NEW;
  END IF;

  SELECT
    COUNT(*) FILTER (WHERE COALESCE(ia.cantidad, 0) <> 0),
    COALESCE(SUM(COALESCE(ia.cantidad, 0)), 0)
  INTO v_filas_con_stock, v_stock_total
  FROM public.inventario_almacen AS ia
  WHERE ia.almacen_id = OLD.id;

  IF COALESCE(v_filas_con_stock, 0) > 0 THEN
    RAISE EXCEPTION
      'No se puede desactivar el almacen: contiene stock. Stock neto actual: %.',
      v_stock_total;
  END IF;

  RETURN NEW;
END;
$$;
ALTER FUNCTION "public"."_validar_desactivacion_almacen_v1"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."_validar_stock_en_almacen_activo_v1"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_activo boolean;
BEGIN
  IF COALESCE(NEW.cantidad, 0) = 0 THEN
    RETURN NEW;
  END IF;

  SELECT a.activo
  INTO v_activo
  FROM public.almacenes AS a
  WHERE a.id = NEW.almacen_id
  FOR KEY SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Almacen % no existe', NEW.almacen_id;
  END IF;

  IF COALESCE(v_activo, false) = false THEN
    RAISE EXCEPTION
      'No se puede registrar stock en un almacen inactivo. Reactivalo primero.';
  END IF;

  RETURN NEW;
END;
$$;
ALTER FUNCTION "public"."_validar_stock_en_almacen_activo_v1"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."actualizar_configuracion_negocio_v1"("p_datos" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
DECLARE
  v_row public.configuracion_negocio%ROWTYPE;
  v_ruc text;
  v_ubigeo text;
  v_razon_social text;
  v_direccion text;
  v_departamento text;
  v_provincia text;
  v_distrito text;
  v_cod_local text;
  v_keys_permitidas constant text[] := ARRAY[
    'razon_social', 'nombre_comercial', 'ruc', 'direccion', 'ubigeo',
    'departamento', 'provincia', 'distrito', 'cod_local', 'telefono', 'logo_url'
  ];
  v_key text;
BEGIN
  IF NOT public.app_es_admin() THEN
    RAISE EXCEPTION 'Solo el administrador puede modificar la empresa';
  END IF;

  IF p_datos IS NULL OR jsonb_typeof(p_datos) <> 'object' THEN
    RAISE EXCEPTION 'Los datos de configuración son inválidos';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_datos)
  LOOP
    IF NOT (v_key = ANY (v_keys_permitidas)) THEN
      RAISE EXCEPTION 'Campo no permitido en esta pantalla: %', v_key;
    END IF;
  END LOOP;

  SELECT * INTO v_row
  FROM public.configuracion_negocio
  WHERE id = 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No existe configuracion_negocio con id=1. Créala antes de usar esta RPC.';
  END IF;

  v_ruc := trim(COALESCE(p_datos->>'ruc', v_row.ruc, ''));
  v_ubigeo := trim(COALESCE(p_datos->>'ubigeo', v_row.ubigeo, ''));
  v_razon_social := trim(COALESCE(p_datos->>'razon_social', v_row.razon_social, ''));
  v_direccion := trim(COALESCE(p_datos->>'direccion', v_row.direccion, ''));
  v_departamento := upper(trim(COALESCE(p_datos->>'departamento', v_row.departamento, '')));
  v_provincia := upper(trim(COALESCE(p_datos->>'provincia', v_row.provincia, '')));
  v_distrito := upper(trim(COALESCE(p_datos->>'distrito', v_row.distrito, '')));
  v_cod_local := trim(COALESCE(p_datos->>'cod_local', v_row.cod_local, '0000'));

  IF v_ruc !~ '^[0-9]{11}$' THEN
    RAISE EXCEPTION 'El RUC debe contener exactamente 11 dígitos';
  END IF;
  IF v_ubigeo !~ '^[0-9]{6}$' THEN
    RAISE EXCEPTION 'El ubigeo debe contener exactamente 6 dígitos';
  END IF;
  IF v_razon_social = '' OR v_direccion = '' OR v_departamento = ''
     OR v_provincia = '' OR v_distrito = '' THEN
    RAISE EXCEPTION 'Razón social y domicilio fiscal completo son obligatorios';
  END IF;
  IF v_cod_local !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION 'El código de local debe contener exactamente 4 dígitos';
  END IF;

  UPDATE public.configuracion_negocio c
  SET
    razon_social = CASE WHEN p_datos ? 'razon_social' THEN v_razon_social ELSE c.razon_social END,
    nombre_comercial = CASE WHEN p_datos ? 'nombre_comercial' THEN NULLIF(trim(p_datos->>'nombre_comercial'), '') ELSE c.nombre_comercial END,
    ruc = CASE WHEN p_datos ? 'ruc' THEN v_ruc ELSE c.ruc END,
    direccion = CASE WHEN p_datos ? 'direccion' THEN v_direccion ELSE c.direccion END,
    ubigeo = CASE WHEN p_datos ? 'ubigeo' THEN v_ubigeo ELSE c.ubigeo END,
    departamento = CASE WHEN p_datos ? 'departamento' THEN v_departamento ELSE c.departamento END,
    provincia = CASE WHEN p_datos ? 'provincia' THEN v_provincia ELSE c.provincia END,
    distrito = CASE WHEN p_datos ? 'distrito' THEN v_distrito ELSE c.distrito END,
    cod_local = CASE WHEN p_datos ? 'cod_local' THEN v_cod_local ELSE c.cod_local END,
    telefono = CASE WHEN p_datos ? 'telefono' THEN NULLIF(trim(p_datos->>'telefono'), '') ELSE c.telefono END,
    logo_url = CASE WHEN p_datos ? 'logo_url' THEN NULLIF(trim(p_datos->>'logo_url'), '') ELSE c.logo_url END
  WHERE c.id = 1
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$_$;
ALTER FUNCTION "public"."actualizar_configuracion_negocio_v1"("p_datos" "jsonb") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."actualizar_cotizaciones_vencidas"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado: empleado no autenticado o inactivo.';
  END IF;

  UPDATE public.cotizaciones
  SET estado = 'vencida'
  WHERE estado = 'pendiente'
    AND (fecha + (COALESCE(validez_dias, 15) || ' days')::interval) < now();
END;
$$;
ALTER FUNCTION "public"."actualizar_cotizaciones_vencidas"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."actualizar_producto_seguro_v1"("p_producto_id" bigint, "p_datos" "jsonb", "p_actualizar_apertura" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
DECLARE
  v_producto public.productos%ROWTYPE;
  v_actualizado public.productos%ROWTYPE;
  v_evaluacion jsonb;

  v_codigo text;
  v_nombre text;
  v_precio_unidad numeric;
  v_precio_caja numeric;
  v_precio_compra numeric;
  v_imagen_path text;
  v_unidad_medida text;
  v_cantidad_por_caja integer;
  v_proveedor_id bigint;
  v_permitir_sin_stock boolean;
  v_tipo_venta text;
  v_stock_minimo integer;

  v_proveedor_nombre text;
  v_unidad_base text;
  v_aperturas_actualizadas bigint := 0;
  v_clave_no_permitida text;
BEGIN
  IF NOT public.app_es_admin() THEN
    RAISE EXCEPTION 'Solo el administrador puede editar productos.';
  END IF;

  IF p_producto_id IS NULL THEN
    RAISE EXCEPTION 'El producto_id es obligatorio.';
  END IF;

  IF p_datos IS NULL OR jsonb_typeof(p_datos) <> 'object' THEN
    RAISE EXCEPTION 'Los datos del producto son inválidos.';
  END IF;

  SELECT clave
  INTO v_clave_no_permitida
  FROM jsonb_object_keys(p_datos) AS k(clave)
  WHERE clave NOT IN (
    'codigo',
    'nombre',
    'precio_unidad',
    'precio_caja',
    'precio_compra',
    'imagen_path',
    'unidad_medida',
    'cantidad_por_caja',
    'proveedor_id',
    'permitir_sin_stock',
    'tipo_venta',
    'stock_minimo'
  )
  LIMIT 1;

  IF v_clave_no_permitida IS NOT NULL THEN
    RAISE EXCEPTION
      'El campo % no puede modificarse mediante esta función.',
      v_clave_no_permitida;
  END IF;

  PERFORM pg_advisory_xact_lock(p_producto_id);

  SELECT *
  INTO v_producto
  FROM public.productos
  WHERE id = p_producto_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El producto % no existe.', p_producto_id;
  END IF;

  v_codigo := UPPER(
    TRIM(
      CASE
        WHEN p_datos ? 'codigo' THEN COALESCE(p_datos->>'codigo', '')
        ELSE COALESCE(v_producto.codigo, '')
      END
    )
  );

  v_nombre := TRIM(
    CASE
      WHEN p_datos ? 'nombre' THEN COALESCE(p_datos->>'nombre', '')
      ELSE COALESCE(v_producto.nombre, '')
    END
  );

  v_precio_unidad := CASE
    WHEN p_datos ? 'precio_unidad'
      THEN COALESCE(NULLIF(p_datos->>'precio_unidad', '')::numeric, 0)
    ELSE COALESCE(v_producto.precio_unidad, 0)
  END;

  v_precio_caja := CASE
    WHEN p_datos ? 'precio_caja'
      THEN COALESCE(NULLIF(p_datos->>'precio_caja', '')::numeric, 0)
    ELSE COALESCE(v_producto.precio_caja, 0)
  END;

  v_precio_compra := CASE
    WHEN p_datos ? 'precio_compra'
      THEN COALESCE(NULLIF(p_datos->>'precio_compra', '')::numeric, 0)
    ELSE COALESCE(v_producto.precio_compra, 0)
  END;

  v_imagen_path := CASE
    WHEN p_datos ? 'imagen_path'
      THEN NULLIF(TRIM(COALESCE(p_datos->>'imagen_path', '')), '')
    ELSE v_producto.imagen_path
  END;

  v_cantidad_por_caja := CASE
    WHEN p_datos ? 'cantidad_por_caja'
      THEN COALESCE(
        NULLIF(p_datos->>'cantidad_por_caja', '')::integer,
        0
      )
    ELSE COALESCE(v_producto.cantidad_por_caja, 0)
  END;

  v_proveedor_id := CASE
    WHEN p_datos ? 'proveedor_id'
      THEN NULLIF(p_datos->>'proveedor_id', '')::bigint
    ELSE v_producto.proveedor_id
  END;

  v_permitir_sin_stock := CASE
    WHEN p_datos ? 'permitir_sin_stock'
      THEN COALESCE(
        NULLIF(p_datos->>'permitir_sin_stock', '')::boolean,
        false
      )
    ELSE COALESCE(v_producto.permitir_sin_stock, false)
  END;

  v_tipo_venta := UPPER(
    TRIM(
      CASE
        WHEN p_datos ? 'tipo_venta'
          THEN COALESCE(p_datos->>'tipo_venta', '')
        ELSE COALESCE(v_producto.tipo_venta, '')
      END
    )
  );

  v_stock_minimo := CASE
    WHEN p_datos ? 'stock_minimo'
      THEN COALESCE(NULLIF(p_datos->>'stock_minimo', '')::integer, 0)
    ELSE COALESCE(v_producto.stock_minimo, 0)
  END;

  v_unidad_medida := CASE
    WHEN v_tipo_venta IN ('PAQUETES', 'CAJA_PAQUETES')
      THEN 'Paquetes'
    WHEN v_tipo_venta = 'CAJA_UNIDADES'
      THEN 'Unidades'
    ELSE TRIM(
      CASE
        WHEN p_datos ? 'unidad_medida'
          THEN COALESCE(p_datos->>'unidad_medida', '')
        ELSE COALESCE(v_producto.unidad_medida, '')
      END
    )
  END;

  IF v_codigo = '' THEN
    RAISE EXCEPTION 'El código del producto es obligatorio.';
  END IF;

  IF LENGTH(v_codigo) > 50 THEN
    RAISE EXCEPTION 'El código no puede superar 50 caracteres.';
  END IF;

  IF v_codigo !~ '^[A-Z0-9._/-]+$' THEN
    RAISE EXCEPTION
      'El código solo puede contener letras, números, punto, guion, barra o guion bajo.';
  END IF;

  IF v_nombre = '' THEN
    RAISE EXCEPTION 'El nombre del producto no puede estar vacío.';
  END IF;

  IF v_tipo_venta NOT IN (
    'PAQUETES',
    'CAJA_PAQUETES',
    'CAJA_UNIDADES'
  ) THEN
    RAISE EXCEPTION
      'tipo_venta inválido. Debe ser PAQUETES, CAJA_PAQUETES o CAJA_UNIDADES.';
  END IF;

  IF v_precio_unidad < 0
     OR v_precio_caja < 0
     OR v_precio_compra < 0 THEN
    RAISE EXCEPTION 'Los precios y costos no pueden ser negativos.';
  END IF;

  IF v_cantidad_por_caja <= 1 THEN
    RAISE EXCEPTION
      'La cantidad contenida en el empaque debe ser mayor a 1.';
  END IF;

  IF v_stock_minimo < 0 THEN
    RAISE EXCEPTION 'El stock mínimo no puede ser negativo.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.productos AS p
    WHERE p.id <> p_producto_id
      AND UPPER(TRIM(COALESCE(p.codigo, ''))) = v_codigo
  ) THEN
    RAISE EXCEPTION 'Ya existe un producto con el código %.', v_codigo;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.productos AS p
    WHERE p.id <> p_producto_id
      AND COALESCE(p.activo, true) = true
      AND LOWER(TRIM(p.nombre)) = LOWER(v_nombre)
      AND UPPER(TRIM(COALESCE(p.tipo_venta, ''))) = v_tipo_venta
      AND p.proveedor_id IS NOT DISTINCT FROM v_proveedor_id
  ) THEN
    RAISE EXCEPTION
      'Ya existe un producto activo con el mismo nombre, proveedor y tipo de venta.';
  END IF;

  IF p_actualizar_apertura THEN
    v_evaluacion :=
      public.evaluar_eliminacion_producto_v1(p_producto_id);

    IF COALESCE(
      (v_evaluacion->>'puede_actualizar_apertura')::boolean,
      false
    ) = false THEN
      RAISE EXCEPTION
        'Los movimientos de apertura no pueden modificarse porque el producto ya tiene historial operativo o referencias.';
    END IF;
  END IF;

  UPDATE public.productos AS p
  SET
    codigo = v_codigo,
    nombre = v_nombre,
    precio_unidad = v_precio_unidad,
    precio_caja = v_precio_caja,
    precio_compra = v_precio_compra,
    imagen_path = v_imagen_path,
    unidad_medida = v_unidad_medida,
    cantidad_por_caja = v_cantidad_por_caja,
    proveedor_id = v_proveedor_id,
    permitir_sin_stock = v_permitir_sin_stock,
    tipo_venta = v_tipo_venta,
    stock_minimo = v_stock_minimo
  WHERE p.id = p_producto_id
  RETURNING *
  INTO v_actualizado;

  IF p_actualizar_apertura THEN
    SELECT COALESCE(pr.nombre, 'Generico')
    INTO v_proveedor_nombre
    FROM public.productos AS p
    LEFT JOIN public.proveedores AS pr
      ON pr.id = p.proveedor_id
    WHERE p.id = p_producto_id;

    v_unidad_base := CASE
      WHEN v_tipo_venta IN ('PAQUETES', 'CAJA_PAQUETES')
        THEN 'Paquete'
      ELSE 'Unidad'
    END;

    UPDATE public.inventario_movimientos AS m
    SET
      producto_nombre = v_nombre,
      pcs = v_cantidad_por_caja,
      proveedor = v_proveedor_nombre,
      tipo_venta_snapshot = v_tipo_venta,
      unidad_base_snapshot = v_unidad_base,
      ingreso_und = v_unidad_base
    WHERE m.producto_id = p_producto_id
      AND UPPER(TRIM(COALESCE(m.tipo, ''))) IN ('ENTRADA', 'INGRESO')
      AND UPPER(
        REGEXP_REPLACE(
          TRIM(COALESCE(m.observaciones, '')),
          '\s+',
          ' ',
          'g'
        )
      ) IN (
        'APERTURA DE INVENTARIO / STOCK INICIAL',
        'APERTURA DE INVENTARIO',
        'STOCK INICIAL'
      )
      AND m.venta_id IS NULL
      AND COALESCE(m.salida_cant, 0) = 0;

    GET DIAGNOSTICS v_aperturas_actualizadas = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'producto_id', p_producto_id,
    'producto', to_jsonb(v_actualizado),
    'aperturas_actualizadas', v_aperturas_actualizadas,
    'mensaje',
      CASE
        WHEN v_aperturas_actualizadas > 0
          THEN 'Producto y movimientos de apertura actualizados.'
        ELSE 'Producto actualizado.'
      END
  );
END;
$_$;
ALTER FUNCTION "public"."actualizar_producto_seguro_v1"("p_producto_id" bigint, "p_datos" "jsonb", "p_actualizar_apertura" boolean) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."ajustar_stock_y_kardex"("p_producto_id" bigint, "p_almacen_id" bigint, "p_delta" integer, "p_tipo_movimiento" "text", "p_motivo" "text", "p_ingreso_costo" numeric DEFAULT 0, "p_ingreso_p_unit" numeric DEFAULT 0, "p_ingreso_p_caja" numeric DEFAULT 0, "p_ingreso_p_c_comp" numeric DEFAULT 0, "p_salida_cliente" "text" DEFAULT NULL::"text", "p_salida_p_unit" numeric DEFAULT 0, "p_salida_total" numeric DEFAULT 0, "p_unidad_label" "text" DEFAULT 'AUTO'::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."ajustar_stock_y_kardex"("p_producto_id" bigint, "p_almacen_id" bigint, "p_delta" integer, "p_tipo_movimiento" "text", "p_motivo" "text", "p_ingreso_costo" numeric, "p_ingreso_p_unit" numeric, "p_ingreso_p_caja" numeric, "p_ingreso_p_c_comp" numeric, "p_salida_cliente" "text", "p_salida_p_unit" numeric, "p_salida_total" numeric, "p_unidad_label" "text") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."anular_venta"("p_venta_id" bigint, "p_detalles" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."anular_venta"("p_venta_id" bigint, "p_detalles" "jsonb") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."anular_venta_v2"("p_venta_id" bigint, "p_motivo" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
        'ticket_pendiente',
        'resultado_incierto'
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
    'vendedor', v_vendedor_nombre,
    'anulada_por', v_actor_nombre,
    'motivo', v_motivo
  );
END;
$$;
ALTER FUNCTION "public"."anular_venta_v2"("p_venta_id" bigint, "p_motivo" "text") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."app_empleado_activo"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND e.rol IN ('admin', 'operador')
  );
$$;
ALTER FUNCTION "public"."app_empleado_activo"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."app_es_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND e.rol = 'admin'
  );
$$;
ALTER FUNCTION "public"."app_es_admin"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."calcular_piezas_reales_stock"("p_tipo_venta" "text", "p_tipo_unidad" "text", "p_cantidad" integer, "p_pcs" integer) RETURNS integer
    LANGUAGE "plpgsql" IMMUTABLE STRICT
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_tipo_venta text := LOWER(TRIM(p_tipo_venta));
  v_tipo_unidad text := LOWER(TRIM(p_tipo_unidad));
  v_pcs integer := GREATEST(COALESCE(p_pcs, 1), 1);
BEGIN
  IF p_cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad visual debe ser mayor a cero';
  END IF;

  IF v_tipo_unidad IN ('cajas', 'box', 'bx') THEN
    v_tipo_unidad := 'caja';
  ELSIF v_tipo_unidad IN ('paquetes', 'paq', 'pack', 'pk') THEN
    v_tipo_unidad := 'paquete';
  ELSIF v_tipo_unidad IN ('unidades', 'und', 'niu', 'pieza', 'piezas') THEN
    v_tipo_unidad := 'unidad';
  END IF;

  IF v_tipo_venta IN ('paquetes', 'paquete') THEN
    IF v_tipo_unidad <> 'paquete' THEN
      RAISE EXCEPTION 'PAQUETES solo admite tipo_unidad=paquete';
    END IF;
    RETURN p_cantidad;
  END IF;

  IF v_tipo_venta = 'caja_paquetes' THEN
    IF v_tipo_unidad = 'caja' THEN
      RETURN p_cantidad * v_pcs;
    ELSIF v_tipo_unidad = 'paquete' THEN
      RETURN p_cantidad;
    END IF;
    RAISE EXCEPTION 'CAJA_PAQUETES solo admite caja o paquete';
  END IF;

  IF v_tipo_venta = 'caja_unidades' THEN
    IF v_tipo_unidad = 'caja' THEN
      RETURN p_cantidad * v_pcs;
    ELSIF v_tipo_unidad = 'unidad' THEN
      RETURN p_cantidad;
    END IF;
    RAISE EXCEPTION 'CAJA_UNIDADES solo admite caja o unidad';
  END IF;

  -- Compatibilidad histórica.
  IF v_tipo_venta IN ('caja', 'solo_cajas') THEN
    IF v_tipo_unidad <> 'caja' THEN
      RAISE EXCEPTION 'SOLO_CAJAS solo admite caja';
    END IF;
    RETURN p_cantidad;
  END IF;

  IF v_tipo_venta IN ('unidad', 'solo_unidades') THEN
    IF v_tipo_unidad <> 'unidad' THEN
      RAISE EXCEPTION 'SOLO_UNIDADES solo admite unidad';
    END IF;
    RETURN p_cantidad;
  END IF;

  IF v_tipo_venta IN ('ambos', 'caja_unidad', 'cajas_unidades') THEN
    IF v_tipo_unidad = 'caja' THEN
      RETURN p_cantidad * v_pcs;
    ELSIF v_tipo_unidad = 'unidad' THEN
      RETURN p_cantidad;
    END IF;
    RAISE EXCEPTION 'AMBOS solo admite caja o unidad';
  END IF;

  RAISE EXCEPTION 'Tipo de venta no reconocido: %', p_tipo_venta;
END;
$$;
ALTER FUNCTION "public"."calcular_piezas_reales_stock"("p_tipo_venta" "text", "p_tipo_unidad" "text", "p_cantidad" integer, "p_pcs" integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."crear_guia_remision_v1"("p_request_id" "uuid", "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint DEFAULT NULL::bigint, "p_transferencia_id" bigint DEFAULT NULL::bigint, "p_guia_remitente_id" "uuid" DEFAULT NULL::"uuid", "p_documento_relacionado_tipo" "text" DEFAULT NULL::"text", "p_documento_relacionado_numero" "text" DEFAULT NULL::"text", "p_motivo_codigo" "text" DEFAULT '01'::"text", "p_motivo_descripcion" "text" DEFAULT 'VENTA'::"text", "p_modalidad_transporte" "text" DEFAULT '02'::"text", "p_fecha_emision" timestamp with time zone DEFAULT "now"(), "p_fecha_traslado" timestamp with time zone DEFAULT "now"(), "p_destinatario" "jsonb" DEFAULT '{}'::"jsonb", "p_remitente" "jsonb" DEFAULT '{}'::"jsonb", "p_partida" "jsonb" DEFAULT '{}'::"jsonb", "p_llegada" "jsonb" DEFAULT '{}'::"jsonb", "p_transportista_id" bigint DEFAULT NULL::bigint, "p_conductor_id" bigint DEFAULT NULL::bigint, "p_vehiculo_id" bigint DEFAULT NULL::bigint, "p_peso_total" numeric DEFAULT NULL::numeric, "p_peso_editado" boolean DEFAULT false, "p_observacion" "text" DEFAULT NULL::"text", "p_detalles" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
DECLARE
  v_tipo_guia text := lower(trim(COALESCE(p_tipo_guia, '')));
  v_origen_tipo text := lower(trim(COALESCE(p_origen_tipo, 'manual')));
  v_tipo_doc text;
  v_tipo_serie text;
  v_serie text;
  v_correlativo bigint;
  v_guia_id uuid;
  v_previo record;
  v_transportista record;
  v_conductor record;
  v_vehiculo record;
  v_detalle jsonb;
  v_dest_tipo text;
  v_dest_num text;
  v_dest_nombre text;
  v_dest_dir text;
  v_dest_ubigeo text;
  v_partida_dir text;
  v_partida_ubigeo text;
  v_llegada_dir text;
  v_llegada_ubigeo text;
  v_rem_tipo text;
  v_rem_num text;
  v_rem_nombre text;
  v_peso numeric;
  v_gre_transportista_habilitada boolean := false;
BEGIN
  IF auth.uid() IS NULL OR NOT public._gre_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado: empleado no autenticado o inactivo.';
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'request_id es obligatorio.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));

  SELECT id, estado, serie, correlativo
  INTO v_previo
  FROM public.guias_remision
  WHERE request_id = p_request_id;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'success', true,
      'idempotent', true,
      'guia_id', v_previo.id,
      'estado', v_previo.estado,
      'serie', v_previo.serie,
      'correlativo', v_previo.correlativo
    );
  END IF;

  IF v_tipo_guia NOT IN ('remitente','transportista') THEN
    RAISE EXCEPTION 'Tipo de guía inválido.';
  END IF;

  IF v_origen_tipo NOT IN ('manual','venta','traslado') THEN
    RAISE EXCEPTION 'Origen de guía inválido.';
  END IF;

  IF p_modalidad_transporte NOT IN ('01','02') THEN
    RAISE EXCEPTION 'Modalidad inválida. Use 01 público o 02 privado.';
  END IF;

  IF v_tipo_guia = 'transportista'
     AND p_modalidad_transporte <> '01' THEN
    RAISE EXCEPTION
      'La GRE Transportista utiliza la modalidad de transporte público.';
  END IF;

  IF p_motivo_codigo NOT IN ('01','02','04','08','09','13','14','18','19') THEN
    RAISE EXCEPTION 'Motivo de traslado no permitido.';
  END IF;

  IF jsonb_typeof(p_detalles) <> 'array'
     OR jsonb_array_length(p_detalles) = 0 THEN
    RAISE EXCEPTION 'La guía debe contener al menos un producto.';
  END IF;

  v_dest_tipo := NULLIF(trim(p_destinatario->>'tipo_documento'), '');
  v_dest_num := NULLIF(trim(p_destinatario->>'numero_documento'), '');
  v_dest_nombre := NULLIF(trim(p_destinatario->>'razon_social'), '');
  v_dest_dir := NULLIF(trim(p_destinatario->>'direccion'), '');
  v_dest_ubigeo := NULLIF(trim(p_destinatario->>'ubigeo'), '');

  v_partida_dir := NULLIF(trim(p_partida->>'direccion'), '');
  v_partida_ubigeo := NULLIF(trim(p_partida->>'ubigeo'), '');
  v_llegada_dir := NULLIF(trim(p_llegada->>'direccion'), '');
  v_llegada_ubigeo := NULLIF(trim(p_llegada->>'ubigeo'), '');

  IF v_dest_tipo IS NULL OR v_dest_num IS NULL OR v_dest_nombre IS NULL THEN
    RAISE EXCEPTION 'Documento y nombre del destinatario son obligatorios.';
  END IF;

  IF v_partida_dir IS NULL OR v_partida_ubigeo !~ '^[0-9]{6}$' THEN
    RAISE EXCEPTION 'La dirección y el ubigeo de partida son obligatorios.';
  END IF;

  IF v_llegada_dir IS NULL OR v_llegada_ubigeo !~ '^[0-9]{6}$' THEN
    RAISE EXCEPTION 'La dirección y el ubigeo de llegada son obligatorios.';
  END IF;

  v_peso := COALESCE(p_peso_total, 0);
  IF v_peso <= 0 THEN
    RAISE EXCEPTION 'El peso total debe ser mayor a cero.';
  END IF;

  SELECT COALESCE(gre_transportista_habilitada, false)
  INTO v_gre_transportista_habilitada
  FROM public.configuracion_negocio
  ORDER BY id
  LIMIT 1;

  IF v_tipo_guia = 'transportista'
     AND NOT v_gre_transportista_habilitada THEN
    RAISE EXCEPTION
      'La GRE Transportista está deshabilitada. Actívela solo si la empresa actúa legalmente como transportista.';
  END IF;

  IF p_conductor_id IS NULL OR p_vehiculo_id IS NULL THEN
    RAISE EXCEPTION 'Conductor y vehículo son obligatorios.';
  END IF;

  SELECT * INTO v_conductor
  FROM public.gre_conductores
  WHERE id = p_conductor_id AND activo = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Conductor no encontrado o inactivo.';
  END IF;

  SELECT * INTO v_vehiculo
  FROM public.gre_vehiculos
  WHERE id = p_vehiculo_id AND activo = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Vehículo no encontrado o inactivo.';
  END IF;

  -- En una GRE Remitente con transporte público se identifica a la
  -- empresa transportista contratada. En una GRE Transportista, la propia
  -- empresa emisora es el transportista y no se exige un catálogo externo.
  IF p_modalidad_transporte = '01' AND v_tipo_guia = 'remitente' THEN
    IF p_transportista_id IS NULL THEN
      RAISE EXCEPTION 'En transporte público debes seleccionar transportista.';
    END IF;

    SELECT * INTO v_transportista
    FROM public.gre_transportistas
    WHERE id = p_transportista_id AND activo = true;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Transportista no encontrado o inactivo.';
    END IF;

    IF v_vehiculo.transportista_id IS NOT NULL
       AND v_vehiculo.transportista_id <> p_transportista_id THEN
      RAISE EXCEPTION
        'El vehículo seleccionado pertenece a otro transportista.';
    END IF;
  END IF;

  IF v_tipo_guia = 'transportista' THEN
    v_rem_tipo := NULLIF(trim(p_remitente->>'tipo_documento'), '');
    v_rem_num := NULLIF(trim(p_remitente->>'numero_documento'), '');
    v_rem_nombre := NULLIF(trim(p_remitente->>'razon_social'), '');

    IF v_rem_tipo IS NULL OR v_rem_num IS NULL OR v_rem_nombre IS NULL THEN
      RAISE EXCEPTION 'La GRE Transportista requiere los datos del remitente.';
    END IF;

    IF NULLIF(trim(COALESCE(p_documento_relacionado_numero, '')), '') IS NULL THEN
      RAISE EXCEPTION 'La GRE Transportista requiere una GRE Remitente relacionada.';
    END IF;

    v_tipo_doc := '31';
    v_tipo_serie := 'guia_transportista';
  ELSE
    v_tipo_doc := '09';
    v_tipo_serie := 'guia_remitente';
  END IF;

  SELECT serie, ultimo_correlativo + 1
  INTO v_serie, v_correlativo
  FROM public.series_comprobantes
  WHERE tipo_documento_sunat = v_tipo_serie
    AND activo = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'No existe una serie activa para %.', v_tipo_serie;
  END IF;

  UPDATE public.series_comprobantes
  SET ultimo_correlativo = v_correlativo,
      updated_at = now()
  WHERE tipo_documento_sunat = v_tipo_serie
    AND serie = v_serie;

  INSERT INTO public.guias_remision(
    request_id,
    tipo_guia,
    tipo_documento_sunat,
    serie,
    correlativo,
    estado,
    origen_tipo,
    venta_id,
    transferencia_id,
    comprobante_id,
    guia_remitente_id,
    documento_relacionado_tipo,
    documento_relacionado_numero,
    motivo_codigo,
    motivo_descripcion,
    modalidad_transporte,
    fecha_emision,
    fecha_traslado,
    destinatario_tipo_documento,
    destinatario_numero_documento,
    destinatario_razon_social,
    destinatario_direccion,
    destinatario_ubigeo,
    remitente_tipo_documento,
    remitente_numero_documento,
    remitente_razon_social,
    partida_direccion,
    partida_ubigeo,
    llegada_direccion,
    llegada_ubigeo,
    peso_total,
    peso_editado,
    transportista_id,
    conductor_id,
    vehiculo_id,
    transportista_ruc_snapshot,
    transportista_razon_social_snapshot,
    transportista_registro_mtc_snapshot,
    conductor_tipo_documento_snapshot,
    conductor_documento_snapshot,
    conductor_nombres_snapshot,
    conductor_licencia_snapshot,
    vehiculo_placa_snapshot,
    vehiculo_marca_snapshot,
    vehiculo_modelo_snapshot,
    observacion,
    creado_por
  )
  VALUES (
    p_request_id,
    v_tipo_guia,
    v_tipo_doc,
    v_serie,
    v_correlativo,
    'pendiente_envio',
    v_origen_tipo,
    p_venta_id,
    p_transferencia_id,
    CASE
      WHEN p_venta_id IS NULL THEN NULL
      ELSE (
        SELECT ce.id
        FROM public.comprobantes_electronicos AS ce
        WHERE ce.venta_id = p_venta_id
          AND ce.estado = 'aceptado'
        ORDER BY ce.created_at DESC
        LIMIT 1
      )
    END,
    p_guia_remitente_id,
    NULLIF(trim(COALESCE(p_documento_relacionado_tipo, '')), ''),
    NULLIF(trim(COALESCE(p_documento_relacionado_numero, '')), ''),
    p_motivo_codigo,
    trim(COALESCE(p_motivo_descripcion, '')),
    p_modalidad_transporte,
    COALESCE(p_fecha_emision, now()),
    p_fecha_traslado,
    v_dest_tipo,
    v_dest_num,
    v_dest_nombre,
    COALESCE(v_dest_dir, v_llegada_dir),
    COALESCE(v_dest_ubigeo, v_llegada_ubigeo),
    v_rem_tipo,
    v_rem_num,
    v_rem_nombre,
    v_partida_dir,
    v_partida_ubigeo,
    v_llegada_dir,
    v_llegada_ubigeo,
    v_peso,
    COALESCE(p_peso_editado, false),
    p_transportista_id,
    p_conductor_id,
    p_vehiculo_id,
    COALESCE(
      (
        SELECT gt.ruc
        FROM public.gre_transportistas AS gt
        WHERE gt.id = p_transportista_id
      ),
      (
        SELECT cn.ruc
        FROM public.configuracion_negocio AS cn
        ORDER BY cn.id
        LIMIT 1
      )
    ),
    COALESCE(
      (
        SELECT gt.razon_social
        FROM public.gre_transportistas AS gt
        WHERE gt.id = p_transportista_id
      ),
      (
        SELECT COALESCE(cn.razon_social, cn.nombre_comercial)
        FROM public.configuracion_negocio AS cn
        ORDER BY cn.id
        LIMIT 1
      )
    ),
    (
      SELECT gt.registro_mtc
      FROM public.gre_transportistas AS gt
      WHERE gt.id = p_transportista_id
    ),
    v_conductor.tipo_documento,
    v_conductor.numero_documento,
    v_conductor.nombres,
    v_conductor.numero_licencia,
    upper(trim(v_vehiculo.placa)),
    v_vehiculo.marca,
    v_vehiculo.modelo,
    NULLIF(trim(COALESCE(p_observacion, '')), ''),
    auth.uid()
  )
  RETURNING id INTO v_guia_id;

  FOR v_detalle IN
    SELECT value
    FROM jsonb_array_elements(p_detalles)
  LOOP
    IF COALESCE((v_detalle->>'cantidad')::numeric, 0) <= 0 THEN
      RAISE EXCEPTION 'Todas las cantidades deben ser mayores a cero.';
    END IF;

    IF NULLIF(trim(v_detalle->>'descripcion'), '') IS NULL THEN
      RAISE EXCEPTION 'Cada línea debe tener descripción.';
    END IF;

    INSERT INTO public.guias_remision_detalles(
      guia_id,
      producto_id,
      detalle_venta_id,
      transferencia_id,
      almacen_id,
      codigo,
      descripcion,
      unidad,
      cantidad,
      piezas_reales,
      peso_unitario_kg,
      peso_total_kg
    )
    VALUES (
      v_guia_id,
      NULLIF(v_detalle->>'producto_id', '')::bigint,
      NULLIF(v_detalle->>'detalle_venta_id', '')::bigint,
      NULLIF(v_detalle->>'transferencia_id', '')::bigint,
      NULLIF(v_detalle->>'almacen_id', '')::bigint,
      NULLIF(trim(v_detalle->>'codigo'), ''),
      trim(v_detalle->>'descripcion'),
      upper(COALESCE(NULLIF(trim(v_detalle->>'unidad'), ''), 'NIU')),
      (v_detalle->>'cantidad')::numeric,
      NULLIF(v_detalle->>'piezas_reales', '')::integer,
      COALESCE(NULLIF(v_detalle->>'peso_unitario_kg', '')::numeric, 0),
      COALESCE(NULLIF(v_detalle->>'peso_total_kg', '')::numeric, 0)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'guia_id', v_guia_id,
    'estado', 'pendiente_envio',
    'tipo_documento_sunat', v_tipo_doc,
    'serie', v_serie,
    'correlativo', v_correlativo,
    'stock_modificado', false
  );
END;
$_$;
ALTER FUNCTION "public"."crear_guia_remision_v1"("p_request_id" "uuid", "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."crear_nota_credito_v1"("p_request_id" "uuid", "p_comprobante_id" "uuid", "p_motivo_codigo" "text", "p_motivo_descripcion" "text" DEFAULT NULL::"text", "p_detalles" "jsonb" DEFAULT '[]'::"jsonb", "p_monto_descuento" numeric DEFAULT NULL::numeric, "p_reponer_stock" boolean DEFAULT true, "p_fecha" timestamp with time zone DEFAULT "now"()) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."crear_nota_credito_v1"("p_request_id" "uuid", "p_comprobante_id" "uuid", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_detalles" "jsonb", "p_monto_descuento" numeric, "p_reponer_stock" boolean, "p_fecha" timestamp with time zone) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."crear_producto_con_stock"("p_request_id" "uuid", "p_datos_producto" "jsonb", "p_stocks" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
DECLARE
    v_producto_id BIGINT;
    v_stock JSONB;

    v_almacen_id BIGINT;
    v_delta INT;
    v_motivo TEXT;
    v_tipo_movimiento TEXT;

    v_ingreso_costo NUMERIC;
    v_ingreso_p_unit NUMERIC;
    v_ingreso_p_caja NUMERIC;
    v_ingreso_p_c_comp NUMERIC;

    v_unidad_label TEXT;
    v_unidad_medida TEXT;

    v_tipo_venta TEXT;
    v_codigo TEXT;
    v_nombre TEXT;

    v_proveedor_id BIGINT;
    v_stock_minimo INT;
    v_almacenes_procesados BIGINT[] := '{}';

    v_resultado_previo JSONB;
BEGIN
    -- =========================================================================
    -- A. AUTENTICACIÓN Y AUTORIZACIÓN
    -- =========================================================================

    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION
            'Acceso denegado: usuario no autenticado.';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.empleados AS e
        WHERE e.auth_id = auth.uid()
          AND COALESCE(e.activo, false) = true
          AND LOWER(COALESCE(e.rol, '')) IN ('admin')
    ) THEN
        RAISE EXCEPTION
            'Solo el administrador puede crear productos.';
    END IF;

    -- =========================================================================
    -- B. VALIDACIÓN DE PARÁMETROS
    -- =========================================================================

    IF p_request_id IS NULL THEN
        RAISE EXCEPTION
            'El request_id es obligatorio para idempotencia.';
    END IF;

    IF p_datos_producto IS NULL
       OR jsonb_typeof(p_datos_producto) <> 'object' THEN
        RAISE EXCEPTION
            'p_datos_producto debe ser un objeto JSON válido.';
    END IF;

    IF p_stocks IS NULL
       OR jsonb_typeof(p_stocks) <> 'array' THEN
        RAISE EXCEPTION
            'p_stocks debe ser un arreglo JSON válido.';
    END IF;

    -- Serializa dos reintentos simultáneos con el mismo UUID.
    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_request_id::text, 0)
    );

    -- =========================================================================
    -- C. IDEMPOTENCIA
    -- =========================================================================

    SELECT spr.resultado
    INTO v_resultado_previo
    FROM public.sys_processed_requests AS spr
    WHERE spr.request_id = p_request_id
    LIMIT 1;

    IF FOUND THEN
        RETURN v_resultado_previo;
    END IF;

    -- =========================================================================
    -- D. NORMALIZACIÓN Y VALIDACIÓN DEL PRODUCTO
    -- =========================================================================

    v_codigo := UPPER(TRIM(COALESCE(p_datos_producto->>'codigo', '')));
    v_nombre := TRIM(COALESCE(p_datos_producto->>'nombre', ''));
    v_tipo_venta :=
        UPPER(TRIM(COALESCE(p_datos_producto->>'tipo_venta', '')));

    v_stock_minimo := COALESCE(
        NULLIF(p_datos_producto->>'stock_minimo', '')::INT,
        0
    );

    IF v_codigo = '' THEN
        RAISE EXCEPTION
            'El código del producto es obligatorio.';
    END IF;

    IF LENGTH(v_codigo) > 50 THEN
        RAISE EXCEPTION
            'El código del producto no puede superar 50 caracteres.';
    END IF;

    IF v_codigo !~ '^[A-Z0-9._/-]+$' THEN
        RAISE EXCEPTION
            'El código solo puede contener letras, números, punto, guion, barra o guion bajo.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.productos AS p
        WHERE UPPER(TRIM(p.codigo)) = v_codigo
    ) THEN
        RAISE EXCEPTION
            'Ya existe un producto con el código %.',
            v_codigo;
    END IF;

    IF v_nombre = '' THEN
        RAISE EXCEPTION
            'El nombre del producto no puede estar vacío.';
    END IF;

    IF v_tipo_venta NOT IN (
        'PAQUETES',
        'CAJA_PAQUETES',
        'CAJA_UNIDADES'
    ) THEN
        RAISE EXCEPTION
            'tipo_venta inválido. Debe ser PAQUETES, CAJA_PAQUETES o CAJA_UNIDADES.';
    END IF;

    IF COALESCE(
           NULLIF(p_datos_producto->>'precio_unidad', '')::NUMERIC,
           0
       ) < 0
       OR COALESCE(
           NULLIF(p_datos_producto->>'precio_caja', '')::NUMERIC,
           0
       ) < 0
       OR COALESCE(
           NULLIF(p_datos_producto->>'precio_compra', '')::NUMERIC,
           0
       ) < 0 THEN
        RAISE EXCEPTION
            'Los precios y costos no pueden ser negativos.';
    END IF;

    -- AQUÍ ESTÁ EL CAMBIO PRINCIPAL: Ahora es < 1 (permite 1)
    IF COALESCE(
           NULLIF(p_datos_producto->>'cantidad_por_caja', '')::INT,
           0
       ) < 1 THEN
        RAISE EXCEPTION
            'La cantidad contenida en el empaque debe ser al menos 1.';
    END IF;

    IF v_stock_minimo < 0 THEN
        RAISE EXCEPTION
            'El stock mínimo no puede ser negativo.';
    END IF;

    v_proveedor_id :=
        NULLIF(p_datos_producto->>'proveedor_id', '')::BIGINT;

    -- Unidad base que se almacena en inventario_almacen.
    IF v_tipo_venta IN ('PAQUETES', 'CAJA_PAQUETES') THEN
        v_unidad_medida := 'Paquetes';
        v_unidad_label := 'Paquete';
    ELSE
        v_unidad_medida := 'Unidades';
        v_unidad_label := 'Unidad';
    END IF;

    -- =========================================================================
    -- E. INSERTAR PRODUCTO
    -- =========================================================================

    INSERT INTO public.productos (
        codigo,
        nombre,
        precio_unidad,
        precio_caja,
        precio_compra,
        imagen_path,
        unidad_medida,
        cantidad_por_caja,
        proveedor_id,
        permitir_sin_stock,
        tipo_venta,
        stock_minimo
    )
    VALUES (
        v_codigo,
        v_nombre,
        COALESCE(
            NULLIF(p_datos_producto->>'precio_unidad', '')::NUMERIC,
            0
        ),
        COALESCE(
            NULLIF(p_datos_producto->>'precio_caja', '')::NUMERIC,
            0
        ),
        COALESCE(
            NULLIF(p_datos_producto->>'precio_compra', '')::NUMERIC,
            0
        ),
        NULLIF(TRIM(COALESCE(p_datos_producto->>'imagen_path', '')), ''),
        v_unidad_medida,
        (p_datos_producto->>'cantidad_por_caja')::INT,
        v_proveedor_id,
        COALESCE(
            NULLIF(p_datos_producto->>'permitir_sin_stock', '')::BOOLEAN,
            false
        ),
        v_tipo_venta,
        v_stock_minimo
    )
    RETURNING id
    INTO v_producto_id;

    -- =========================================================================
    -- F. STOCK INICIAL Y KARDEX
    -- =========================================================================

    FOR v_stock IN
        SELECT value
        FROM jsonb_array_elements(p_stocks)
    LOOP
        IF jsonb_typeof(v_stock) <> 'object' THEN
            RAISE EXCEPTION
                'Cada elemento de p_stocks debe ser un objeto JSON.';
        END IF;

        v_almacen_id :=
            NULLIF(v_stock->>'almacen_id', '')::BIGINT;

        v_delta :=
            COALESCE(
                NULLIF(v_stock->>'delta', '')::INT,
                0
            );

        v_motivo :=
            COALESCE(
                NULLIF(TRIM(v_stock->>'motivo'), ''),
                'Apertura de Inventario / Stock Inicial'
            );

        v_tipo_movimiento :=
            UPPER(
                COALESCE(
                    NULLIF(TRIM(v_stock->>'tipo_movimiento'), ''),
                    'ENTRADA'
                )
            );

        v_ingreso_costo :=
            COALESCE(
                NULLIF(v_stock->>'ingreso_costo', '')::NUMERIC,
                0
            );

        v_ingreso_p_unit :=
            COALESCE(
                NULLIF(v_stock->>'ingreso_p_unit', '')::NUMERIC,
                0
            );

        v_ingreso_p_caja :=
            NULLIF(v_stock->>'ingreso_p_caja', '')::NUMERIC;

        v_ingreso_p_c_comp :=
            NULLIF(v_stock->>'ingreso_p_c_comp', '')::NUMERIC;

        IF v_almacen_id IS NULL THEN
            RAISE EXCEPTION
                'El almacen_id es obligatorio.';
        END IF;

        IF v_delta < 0 THEN
            RAISE EXCEPTION
                'El stock inicial no puede ser negativo.';
        END IF;

        IF v_tipo_movimiento <> 'ENTRADA' THEN
            RAISE EXCEPTION
                'El movimiento inicial debe ser ENTRADA.';
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

        IF v_almacen_id = ANY(v_almacenes_procesados) THEN
            RAISE EXCEPTION
                'El almacén % está duplicado en el arreglo de stocks.',
                v_almacen_id;
        END IF;

        v_almacenes_procesados :=
            array_append(v_almacenes_procesados, v_almacen_id);

        IF v_delta > 0 THEN
            PERFORM public.ajustar_stock_y_kardex(
                p_producto_id := v_producto_id,
                p_almacen_id := v_almacen_id,
                p_delta := v_delta,
                p_tipo_movimiento := 'ENTRADA',
                p_motivo := v_motivo,
                p_ingreso_costo := v_ingreso_costo,
                p_ingreso_p_unit := v_ingreso_p_unit,
                p_ingreso_p_caja := v_ingreso_p_caja,
                p_ingreso_p_c_comp := v_ingreso_p_c_comp,
                p_salida_cliente := NULL,
                p_salida_p_unit := 0,
                p_salida_total := 0,
                p_unidad_label := v_unidad_label
            );
        END IF;
    END LOOP;

    -- =========================================================================
    -- G. RESULTADO E IDEMPOTENCIA
    -- =========================================================================

    v_resultado_previo := jsonb_build_object(
        'success', true,
        'producto_id', v_producto_id,
        'codigo', v_codigo,
        'tipo_venta', v_tipo_venta,
        'mensaje', 'Producto y stock creados con éxito'
    );

    INSERT INTO public.sys_processed_requests (
        request_id,
        producto_id,
        resultado
    )
    VALUES (
        p_request_id,
        v_producto_id,
        v_resultado_previo
    );

    RETURN v_resultado_previo;
END;
$_$;
ALTER FUNCTION "public"."crear_producto_con_stock"("p_request_id" "uuid", "p_datos_producto" "jsonb", "p_stocks" "jsonb") OWNER TO "postgres";
COMMENT ON FUNCTION "public"."crear_producto_con_stock"("p_request_id" "uuid", "p_datos_producto" "jsonb", "p_stocks" "jsonb") IS 'Crea un producto con stock inicial de forma transaccional e idempotente; incluye stock_minimo.';
CREATE OR REPLACE FUNCTION "public"."desactivar_almacen_seguro_v1"("p_almacen_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_almacen public.almacenes%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.empleados AS e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND LOWER(COALESCE(e.rol, '')) = 'admin'
  ) THEN
    RAISE EXCEPTION 'Solo un administrador activo puede desactivar almacenes';
  END IF;

  SELECT * INTO v_almacen
  FROM public.almacenes
  WHERE id = p_almacen_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Almacen no encontrado';
  END IF;

  IF COALESCE(v_almacen.activo, false) = false THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true, 'almacen_id', p_almacen_id, 'activo', false);
  END IF;

  UPDATE public.almacenes
  SET activo = false, updated_at = now()
  WHERE id = p_almacen_id;

  RETURN jsonb_build_object('success', true, 'idempotent', false, 'almacen_id', p_almacen_id, 'activo', false);
END;
$$;
ALTER FUNCTION "public"."desactivar_almacen_seguro_v1"("p_almacen_id" bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."eliminar_borrador_guia_v1"("p_guia_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_guia public.guias_remision%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND e.rol IN ('admin', 'operador')
  ) THEN
    RAISE EXCEPTION 'Empleado inactivo o rol no autorizado';
  END IF;

  SELECT *
  INTO v_guia
  FROM public.guias_remision
  WHERE id = p_guia_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Guía no encontrada';
  END IF;

  IF v_guia.estado <> 'borrador' THEN
    RAISE EXCEPTION 'Solo se pueden eliminar guías en estado borrador';
  END IF;

  IF v_guia.ticket_sunat IS NOT NULL
     OR v_guia.enviado_at IS NOT NULL THEN
    RAISE EXCEPTION 'La guía tiene información de envío y no puede eliminarse';
  END IF;

  DELETE FROM public.guias_remision_detalles
  WHERE guia_id = p_guia_id;

  DELETE FROM public.guias_remision
  WHERE id = p_guia_id;

  RETURN jsonb_build_object(
    'success', true,
    'guia_id', p_guia_id
  );
END;
$$;
ALTER FUNCTION "public"."eliminar_borrador_guia_v1"("p_guia_id" "uuid") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."eliminar_cotizacion_v2"("p_cotizacion_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."eliminar_cotizacion_v2"("p_cotizacion_id" bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."eliminar_gasto_v1"("p_gasto_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_gasto public.gastos%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado: empleado no autenticado o inactivo.';
  END IF;

  IF p_gasto_id IS NULL THEN
    RAISE EXCEPTION 'El gasto es obligatorio.';
  END IF;

  SELECT g.* INTO v_gasto
  FROM public.gastos AS g
  WHERE g.id = p_gasto_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Gasto no encontrado.';
  END IF;

  DELETE FROM public.gastos WHERE id = p_gasto_id;

  RETURN jsonb_build_object('success', true, 'gasto_id', p_gasto_id);
END;
$$;
ALTER FUNCTION "public"."eliminar_gasto_v1"("p_gasto_id" bigint) OWNER TO "postgres";
COMMENT ON FUNCTION "public"."eliminar_gasto_v1"("p_gasto_id" bigint) IS 'Elimina gasto y pagos asociados en una sola transaccion. Fase 5.';
CREATE OR REPLACE FUNCTION "public"."eliminar_pago_gasto_v1"("p_pago_id" bigint, "p_gasto_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_gasto public.gastos%ROWTYPE;
  v_pago public.pagos_gasto%ROWTYPE;
  v_total_pagado numeric := 0;
  v_nuevo_saldo numeric := 0;
  v_estado text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado: empleado no autenticado o inactivo.';
  END IF;

  IF p_pago_id IS NULL OR p_gasto_id IS NULL THEN
    RAISE EXCEPTION 'Pago y gasto son obligatorios.';
  END IF;

  SELECT g.* INTO v_gasto
  FROM public.gastos AS g
  WHERE g.id = p_gasto_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Gasto no encontrado.';
  END IF;

  SELECT pg.* INTO v_pago
  FROM public.pagos_gasto AS pg
  WHERE pg.id = p_pago_id
    AND pg.gasto_id = p_gasto_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pago no encontrado para el gasto indicado.';
  END IF;

  DELETE FROM public.pagos_gasto WHERE id = v_pago.id;

  SELECT COALESCE(SUM(pg.monto), 0)
  INTO v_total_pagado
  FROM public.pagos_gasto AS pg
  WHERE pg.gasto_id = p_gasto_id;

  v_nuevo_saldo := GREATEST(v_gasto.monto - v_total_pagado, 0);
  v_estado := CASE WHEN v_nuevo_saldo <= 0.02 THEN 'pagado' ELSE 'pendiente' END;

  UPDATE public.gastos
  SET saldo = v_nuevo_saldo,
      estado = v_estado
  WHERE id = p_gasto_id;

  RETURN jsonb_build_object(
    'success', true,
    'gasto_id', p_gasto_id,
    'pago_id', p_pago_id,
    'saldo', v_nuevo_saldo,
    'estado', v_estado
  );
END;
$$;
ALTER FUNCTION "public"."eliminar_pago_gasto_v1"("p_pago_id" bigint, "p_gasto_id" bigint) OWNER TO "postgres";
COMMENT ON FUNCTION "public"."eliminar_pago_gasto_v1"("p_pago_id" bigint, "p_gasto_id" bigint) IS 'Elimina un pago de gasto y recalcula saldo/estado atomicamente. Fase 5.';
CREATE OR REPLACE FUNCTION "public"."eliminar_pago_venta_v1"("p_pago_id" bigint, "p_venta_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."eliminar_pago_venta_v1"("p_pago_id" bigint, "p_venta_id" bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."eliminar_producto_seguro_v1"("p_producto_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_producto public.productos%ROWTYPE;
  v_evaluacion jsonb;
  v_motivos text;
  v_movimientos_eliminados bigint := 0;
  v_stock_eliminado bigint := 0;
  v_requests_eliminados bigint := 0;
BEGIN
  IF NOT public.app_es_admin() THEN
    RAISE EXCEPTION 'Solo el administrador puede eliminar productos.';
  END IF;

  IF p_producto_id IS NULL THEN
    RAISE EXCEPTION 'El producto_id es obligatorio.';
  END IF;

  PERFORM pg_advisory_xact_lock(p_producto_id);

  SELECT *
  INTO v_producto
  FROM public.productos
  WHERE id = p_producto_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El producto % no existe.', p_producto_id;
  END IF;

  v_evaluacion :=
    public.evaluar_eliminacion_producto_v1(p_producto_id);

  IF COALESCE((v_evaluacion->>'puede_eliminar')::boolean, false) = false THEN
    SELECT string_agg(elemento->>'mensaje', ' ')
    INTO v_motivos
    FROM jsonb_array_elements(
      COALESCE(v_evaluacion->'bloqueos', '[]'::jsonb)
    ) AS elemento;

    RAISE EXCEPTION
      'El producto no puede eliminarse definitivamente. %',
      COALESCE(v_motivos, 'Solo puede desactivarse.');
  END IF;

  DELETE FROM public.sys_processed_requests
  WHERE producto_id = p_producto_id;
  GET DIAGNOSTICS v_requests_eliminados = ROW_COUNT;

  DELETE FROM public.inventario_movimientos AS m
  WHERE m.producto_id = p_producto_id
    AND UPPER(TRIM(COALESCE(m.tipo, ''))) IN ('ENTRADA', 'INGRESO')
    AND UPPER(
      REGEXP_REPLACE(
        TRIM(COALESCE(m.observaciones, '')),
        '\s+',
        ' ',
        'g'
      )
    ) IN (
      'APERTURA DE INVENTARIO / STOCK INICIAL',
      'APERTURA DE INVENTARIO',
      'STOCK INICIAL'
    )
    AND m.venta_id IS NULL
    AND COALESCE(m.salida_cant, 0) = 0;
  GET DIAGNOSTICS v_movimientos_eliminados = ROW_COUNT;

  DELETE FROM public.inventario_almacen
  WHERE producto_id = p_producto_id;
  GET DIAGNOSTICS v_stock_eliminado = ROW_COUNT;

  DELETE FROM public.productos
  WHERE id = p_producto_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'El producto cambió durante la operación y no pudo eliminarse.';
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'producto_id', p_producto_id,
    'producto_nombre', v_producto.nombre,
    'imagen_path', v_producto.imagen_path,
    'movimientos_apertura_eliminados', v_movimientos_eliminados,
    'filas_stock_eliminadas', v_stock_eliminado,
    'requests_idempotencia_eliminados', v_requests_eliminados,
    'mensaje', 'Producto eliminado definitivamente.'
  );
END;
$$;
ALTER FUNCTION "public"."eliminar_producto_seguro_v1"("p_producto_id" bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."evaluar_eliminacion_producto_v1"("p_producto_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
DECLARE
  v_producto public.productos%ROWTYPE;
  v_movimientos_total bigint := 0;
  v_movimientos_apertura bigint := 0;
  v_movimientos_operativos bigint := 0;
  v_stock_total bigint := 0;
  v_filas_stock bigint := 0;
  v_bloqueos jsonb := '[]'::jsonb;
  v_cantidad bigint;
  v_mensaje text;
  v_puede_eliminar boolean;
  r record;
BEGIN
  IF NOT public.app_es_admin() THEN
    RAISE EXCEPTION 'Solo el administrador puede evaluar la eliminación de productos.';
  END IF;

  IF p_producto_id IS NULL THEN
    RAISE EXCEPTION 'El producto_id es obligatorio.';
  END IF;

  SELECT *
  INTO v_producto
  FROM public.productos
  WHERE id = p_producto_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El producto % no existe.', p_producto_id;
  END IF;

  SELECT
    COUNT(*),
    COUNT(*) FILTER (
      WHERE UPPER(TRIM(COALESCE(m.tipo, ''))) IN ('ENTRADA', 'INGRESO')
        AND UPPER(
          REGEXP_REPLACE(
            TRIM(COALESCE(m.observaciones, '')),
            '\s+',
            ' ',
            'g'
          )
        ) IN (
          'APERTURA DE INVENTARIO / STOCK INICIAL',
          'APERTURA DE INVENTARIO',
          'STOCK INICIAL'
        )
        AND m.venta_id IS NULL
        AND COALESCE(m.salida_cant, 0) = 0
    )
  INTO v_movimientos_total, v_movimientos_apertura
  FROM public.inventario_movimientos AS m
  WHERE m.producto_id = p_producto_id;

  v_movimientos_operativos :=
    v_movimientos_total - v_movimientos_apertura;

  SELECT
    COUNT(*),
    COALESCE(SUM(COALESCE(ia.cantidad, 0)), 0)
  INTO v_filas_stock, v_stock_total
  FROM public.inventario_almacen AS ia
  WHERE ia.producto_id = p_producto_id;

  IF v_movimientos_operativos > 0 THEN
    v_bloqueos := v_bloqueos || jsonb_build_array(
      jsonb_build_object(
        'tabla', 'inventario_movimientos',
        'cantidad', v_movimientos_operativos,
        'mensaje',
          CASE
            WHEN v_movimientos_operativos = 1
              THEN 'Tiene 1 movimiento operativo de inventario.'
            ELSE format(
              'Tiene %s movimientos operativos de inventario.',
              v_movimientos_operativos
            )
          END
      )
    );
  END IF;

  -- Revisa automáticamente cualquier tabla pública real que contenga
  -- `producto_id`. Se excluyen únicamente las tablas que la eliminación
  -- segura limpia dentro de su propia transacción.
  FOR r IN
    WITH referencias AS (
      -- Columnas convencionales, incluso si no tienen FK.
      SELECT
        c.table_name,
        c.column_name
      FROM information_schema.columns AS c
      JOIN information_schema.tables AS t
        ON t.table_schema = c.table_schema
       AND t.table_name = c.table_name
      WHERE c.table_schema = 'public'
        AND c.column_name = 'producto_id'
        AND t.table_type = 'BASE TABLE'

      UNION

      -- Cualquier FK real que apunte a productos, aunque la columna tenga
      -- otro nombre.
      SELECT
        rel.relname AS table_name,
        att.attname AS column_name
      FROM pg_constraint AS con
      JOIN pg_class AS rel
        ON rel.oid = con.conrelid
      JOIN pg_namespace AS ns
        ON ns.oid = rel.relnamespace
      JOIN LATERAL unnest(con.conkey) AS key_column(attnum)
        ON true
      JOIN pg_attribute AS att
        ON att.attrelid = con.conrelid
       AND att.attnum = key_column.attnum
      WHERE con.contype = 'f'
        AND con.confrelid = 'public.productos'::regclass
        AND ns.nspname = 'public'
    )
    SELECT DISTINCT
      ref.table_name,
      ref.column_name
    FROM referencias AS ref
    WHERE ref.table_name NOT IN (
      'inventario_almacen',
      'inventario_movimientos',
      'sys_processed_requests'
    )
    ORDER BY ref.table_name, ref.column_name
  LOOP
    EXECUTE format(
      'SELECT COUNT(*) FROM public.%I WHERE %I = $1',
      r.table_name,
      r.column_name
    )
    INTO v_cantidad
    USING p_producto_id;

    IF v_cantidad > 0 THEN
      v_mensaje := CASE r.table_name
        WHEN 'detalle_ventas'
          THEN format('Tiene %s detalle(s) de venta.', v_cantidad)
        WHEN 'detalle_cotizaciones'
          THEN format('Tiene %s detalle(s) de cotización.', v_cantidad)
        WHEN 'guias_remision_detalles'
          THEN format('Tiene %s detalle(s) de guía de remisión.', v_cantidad)
        WHEN 'notas_credito_detalles'
          THEN format('Tiene %s detalle(s) de nota de crédito.', v_cantidad)
        WHEN 'transferencias_stock'
          THEN format('Tiene %s traslado(s) de stock.', v_cantidad)
        WHEN 'inventario_operaciones_idempotentes'
          THEN format(
            'Tiene %s operación(es) de inventario registrada(s).',
            v_cantidad
          )
        ELSE format(
          'Tiene %s referencia(s) en la tabla %s.',
          v_cantidad,
          r.table_name
        )
      END;

      v_bloqueos := v_bloqueos || jsonb_build_array(
        jsonb_build_object(
          'tabla', r.table_name,
          'columna', r.column_name,
          'cantidad', v_cantidad,
          'mensaje', v_mensaje
        )
      );
    END IF;
  END LOOP;

  v_puede_eliminar :=
    v_movimientos_operativos = 0
    AND jsonb_array_length(v_bloqueos) = 0;

  RETURN jsonb_build_object(
    'success', true,
    'producto_id', v_producto.id,
    'producto_nombre', v_producto.nombre,
    'producto_activo', COALESCE(v_producto.activo, true),
    'imagen_path', v_producto.imagen_path,
    'movimientos_total', v_movimientos_total,
    'movimientos_apertura', v_movimientos_apertura,
    'movimientos_operativos', v_movimientos_operativos,
    'filas_stock', v_filas_stock,
    'stock_total', v_stock_total,
    'solo_apertura',
      v_movimientos_total = v_movimientos_apertura,
    'puede_actualizar_apertura',
      v_puede_eliminar AND v_movimientos_apertura > 0,
    'puede_eliminar', v_puede_eliminar,
    'accion_permitida',
      CASE WHEN v_puede_eliminar THEN 'eliminar' ELSE 'desactivar' END,
    'bloqueos', v_bloqueos
  );
END;
$_$;
ALTER FUNCTION "public"."evaluar_eliminacion_producto_v1"("p_producto_id" bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."facturacion_claim_comprobante"("p_comprobante_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text" DEFAULT 'emitir'::"text", "p_forzar" boolean DEFAULT false, "p_sistema" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."facturacion_claim_comprobante"("p_comprobante_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text", "p_forzar" boolean, "p_sistema" boolean) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."facturacion_finalizar_comprobante"("p_comprobante_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_comp record;
  v_estado text := lower(trim(COALESCE(p_estado, '')));
  v_intento_id uuid;
  v_codigo_http integer;
  v_duracion integer;
  v_mensaje text;
BEGIN
  IF v_estado NOT IN (
    'aceptado', 'rechazado', 'pendiente_reintento',
    'resultado_incierto', 'ticket_pendiente'
  ) THEN
    RAISE EXCEPTION 'Estado final inválido: %', v_estado;
  END IF;

  SELECT * INTO v_comp
  FROM public.comprobantes_electronicos
  WHERE id = p_comprobante_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Comprobante no encontrado'; END IF;

  IF v_comp.estado = 'aceptado' AND v_estado <> 'aceptado' THEN
    RETURN jsonb_build_object('success', true, 'estado', 'aceptado',
      'idempotent', true, 'ignored_state', v_estado,
      'comprobante_id', p_comprobante_id, 'venta_id', v_comp.venta_id);
  END IF;

  IF v_comp.bloqueo_token IS DISTINCT FROM p_bloqueo_token THEN
    IF v_comp.estado = 'aceptado' AND v_estado = 'aceptado' THEN
      RETURN jsonb_build_object('success', true, 'estado', 'aceptado',
        'idempotent', true, 'comprobante_id', p_comprobante_id,
        'venta_id', v_comp.venta_id);
    END IF;
    RAISE EXCEPTION 'El bloqueo del comprobante ya no es válido';
  END IF;

  v_intento_id := NULLIF(p_resultado->>'intento_id', '')::uuid;
  v_codigo_http := NULLIF(p_resultado->>'codigo_http', '')::integer;
  v_duracion := NULLIF(p_resultado->>'duracion_ms', '')::integer;
  v_mensaje := NULLIF(trim(p_resultado->>'mensaje_error'), '');

  UPDATE public.comprobantes_electronicos
  SET estado = v_estado,
      payload_json = COALESCE(p_resultado->'payload_json', payload_json),
      respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
      xml_path = COALESCE(NULLIF(p_resultado->>'xml_path', ''), xml_path),
      cdr_path = COALESCE(NULLIF(p_resultado->>'cdr_path', ''), cdr_path),
      pdf_path = COALESCE(NULLIF(p_resultado->>'pdf_path', ''), pdf_path),
      hash_documento = COALESCE(NULLIF(p_resultado->>'hash_documento', ''), hash_documento),
      codigo_sunat = COALESCE(NULLIF(p_resultado->>'codigo_sunat', ''), codigo_sunat),
      descripcion_sunat = COALESCE(NULLIF(p_resultado->>'descripcion_sunat', ''), v_mensaje, descripcion_sunat),
      observaciones_sunat = COALESCE(p_resultado->'observaciones_sunat', observaciones_sunat),
      ticket_sunat = COALESCE(NULLIF(p_resultado->>'ticket_sunat', ''), ticket_sunat),
      archivo_nombre_base = COALESCE(NULLIF(p_resultado->>'archivo_nombre_base', ''), archivo_nombre_base),
      ultimo_error_tipo = CASE WHEN v_estado = 'aceptado' THEN NULL
        ELSE COALESCE(NULLIF(p_resultado->>'error_tipo', ''), ultimo_error_tipo) END,
      ultimo_http_status = v_codigo_http,
      enviado_at = CASE
        WHEN v_estado IN ('aceptado', 'rechazado', 'ticket_pendiente', 'resultado_incierto')
          OR COALESCE((p_resultado->>'remoto_iniciado')::boolean, false)
        THEN COALESCE(enviado_at, now()) ELSE enviado_at END,
      aceptado_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now()) ELSE aceptado_at END,
      consultado_at = CASE WHEN COALESCE((p_resultado->>'fue_consulta')::boolean, false)
        THEN now() ELSE consultado_at END,
      pdf_generado_at = CASE WHEN NULLIF(p_resultado->>'pdf_path', '') IS NOT NULL
        THEN now() ELSE pdf_generado_at END,
      procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
  WHERE id = p_comprobante_id;

  IF v_intento_id IS NOT NULL THEN
    UPDATE public.facturacion_intentos
    SET resultado = v_estado, codigo_http = v_codigo_http,
        codigo_error = NULLIF(p_resultado->>'codigo_error', ''),
        mensaje_error = v_mensaje,
        respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
        payload_json = COALESCE(p_resultado->'payload_json', payload_json),
        fecha_fin = now(),
        duracion_ms = COALESCE(v_duracion,
          GREATEST(0, floor(extract(epoch FROM (now() - fecha_inicio)) * 1000)::integer))
    WHERE id = v_intento_id;
  END IF;

  UPDATE public.ventas SET estado_facturacion = v_estado
  WHERE id = v_comp.venta_id;

  RETURN jsonb_build_object('success', true, 'estado', v_estado,
    'comprobante_id', p_comprobante_id, 'venta_id', v_comp.venta_id);
END;
$$;
ALTER FUNCTION "public"."facturacion_finalizar_comprobante"("p_comprobante_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."fn_autoclasificar_tipo_doc_cliente"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.dni_ruc := TRIM(REGEXP_REPLACE(COALESCE(NEW.dni_ruc, ''), '[^0-9]', '', 'g'));
  IF LENGTH(NEW.dni_ruc) = 11 THEN
    NEW.tipo_doc := '6';
  ELSIF LENGTH(NEW.dni_ruc) = 8 THEN
    NEW.tipo_doc := '1';
  ELSE
    NEW.tipo_doc := COALESCE(NEW.tipo_doc, '0');
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION "public"."fn_autoclasificar_tipo_doc_cliente"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."get_dashboard_summary"("inicio" timestamp with time zone, "fin" timestamp with time zone) RETURNS json
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
    v_ingresos_hoy numeric := 0;
    v_egresos_hoy numeric := 0;

    v_total_productos bigint := 0;
    v_low_stock integer := 0;
    v_out_of_stock integer := 0;

    v_por_cobrar numeric := 0;
    v_por_pagar numeric := 0;
BEGIN

    IF NOT public.app_empleado_activo() THEN
        RAISE EXCEPTION 'Empleado no autorizado';
    END IF;


    SELECT COALESCE(
        SUM(
            CASE
                WHEN tipo = 'ingreso'
                    THEN monto
                ELSE 0
            END
        ),
        0
    )
    INTO v_ingresos_hoy
    FROM public.movimientos
    WHERE fecha >= inicio
      AND fecha < fin;


    SELECT COALESCE(
        SUM(
            CASE
                WHEN tipo = 'egreso'
                    THEN monto
                ELSE 0
            END
        ),
        0
    )
    INTO v_egresos_hoy
    FROM public.movimientos
    WHERE fecha >= inicio
      AND fecha < fin;


    SELECT COUNT(*)
    INTO v_total_productos
    FROM public.productos
    WHERE COALESCE(activo, true) = true;


    SELECT COUNT(*)
    INTO v_low_stock
    FROM (
        SELECT p.id
        FROM public.productos p

        JOIN public.inventario_almacen ia
          ON ia.producto_id = p.id

        WHERE COALESCE(p.activo, true) = true

        GROUP BY
            p.id,
            p.stock_minimo

        HAVING
            SUM(ia.cantidad) <=
                COALESCE(p.stock_minimo, 0)
            AND SUM(ia.cantidad) > 0
    ) s;


    SELECT COUNT(*)
    INTO v_out_of_stock
    FROM (
        SELECT p.id
        FROM public.productos p

        LEFT JOIN public.inventario_almacen ia
          ON ia.producto_id = p.id

        WHERE COALESCE(p.activo, true) = true

        GROUP BY p.id

        HAVING
            COALESCE(SUM(ia.cantidad), 0) <= 0
    ) s;


    SELECT COALESCE(SUM(saldo), 0)
    INTO v_por_cobrar
    FROM public.ventas
    WHERE estado = 'pendiente'
      AND cliente_id IS NOT NULL;


    SELECT COALESCE(SUM(saldo), 0)
    INTO v_por_pagar
    FROM public.gastos
    WHERE estado = 'pendiente'
      AND proveedor_id IS NOT NULL;


    RETURN json_build_object(

        -- Nombres correctos nuevos.
        'ingresos_hoy', v_ingresos_hoy,
        'egresos_hoy', v_egresos_hoy,

        -- Compatibilidad temporal con Flutter antiguo.
        'ventas_hoy', v_ingresos_hoy,
        'gastos_hoy', v_egresos_hoy,

        'total_productos', v_total_productos,
        'low_stock_count', v_low_stock,
        'out_of_stock_count', v_out_of_stock,

        'deudas_por_cobrar', v_por_cobrar,
        'deudas_por_pagar', v_por_pagar
    );
END;
$$;
ALTER FUNCTION "public"."get_dashboard_summary"("inicio" timestamp with time zone, "fin" timestamp with time zone) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."get_estado_caja_chica"() RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_sesion_activa public.sesiones_caja%ROWTYPE;
  v_ingresos_efectivo numeric := 0;
  v_egresos_efectivo numeric := 0;
  v_pagos_personal numeric := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado: empleado no autenticado o inactivo.';
  END IF;

  SELECT sc.*
  INTO v_sesion_activa
  FROM public.sesiones_caja AS sc
  WHERE sc.estado = 'ABIERTA'
  ORDER BY sc.fecha_apertura DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN json_build_object('estado', 'CERRADA', 'sesion', NULL);
  END IF;

  SELECT COALESCE(SUM(pv.monto), 0)
  INTO v_ingresos_efectivo
  FROM public.pagos_venta AS pv
  WHERE pv.fecha >= v_sesion_activa.fecha_apertura
    AND TRIM(UPPER(pv.metodo)) LIKE '%EFECTIVO%';

  SELECT COALESCE(SUM(pg.monto), 0)
  INTO v_egresos_efectivo
  FROM public.pagos_gasto AS pg
  WHERE pg.fecha >= v_sesion_activa.fecha_apertura
    AND TRIM(UPPER(pg.metodo)) LIKE '%EFECTIVO%'
    AND COALESCE(pg.afecta_caja_chica, false) = true;

  SELECT COALESCE(SUM(pe.monto), 0)
  INTO v_pagos_personal
  FROM public.pagos_empleados AS pe
  WHERE pe.fecha >= v_sesion_activa.fecha_apertura
    AND TRIM(UPPER(pe.metodo)) LIKE '%EFECTIVO%'
    AND COALESCE(pe.afecta_caja_chica, false) = true;

  RETURN json_build_object(
    'estado', 'ABIERTA',
    'sesion', row_to_json(v_sesion_activa),
    'ingresos_efectivo', v_ingresos_efectivo,
    'egresos_efectivo', v_egresos_efectivo + v_pagos_personal,
    'saldo_esperado',
      v_sesion_activa.monto_apertura
      + v_ingresos_efectivo
      - (v_egresos_efectivo + v_pagos_personal)
  );
END;
$$;
ALTER FUNCTION "public"."get_estado_caja_chica"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."get_user_role"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  SELECT e.rol
  FROM public.empleados e
  WHERE e.auth_id = auth.uid()
    AND COALESCE(e.activo, false) = true
    AND e.rol IN ('admin', 'operador')
  LIMIT 1;
$$;
ALTER FUNCTION "public"."get_user_role"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."gre_claim"("p_guia_id" "uuid", "p_accion" "text", "p_forzar" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_guia public.guias_remision%ROWTYPE;
  v_bloqueo uuid := gen_random_uuid();
  v_intento_id uuid;
  v_numero integer;
BEGIN
  SELECT *
  INTO v_guia
  FROM public.guias_remision
  WHERE id = p_guia_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Guía no encontrada.';
  END IF;

  IF v_guia.estado = 'borrador' THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'borrador',
      'mensaje', 'Completa y prepara la guía antes de emitir.'
    );
  END IF;

  IF v_guia.serie IS NULL OR v_guia.correlativo IS NULL THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', v_guia.estado,
      'mensaje', 'La guía todavía no tiene serie y correlativo.'
    );
  END IF;

  IF v_guia.estado = 'aceptado' THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'aceptado',
      'mensaje', 'La guía ya fue aceptada.'
    );
  END IF;

  IF v_guia.estado = 'rechazado' AND NOT COALESCE(p_forzar, false) THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'rechazado',
      'mensaje', 'Corrige los datos antes de volver a emitir.'
    );
  END IF;

  IF v_guia.estado = 'procesando'
     AND v_guia.bloqueo_expira_at > now() THEN
    RETURN jsonb_build_object(
      'claimed', false,
      'estado', 'procesando',
      'mensaje', 'La guía está siendo procesada.'
    );
  END IF;

  SELECT COALESCE(max(numero_intento), 0) + 1
  INTO v_numero
  FROM public.guias_remision_intentos
  WHERE guia_id = p_guia_id;

  INSERT INTO public.guias_remision_intentos(
    guia_id, numero_intento, accion, resultado
  )
  VALUES (
    p_guia_id,
    v_numero,
    lower(trim(COALESCE(p_accion, 'emitir'))),
    'procesando'
  )
  RETURNING id INTO v_intento_id;

  UPDATE public.guias_remision
  SET
    estado = 'procesando',
    procesando_at = now(),
    bloqueo_token = v_bloqueo,
    bloqueo_expira_at = now() + interval '3 minutes',
    ultimo_intento_at = now()
  WHERE id = p_guia_id;

  RETURN jsonb_build_object(
    'claimed', true,
    'guia_id', p_guia_id,
    'bloqueo_token', v_bloqueo,
    'intento_id', v_intento_id,
    'numero_intento', v_numero,
    'ticket_sunat', v_guia.ticket_sunat
  );
END;
$$;
ALTER FUNCTION "public"."gre_claim"("p_guia_id" "uuid", "p_accion" "text", "p_forzar" boolean) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."gre_claim_v2"("p_guia_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text" DEFAULT 'emitir'::"text", "p_forzar" boolean DEFAULT false, "p_sistema" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."gre_claim_v2"("p_guia_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text", "p_forzar" boolean, "p_sistema" boolean) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."gre_finalizar"("p_guia_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_guia public.guias_remision%ROWTYPE;
  v_estado text := lower(trim(COALESCE(p_estado, '')));
  v_intento_id uuid;
  v_codigo_http integer;
  v_duracion integer;
  v_mensaje text;
BEGIN
  IF v_estado NOT IN (
    'pendiente_envio', 'ticket_pendiente', 'pendiente_reintento',
    'resultado_incierto', 'xml_validado_prueba', 'aceptado', 'rechazado'
  ) THEN
    RAISE EXCEPTION 'Estado final GRE inválido: %', v_estado;
  END IF;

  SELECT * INTO v_guia FROM public.guias_remision
  WHERE id = p_guia_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Guía no encontrada'; END IF;

  IF v_guia.estado = 'aceptado' AND v_estado <> 'aceptado' THEN
    RETURN jsonb_build_object('success', true, 'estado', 'aceptado', 'idempotent', true);
  END IF;

  IF v_guia.bloqueo_token IS DISTINCT FROM p_bloqueo_token THEN
    IF v_guia.estado = 'aceptado' AND v_estado = 'aceptado' THEN
      RETURN jsonb_build_object('success', true, 'estado', 'aceptado', 'idempotent', true);
    END IF;
    RAISE EXCEPTION 'El bloqueo de la guía ya no es válido';
  END IF;

  v_intento_id := NULLIF(p_resultado->>'intento_id', '')::uuid;
  v_codigo_http := NULLIF(p_resultado->>'codigo_http', '')::integer;
  v_duracion := NULLIF(p_resultado->>'duracion_ms', '')::integer;
  v_mensaje := NULLIF(trim(p_resultado->>'mensaje_error'), '');

  UPDATE public.guias_remision
  SET estado = v_estado,
      payload_json = COALESCE(p_resultado->'payload_json', payload_json),
      respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
      ticket_sunat = COALESCE(NULLIF(p_resultado->>'ticket_sunat', ''), ticket_sunat),
      codigo_sunat = COALESCE(NULLIF(p_resultado->>'codigo_sunat', ''), codigo_sunat),
      descripcion_sunat = COALESCE(NULLIF(p_resultado->>'descripcion_sunat', ''), v_mensaje, descripcion_sunat),
      observaciones_sunat = COALESCE(p_resultado->'observaciones_sunat', observaciones_sunat),
      xml_path = COALESCE(NULLIF(p_resultado->>'xml_path', ''), xml_path),
      cdr_path = COALESCE(NULLIF(p_resultado->>'cdr_path', ''), cdr_path),
      pdf_path = COALESCE(NULLIF(p_resultado->>'pdf_path', ''), pdf_path),
      hash_documento = COALESCE(NULLIF(p_resultado->>'hash_documento', ''), hash_documento),
      ambiente_emision = COALESCE(NULLIF(p_resultado->>'ambiente_emision', ''), ambiente_emision),
      es_prueba = COALESCE(NULLIF(p_resultado->>'es_prueba', '')::boolean, es_prueba),
      ultimo_http_status = v_codigo_http,
      ultimo_error_tipo = CASE WHEN v_estado IN ('aceptado', 'xml_validado_prueba') THEN NULL
        ELSE COALESCE(NULLIF(p_resultado->>'error_tipo', ''), ultimo_error_tipo) END,
      enviado_at = CASE WHEN v_estado IN ('ticket_pendiente', 'aceptado', 'rechazado', 'resultado_incierto')
        AND COALESCE(NULLIF(p_resultado->>'ambiente_emision', ''), ambiente_emision) = 'produccion'
        THEN COALESCE(enviado_at, now()) ELSE enviado_at END,
      aceptado_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now()) ELSE aceptado_at END,
      consultado_at = CASE WHEN COALESCE((p_resultado->>'fue_consulta')::boolean, false)
        THEN now() ELSE consultado_at END,
      procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
  WHERE id = p_guia_id;

  IF v_intento_id IS NOT NULL THEN
    UPDATE public.guias_remision_intentos
    SET resultado = v_estado, codigo_http = v_codigo_http,
        codigo_error = NULLIF(p_resultado->>'codigo_error', ''),
        mensaje_error = v_mensaje,
        payload_json = COALESCE(p_resultado->'payload_json', payload_json),
        respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
        fecha_fin = now(),
        duracion_ms = COALESCE(v_duracion,
          GREATEST(0, floor(extract(epoch FROM (now() - fecha_inicio)) * 1000)::integer))
    WHERE id = v_intento_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'guia_id', p_guia_id, 'estado', v_estado);
END;
$$;
ALTER FUNCTION "public"."gre_finalizar"("p_guia_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."gre_normalizar_detalle_unidad"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_tipo_venta text;
  v_pcs integer;
  v_unidad text;
  v_cantidad_entera integer;
  v_piezas_calculadas integer;
BEGIN
  IF NEW.cantidad IS NULL OR NEW.cantidad <= 0 THEN
    RAISE EXCEPTION 'La cantidad del detalle de la guía debe ser mayor a cero.';
  END IF;

  v_unidad := upper(trim(COALESCE(NEW.unidad, 'NIU')));

  -- Aceptar alias comunes, pero guardar siempre el código SUNAT.
  v_unidad := CASE
    WHEN v_unidad IN ('CAJA', 'CAJAS', 'BOX') THEN 'BX'
    WHEN v_unidad IN ('PAQUETE', 'PAQUETES', 'PAQ', 'PACK') THEN 'PK'
    WHEN v_unidad IN ('UNIDAD', 'UNIDADES', 'UND', 'PIEZA', 'PIEZAS') THEN 'NIU'
    ELSE v_unidad
  END;

  IF v_unidad NOT IN ('BX', 'PK', 'NIU', 'ZZ') THEN
    RAISE EXCEPTION 'Unidad GRE no permitida: %.', v_unidad;
  END IF;

  -- Para líneas personalizadas se conserva la equivalencia enviada.
  IF NEW.producto_id IS NULL OR v_unidad = 'ZZ' THEN
    NEW.unidad := v_unidad;

    IF NEW.piezas_reales IS NULL OR NEW.piezas_reales <= 0 THEN
      NEW.piezas_reales := GREATEST(round(NEW.cantidad)::integer, 1);
    END IF;

    NEW.peso_unitario_kg := COALESCE(NEW.peso_unitario_kg, 0);
    NEW.peso_total_kg :=
      round(NEW.peso_unitario_kg * NEW.piezas_reales, 6);

    RETURN NEW;
  END IF;

  SELECT
    upper(trim(COALESCE(p.tipo_venta, ''))),
    GREATEST(COALESCE(p.cantidad_por_caja, 1), 1)
  INTO
    v_tipo_venta,
    v_pcs
  FROM public.productos AS p
  WHERE p.id = NEW.producto_id
    AND COALESCE(p.activo, true) = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'El producto % no existe o está inactivo.',
      NEW.producto_id;
  END IF;

  -- BX, PK y NIU representan cantidades comerciales enteras.
  IF NEW.cantidad <> trunc(NEW.cantidad) THEN
    RAISE EXCEPTION
      'La cantidad de cajas, paquetes o unidades debe ser entera.';
  END IF;

  v_cantidad_entera := NEW.cantidad::integer;

  v_piezas_calculadas := CASE
    -- El paquete es la unidad base del inventario.
    WHEN v_tipo_venta IN ('PAQUETES', 'PAQUETE')
         AND v_unidad = 'PK'
      THEN v_cantidad_entera

    -- La caja contiene paquetes; el paquete suelto es la unidad base.
    WHEN v_tipo_venta = 'CAJA_PAQUETES'
         AND v_unidad = 'BX'
      THEN v_cantidad_entera * v_pcs
    WHEN v_tipo_venta = 'CAJA_PAQUETES'
         AND v_unidad = 'PK'
      THEN v_cantidad_entera

    -- La caja contiene unidades; la unidad suelta es la unidad base.
    WHEN v_tipo_venta IN (
           'CAJA_UNIDADES',
           'AMBOS',
           'CAJA_UNIDAD',
           'CAJAS_UNIDADES'
         )
         AND v_unidad = 'BX'
      THEN v_cantidad_entera * v_pcs
    WHEN v_tipo_venta IN (
           'CAJA_UNIDADES',
           'AMBOS',
           'CAJA_UNIDAD',
           'CAJAS_UNIDADES'
         )
         AND v_unidad = 'NIU'
      THEN v_cantidad_entera

    -- Compatibilidad histórica: la caja completa era la unidad base.
    WHEN v_tipo_venta IN ('CAJA', 'SOLO_CAJAS')
         AND v_unidad = 'BX'
      THEN v_cantidad_entera

    -- Compatibilidad histórica: la unidad es la unidad base.
    WHEN v_tipo_venta IN ('UNIDAD', 'SOLO_UNIDADES')
         AND v_unidad = 'NIU'
      THEN v_cantidad_entera

    ELSE NULL
  END;

  IF v_piezas_calculadas IS NULL THEN
    RAISE EXCEPTION
      'La unidad % no corresponde al tipo de venta % del producto %.',
      v_unidad,
      v_tipo_venta,
      NEW.producto_id;
  END IF;

  NEW.unidad := v_unidad;
  NEW.piezas_reales := v_piezas_calculadas;
  NEW.peso_unitario_kg := COALESCE(NEW.peso_unitario_kg, 0);
  NEW.peso_total_kg :=
    round(NEW.peso_unitario_kg * v_piezas_calculadas, 6);

  RETURN NEW;
END;
$$;
ALTER FUNCTION "public"."gre_normalizar_detalle_unidad"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."guardar_cotizacion_v2"("p_request_id" "uuid", "p_cliente_id" bigint, "p_total" numeric, "p_fecha" timestamp with time zone, "p_observaciones" "text", "p_validez_dias" integer, "p_detalles" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."guardar_cotizacion_v2"("p_request_id" "uuid", "p_cliente_id" bigint, "p_total" numeric, "p_fecha" timestamp with time zone, "p_observaciones" "text", "p_validez_dias" integer, "p_detalles" "jsonb") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."guardar_guia_remision_v2"("p_guia_id" "uuid" DEFAULT NULL::"uuid", "p_request_id" "uuid" DEFAULT NULL::"uuid", "p_emitir" boolean DEFAULT false, "p_tipo_guia" "text" DEFAULT 'remitente'::"text", "p_origen_tipo" "text" DEFAULT 'manual'::"text", "p_venta_id" bigint DEFAULT NULL::bigint, "p_transferencia_id" bigint DEFAULT NULL::bigint, "p_guia_remitente_id" "uuid" DEFAULT NULL::"uuid", "p_documento_relacionado_tipo" "text" DEFAULT NULL::"text", "p_documento_relacionado_numero" "text" DEFAULT NULL::"text", "p_motivo_codigo" "text" DEFAULT '01'::"text", "p_motivo_descripcion" "text" DEFAULT 'VENTA'::"text", "p_modalidad_transporte" "text" DEFAULT '02'::"text", "p_fecha_emision" timestamp with time zone DEFAULT "now"(), "p_fecha_traslado" timestamp with time zone DEFAULT "now"(), "p_destinatario" "jsonb" DEFAULT '{}'::"jsonb", "p_remitente" "jsonb" DEFAULT '{}'::"jsonb", "p_partida" "jsonb" DEFAULT '{}'::"jsonb", "p_llegada" "jsonb" DEFAULT '{}'::"jsonb", "p_transportista_id" bigint DEFAULT NULL::bigint, "p_conductor_id" bigint DEFAULT NULL::bigint, "p_vehiculo_id" bigint DEFAULT NULL::bigint, "p_peso_total" numeric DEFAULT NULL::numeric, "p_peso_editado" boolean DEFAULT false, "p_observacion" "text" DEFAULT NULL::"text", "p_detalles" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
  SELECT public.guardar_guia_remision_v3(
    p_guia_id => p_guia_id,
    p_request_id => p_request_id,
    p_emitir => p_emitir,
    p_tipo_guia => p_tipo_guia,
    p_origen_tipo => p_origen_tipo,
    p_venta_id => p_venta_id,
    p_transferencia_id => p_transferencia_id,
    p_guia_remitente_id => p_guia_remitente_id,
    p_documento_relacionado_tipo => p_documento_relacionado_tipo,
    p_documento_relacionado_numero => p_documento_relacionado_numero,
    p_motivo_codigo => p_motivo_codigo,
    p_motivo_descripcion => p_motivo_descripcion,
    p_modalidad_transporte => p_modalidad_transporte,
    p_fecha_emision => p_fecha_emision,
    p_fecha_traslado => p_fecha_traslado,
    p_destinatario => p_destinatario,
    p_remitente => p_remitente,
    p_partida => p_partida,
    p_llegada => p_llegada,
    p_transportista_id => p_transportista_id,
    p_conductor_id => p_conductor_id,
    p_vehiculo_id => p_vehiculo_id,
    p_peso_total => p_peso_total,
    p_peso_editado => p_peso_editado,
    p_observacion => p_observacion,
    p_detalles => p_detalles,
    p_ind_transbordo => false,
    p_transportista_transbordo_id => NULL,
    p_agencia_origen_id => NULL,
    p_agencia_destino_id => NULL,
    p_destino_entrega_tipo => 'direccion_cliente'
  );
$$;
ALTER FUNCTION "public"."guardar_guia_remision_v2"("p_guia_id" "uuid", "p_request_id" "uuid", "p_emitir" boolean, "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."guardar_guia_remision_v3"("p_guia_id" "uuid" DEFAULT NULL::"uuid", "p_request_id" "uuid" DEFAULT NULL::"uuid", "p_emitir" boolean DEFAULT false, "p_tipo_guia" "text" DEFAULT 'remitente'::"text", "p_origen_tipo" "text" DEFAULT 'manual'::"text", "p_venta_id" bigint DEFAULT NULL::bigint, "p_transferencia_id" bigint DEFAULT NULL::bigint, "p_guia_remitente_id" "uuid" DEFAULT NULL::"uuid", "p_documento_relacionado_tipo" "text" DEFAULT NULL::"text", "p_documento_relacionado_numero" "text" DEFAULT NULL::"text", "p_motivo_codigo" "text" DEFAULT '01'::"text", "p_motivo_descripcion" "text" DEFAULT 'VENTA'::"text", "p_modalidad_transporte" "text" DEFAULT '02'::"text", "p_fecha_emision" timestamp with time zone DEFAULT "now"(), "p_fecha_traslado" timestamp with time zone DEFAULT "now"(), "p_destinatario" "jsonb" DEFAULT '{}'::"jsonb", "p_remitente" "jsonb" DEFAULT '{}'::"jsonb", "p_partida" "jsonb" DEFAULT '{}'::"jsonb", "p_llegada" "jsonb" DEFAULT '{}'::"jsonb", "p_transportista_id" bigint DEFAULT NULL::bigint, "p_conductor_id" bigint DEFAULT NULL::bigint, "p_vehiculo_id" bigint DEFAULT NULL::bigint, "p_peso_total" numeric DEFAULT NULL::numeric, "p_peso_editado" boolean DEFAULT false, "p_observacion" "text" DEFAULT NULL::"text", "p_detalles" "jsonb" DEFAULT '[]'::"jsonb", "p_ind_transbordo" boolean DEFAULT false, "p_transportista_transbordo_id" bigint DEFAULT NULL::bigint, "p_agencia_origen_id" bigint DEFAULT NULL::bigint, "p_agencia_destino_id" bigint DEFAULT NULL::bigint, "p_destino_entrega_tipo" "text" DEFAULT 'direccion_cliente'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_actual public.guias_remision%ROWTYPE;
  v_guia_id uuid;
  v_request_id uuid;
  v_tipo_guia text := lower(trim(COALESCE(p_tipo_guia, 'remitente')));
  v_origen_tipo text := lower(trim(COALESCE(p_origen_tipo, 'manual')));
  v_tipo_doc text;
  v_tipo_serie text;
  v_serie text;
  v_correlativo bigint;
  v_estado text := CASE WHEN COALESCE(p_emitir, false)
    THEN 'pendiente_envio' ELSE 'borrador' END;

  v_dest_tipo text := NULLIF(trim(p_destinatario->>'tipo_documento'), '');
  v_dest_num text := NULLIF(trim(p_destinatario->>'numero_documento'), '');
  v_dest_nombre text := NULLIF(trim(p_destinatario->>'razon_social'), '');
  v_dest_dir text := NULLIF(trim(p_destinatario->>'direccion'), '');
  v_dest_ubigeo text := NULLIF(trim(p_destinatario->>'ubigeo'), '');

  v_partida_dir text := NULLIF(trim(p_partida->>'direccion'), '');
  v_partida_ubigeo text := NULLIF(trim(p_partida->>'ubigeo'), '');
  v_llegada_dir text := NULLIF(trim(p_llegada->>'direccion'), '');
  v_llegada_ubigeo text := NULLIF(trim(p_llegada->>'ubigeo'), '');

  v_rem_tipo text := NULLIF(trim(p_remitente->>'tipo_documento'), '');
  v_rem_num text := NULLIF(trim(p_remitente->>'numero_documento'), '');
  v_rem_nombre text := NULLIF(trim(p_remitente->>'razon_social'), '');

  v_transportista public.gre_transportistas%ROWTYPE;
  v_transportista_transbordo public.gre_transportistas%ROWTYPE;
  v_conductor public.gre_conductores%ROWTYPE;
  v_vehiculo public.gre_vehiculos%ROWTYPE;
  v_agencia_origen public.gre_transportistas_agencias%ROWTYPE;
  v_agencia_destino public.gre_transportistas_agencias%ROWTYPE;
  v_destino_entrega_tipo text := lower(trim(COALESCE(p_destino_entrega_tipo, 'direccion_cliente')));
  v_detalle jsonb;
  v_gre_transportista_habilitada boolean := false;
BEGIN
  IF auth.uid() IS NULL OR NOT public._gre_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado: empleado no autenticado o inactivo.';
  END IF;

  IF v_tipo_guia NOT IN ('remitente', 'transportista') THEN
    RAISE EXCEPTION 'Tipo de guía inválido.';
  END IF;

  IF v_origen_tipo NOT IN ('manual', 'venta', 'traslado') THEN
    RAISE EXCEPTION 'Origen de guía inválido.';
  END IF;

  IF p_modalidad_transporte NOT IN ('01', '02') THEN
    RAISE EXCEPTION 'Modalidad inválida. Use 01 público o 02 privado.';
  END IF;

  IF v_destino_entrega_tipo NOT IN ('agencia', 'direccion_cliente') THEN
    RAISE EXCEPTION 'Destino de entrega inválido.';
  END IF;

  IF p_motivo_codigo NOT IN ('01','02','04','08','09','13','14','18','19') THEN
    RAISE EXCEPTION 'Motivo de traslado no permitido.';
  END IF;

  v_tipo_doc := CASE WHEN v_tipo_guia = 'transportista' THEN '31' ELSE '09' END;
  v_tipo_serie := CASE
    WHEN v_tipo_guia = 'transportista' THEN 'guia_transportista'
    ELSE 'guia_remitente'
  END;

  IF p_guia_id IS NOT NULL THEN
    SELECT *
    INTO v_actual
    FROM public.guias_remision
    WHERE id = p_guia_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Guía no encontrada.';
    END IF;

    IF v_actual.ticket_sunat IS NOT NULL THEN
      RAISE EXCEPTION
        'La guía ya tiene ticket SUNAT y no puede editarse.';
    END IF;

    IF v_actual.estado NOT IN (
      'borrador', 'pendiente_envio', 'pendiente_reintento', 'rechazado'
    ) THEN
      RAISE EXCEPTION
        'La guía no puede editarse en estado %.', v_actual.estado;
    END IF;

    IF v_actual.tipo_documento_sunat <> v_tipo_doc
       AND v_actual.serie IS NOT NULL THEN
      RAISE EXCEPTION
        'No se puede cambiar el tipo de una guía ya numerada.';
    END IF;

    v_guia_id := v_actual.id;
    v_request_id := v_actual.request_id;
    v_serie := v_actual.serie;
    v_correlativo := v_actual.correlativo;
  ELSE
    IF p_request_id IS NULL THEN
      RAISE EXCEPTION 'request_id es obligatorio.';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));

    SELECT *
    INTO v_actual
    FROM public.guias_remision
    WHERE request_id = p_request_id
    FOR UPDATE;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'success', true,
        'idempotent', true,
        'guia_id', v_actual.id,
        'estado', v_actual.estado,
        'serie', v_actual.serie,
        'correlativo', v_actual.correlativo
      );
    END IF;

    v_guia_id := gen_random_uuid();
    v_request_id := p_request_id;
  END IF;

  IF jsonb_typeof(p_detalles) <> 'array' THEN
    RAISE EXCEPTION 'Los detalles deben enviarse como arreglo JSON.';
  END IF;

  -- Catálogo y snapshots del transbordo programado. La GRE Remitente
  -- conserva modalidad privada porque el remitente opera el primer tramo.
  IF p_transportista_transbordo_id IS NOT NULL THEN
    SELECT *
    INTO v_transportista_transbordo
    FROM public.gre_transportistas
    WHERE id = p_transportista_transbordo_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Transportista del transbordo no encontrado.';
    END IF;
  END IF;

  IF p_agencia_origen_id IS NOT NULL THEN
    SELECT *
    INTO v_agencia_origen
    FROM public.gre_transportistas_agencias
    WHERE id = p_agencia_origen_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Agencia de origen no encontrada.';
    END IF;
  END IF;

  IF p_agencia_destino_id IS NOT NULL THEN
    SELECT *
    INTO v_agencia_destino
    FROM public.gre_transportistas_agencias
    WHERE id = p_agencia_destino_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Agencia de destino no encontrada.';
    END IF;
  END IF;

  IF COALESCE(p_ind_transbordo, false)
     AND v_destino_entrega_tipo = 'agencia'
     AND p_agencia_destino_id IS NOT NULL THEN
    v_llegada_dir := NULLIF(trim(v_agencia_destino.direccion), '');
    v_llegada_ubigeo := NULLIF(trim(v_agencia_destino.ubigeo), '');
  END IF;

  IF COALESCE(p_emitir, false) THEN
    IF jsonb_array_length(p_detalles) = 0 THEN
      RAISE EXCEPTION 'La guía debe contener al menos un producto.';
    END IF;

    IF v_dest_tipo IS NULL OR v_dest_num IS NULL OR v_dest_nombre IS NULL THEN
      RAISE EXCEPTION 'Documento y nombre del destinatario son obligatorios.';
    END IF;

    IF char_length(COALESCE(v_partida_dir, '')) < 5 THEN
      RAISE EXCEPTION 'Ingresa una dirección de partida completa.';
    END IF;

    IF char_length(COALESCE(v_llegada_dir, '')) < 5 THEN
      RAISE EXCEPTION 'Ingresa una dirección de llegada completa.';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.gre_ubigeos
      WHERE codigo = v_partida_ubigeo AND activo = true
    ) THEN
      RAISE EXCEPTION 'Selecciona un ubigeo válido para la partida.';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM public.gre_ubigeos
      WHERE codigo = v_llegada_ubigeo AND activo = true
    ) THEN
      RAISE EXCEPTION 'Selecciona un ubigeo válido para la llegada.';
    END IF;

    IF COALESCE(p_peso_total, 0) <= 0 THEN
      RAISE EXCEPTION 'El peso total debe ser mayor a cero.';
    END IF;

    IF v_tipo_guia = 'transportista' THEN
      SELECT COALESCE(gre_transportista_habilitada, false)
      INTO v_gre_transportista_habilitada
      FROM public.configuracion_negocio
      ORDER BY id
      LIMIT 1;

      IF NOT v_gre_transportista_habilitada THEN
        RAISE EXCEPTION
          'La GRE Transportista está deshabilitada.';
      END IF;

      IF v_rem_tipo IS NULL OR v_rem_num IS NULL OR v_rem_nombre IS NULL THEN
        RAISE EXCEPTION
          'La GRE Transportista requiere los datos del remitente.';
      END IF;

      IF NULLIF(trim(COALESCE(p_documento_relacionado_numero, '')), '') IS NULL THEN
        RAISE EXCEPTION
          'La GRE Transportista requiere una GRE Remitente relacionada.';
      END IF;
    END IF;

    IF COALESCE(p_ind_transbordo, false) THEN
      IF v_tipo_guia <> 'remitente' OR p_modalidad_transporte <> '02' THEN
        RAISE EXCEPTION
          'El transbordo programado solo se admite en una GRE Remitente con primer tramo privado.';
      END IF;

      IF p_transportista_transbordo_id IS NULL
         OR p_agencia_origen_id IS NULL THEN
        RAISE EXCEPTION
          'Selecciona la empresa transportista y la agencia donde se realizará el transbordo.';
      END IF;

      IF v_transportista_transbordo.activo IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'El transportista del transbordo está inactivo.';
      END IF;

      IF v_agencia_origen.activo IS DISTINCT FROM true
         OR v_agencia_origen.permite_origen IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'La agencia seleccionada no está habilitada como origen.';
      END IF;

      IF v_agencia_origen.transportista_id <> p_transportista_transbordo_id THEN
        RAISE EXCEPTION 'La agencia de origen no pertenece al transportista seleccionado.';
      END IF;

      IF v_destino_entrega_tipo = 'agencia' THEN
        IF p_agencia_destino_id IS NULL THEN
          RAISE EXCEPTION 'Selecciona la agencia de destino.';
        END IF;

        IF v_agencia_destino.activo IS DISTINCT FROM true
           OR v_agencia_destino.permite_destino IS DISTINCT FROM true THEN
          RAISE EXCEPTION 'La agencia seleccionada no está habilitada como destino.';
        END IF;

        IF v_agencia_destino.transportista_id <> p_transportista_transbordo_id THEN
          RAISE EXCEPTION 'La agencia de destino no pertenece al transportista seleccionado.';
        END IF;
      END IF;
    END IF;

    -- Transporte público en GRE Remitente: solo empresa transportista.
    IF p_modalidad_transporte = '01' AND v_tipo_guia = 'remitente' THEN
      IF p_transportista_id IS NULL THEN
        RAISE EXCEPTION
          'En transporte público selecciona la empresa transportista.';
      END IF;

      SELECT *
      INTO v_transportista
      FROM public.gre_transportistas
      WHERE id = p_transportista_id AND activo = true;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Transportista no encontrado o inactivo.';
      END IF;

      IF NULLIF(trim(v_transportista.ruc), '') IS NULL
         OR NULLIF(trim(v_transportista.razon_social), '') IS NULL THEN
        RAISE EXCEPTION 'Completa los datos del transportista.';
      END IF;
    ELSE
      -- Transporte privado y GRE Transportista: conductor y vehículo reales.
      IF p_conductor_id IS NULL OR p_vehiculo_id IS NULL THEN
        RAISE EXCEPTION 'Selecciona conductor y vehículo.';
      END IF;

      SELECT *
      INTO v_conductor
      FROM public.gre_conductores
      WHERE id = p_conductor_id AND activo = true;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Conductor no encontrado o inactivo.';
      END IF;

      SELECT *
      INTO v_vehiculo
      FROM public.gre_vehiculos
      WHERE id = p_vehiculo_id AND activo = true;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehículo no encontrado o inactivo.';
      END IF;

      IF NULLIF(trim(v_conductor.numero_licencia), '') IS NULL THEN
        RAISE EXCEPTION 'La licencia de conducir es obligatoria.';
      END IF;

      IF NULLIF(trim(v_conductor.nombres), '') IS NULL
         OR NULLIF(trim(v_conductor.apellidos), '') IS NULL THEN
        RAISE EXCEPTION
          'Registra nombres y apellidos del conductor por separado.';
      END IF;

      IF NULLIF(trim(v_vehiculo.placa), '') IS NULL
         OR NULLIF(trim(v_vehiculo.marca), '') IS NULL
         OR NULLIF(trim(v_vehiculo.constancia_inscripcion), '') IS NULL THEN
        RAISE EXCEPTION
          'Completa placa, marca y constancia de inscripción del vehículo.';
      END IF;
    END IF;

    -- Reservar el correlativo solo cuando se va a emitir.
    IF v_serie IS NULL OR v_correlativo IS NULL THEN
      SELECT serie, ultimo_correlativo + 1
      INTO v_serie, v_correlativo
      FROM public.series_comprobantes
      WHERE tipo_documento_sunat = v_tipo_serie
        AND activo = true
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe una serie activa para %.', v_tipo_serie;
      END IF;

      UPDATE public.series_comprobantes
      SET ultimo_correlativo = v_correlativo,
          updated_at = now()
      WHERE tipo_documento_sunat = v_tipo_serie
        AND serie = v_serie;
    END IF;
  END IF;

  -- Cargar snapshots opcionales.
  IF p_transportista_id IS NOT NULL THEN
    SELECT *
    INTO v_transportista
    FROM public.gre_transportistas
    WHERE id = p_transportista_id;
  END IF;

  IF p_conductor_id IS NOT NULL THEN
    SELECT *
    INTO v_conductor
    FROM public.gre_conductores
    WHERE id = p_conductor_id;
  END IF;

  IF p_vehiculo_id IS NOT NULL THEN
    SELECT *
    INTO v_vehiculo
    FROM public.gre_vehiculos
    WHERE id = p_vehiculo_id;
  END IF;

  INSERT INTO public.guias_remision(
    id,
    request_id,
    tipo_guia,
    tipo_documento_sunat,
    serie,
    correlativo,
    estado,
    origen_tipo,
    venta_id,
    transferencia_id,
    comprobante_id,
    guia_remitente_id,
    documento_relacionado_tipo,
    documento_relacionado_numero,
    motivo_codigo,
    motivo_descripcion,
    modalidad_transporte,
    fecha_emision,
    fecha_traslado,
    destinatario_tipo_documento,
    destinatario_numero_documento,
    destinatario_razon_social,
    destinatario_direccion,
    destinatario_ubigeo,
    remitente_tipo_documento,
    remitente_numero_documento,
    remitente_razon_social,
    partida_direccion,
    partida_ubigeo,
    llegada_direccion,
    llegada_ubigeo,
    peso_total,
    peso_editado,
    transportista_id,
    conductor_id,
    vehiculo_id,
    ind_transbordo,
    transportista_transbordo_id,
    agencia_origen_id,
    agencia_destino_id,
    destino_entrega_tipo,
    transportista_transbordo_ruc_snapshot,
    transportista_transbordo_razon_social_snapshot,
    transportista_transbordo_registro_mtc_snapshot,
    agencia_origen_nombre_snapshot,
    agencia_origen_direccion_snapshot,
    agencia_origen_ubigeo_snapshot,
    agencia_destino_nombre_snapshot,
    agencia_destino_direccion_snapshot,
    agencia_destino_ubigeo_snapshot,
    transportista_ruc_snapshot,
    transportista_razon_social_snapshot,
    transportista_registro_mtc_snapshot,
    conductor_tipo_documento_snapshot,
    conductor_documento_snapshot,
    conductor_nombres_snapshot,
    conductor_apellidos_snapshot,
    conductor_licencia_snapshot,
    vehiculo_placa_snapshot,
    vehiculo_marca_snapshot,
    vehiculo_modelo_snapshot,
    vehiculo_constancia_snapshot,
    observacion,
    descripcion_sunat,
    creado_por
  )
  VALUES (
    v_guia_id,
    v_request_id,
    v_tipo_guia,
    v_tipo_doc,
    v_serie,
    v_correlativo,
    v_estado,
    v_origen_tipo,
    p_venta_id,
    p_transferencia_id,
    CASE
      WHEN p_venta_id IS NULL THEN NULL
      ELSE (
        SELECT ce.id
        FROM public.comprobantes_electronicos AS ce
        WHERE ce.venta_id = p_venta_id
          AND ce.estado = 'aceptado'
        ORDER BY ce.created_at DESC
        LIMIT 1
      )
    END,
    p_guia_remitente_id,
    NULLIF(trim(COALESCE(p_documento_relacionado_tipo, '')), ''),
    NULLIF(trim(COALESCE(p_documento_relacionado_numero, '')), ''),
    p_motivo_codigo,
    trim(COALESCE(p_motivo_descripcion, '')),
    p_modalidad_transporte,
    COALESCE(p_fecha_emision, now()),
    COALESCE(p_fecha_traslado, now()),
    v_dest_tipo,
    v_dest_num,
    v_dest_nombre,
    COALESCE(v_dest_dir, v_llegada_dir),
    COALESCE(v_dest_ubigeo, v_llegada_ubigeo),
    v_rem_tipo,
    v_rem_num,
    v_rem_nombre,
    v_partida_dir,
    v_partida_ubigeo,
    v_llegada_dir,
    v_llegada_ubigeo,
    p_peso_total,
    COALESCE(p_peso_editado, false),
    p_transportista_id,
    p_conductor_id,
    p_vehiculo_id,
    COALESCE(p_ind_transbordo, false),
    CASE WHEN COALESCE(p_ind_transbordo, false)
      THEN p_transportista_transbordo_id ELSE NULL END,
    CASE WHEN COALESCE(p_ind_transbordo, false)
      THEN p_agencia_origen_id ELSE NULL END,
    CASE WHEN COALESCE(p_ind_transbordo, false)
              AND v_destino_entrega_tipo = 'agencia'
      THEN p_agencia_destino_id ELSE NULL END,
    CASE WHEN COALESCE(p_ind_transbordo, false)
      THEN v_destino_entrega_tipo ELSE 'direccion_cliente' END,
    CASE WHEN COALESCE(p_ind_transbordo, false)
      THEN v_transportista_transbordo.ruc ELSE NULL END,
    CASE WHEN COALESCE(p_ind_transbordo, false)
      THEN v_transportista_transbordo.razon_social ELSE NULL END,
    CASE WHEN COALESCE(p_ind_transbordo, false)
      THEN v_transportista_transbordo.registro_mtc ELSE NULL END,
    CASE WHEN COALESCE(p_ind_transbordo, false)
      THEN v_agencia_origen.nombre ELSE NULL END,
    CASE WHEN COALESCE(p_ind_transbordo, false)
      THEN v_agencia_origen.direccion ELSE NULL END,
    CASE WHEN COALESCE(p_ind_transbordo, false)
      THEN v_agencia_origen.ubigeo ELSE NULL END,
    CASE WHEN COALESCE(p_ind_transbordo, false)
              AND v_destino_entrega_tipo = 'agencia'
      THEN v_agencia_destino.nombre ELSE NULL END,
    CASE WHEN COALESCE(p_ind_transbordo, false)
              AND v_destino_entrega_tipo = 'agencia'
      THEN v_agencia_destino.direccion ELSE NULL END,
    CASE WHEN COALESCE(p_ind_transbordo, false)
              AND v_destino_entrega_tipo = 'agencia'
      THEN v_agencia_destino.ubigeo ELSE NULL END,
    CASE
      WHEN p_modalidad_transporte = '01'
           AND v_tipo_guia = 'remitente'
        THEN v_transportista.ruc
      WHEN v_tipo_guia = 'transportista'
        THEN (
          SELECT ruc FROM public.configuracion_negocio ORDER BY id LIMIT 1
        )
      ELSE NULL
    END,
    CASE
      WHEN p_modalidad_transporte = '01'
           AND v_tipo_guia = 'remitente'
        THEN v_transportista.razon_social
      WHEN v_tipo_guia = 'transportista'
        THEN (
          SELECT COALESCE(razon_social, nombre_comercial)
          FROM public.configuracion_negocio ORDER BY id LIMIT 1
        )
      ELSE NULL
    END,
    CASE
      WHEN p_modalidad_transporte = '01'
           AND v_tipo_guia = 'remitente'
        THEN v_transportista.registro_mtc
      ELSE NULL
    END,
    v_conductor.tipo_documento,
    v_conductor.numero_documento,
    v_conductor.nombres,
    v_conductor.apellidos,
    v_conductor.numero_licencia,
    upper(trim(v_vehiculo.placa)),
    v_vehiculo.marca,
    v_vehiculo.modelo,
    v_vehiculo.constancia_inscripcion,
    NULLIF(trim(COALESCE(p_observacion, '')), ''),
    CASE
      WHEN v_estado = 'borrador'
        THEN 'Borrador. Completa los datos antes de emitir.'
      ELSE NULL
    END,
    auth.uid()
  )
  ON CONFLICT (id) DO UPDATE
  SET
    tipo_guia = EXCLUDED.tipo_guia,
    tipo_documento_sunat = EXCLUDED.tipo_documento_sunat,
    serie = EXCLUDED.serie,
    correlativo = EXCLUDED.correlativo,
    estado = EXCLUDED.estado,
    origen_tipo = EXCLUDED.origen_tipo,
    venta_id = EXCLUDED.venta_id,
    transferencia_id = EXCLUDED.transferencia_id,
    comprobante_id = EXCLUDED.comprobante_id,
    guia_remitente_id = EXCLUDED.guia_remitente_id,
    documento_relacionado_tipo = EXCLUDED.documento_relacionado_tipo,
    documento_relacionado_numero = EXCLUDED.documento_relacionado_numero,
    motivo_codigo = EXCLUDED.motivo_codigo,
    motivo_descripcion = EXCLUDED.motivo_descripcion,
    modalidad_transporte = EXCLUDED.modalidad_transporte,
    fecha_emision = EXCLUDED.fecha_emision,
    fecha_traslado = EXCLUDED.fecha_traslado,
    destinatario_tipo_documento = EXCLUDED.destinatario_tipo_documento,
    destinatario_numero_documento = EXCLUDED.destinatario_numero_documento,
    destinatario_razon_social = EXCLUDED.destinatario_razon_social,
    destinatario_direccion = EXCLUDED.destinatario_direccion,
    destinatario_ubigeo = EXCLUDED.destinatario_ubigeo,
    remitente_tipo_documento = EXCLUDED.remitente_tipo_documento,
    remitente_numero_documento = EXCLUDED.remitente_numero_documento,
    remitente_razon_social = EXCLUDED.remitente_razon_social,
    partida_direccion = EXCLUDED.partida_direccion,
    partida_ubigeo = EXCLUDED.partida_ubigeo,
    llegada_direccion = EXCLUDED.llegada_direccion,
    llegada_ubigeo = EXCLUDED.llegada_ubigeo,
    peso_total = EXCLUDED.peso_total,
    peso_editado = EXCLUDED.peso_editado,
    transportista_id = EXCLUDED.transportista_id,
    conductor_id = EXCLUDED.conductor_id,
    vehiculo_id = EXCLUDED.vehiculo_id,
    ind_transbordo = EXCLUDED.ind_transbordo,
    transportista_transbordo_id = EXCLUDED.transportista_transbordo_id,
    agencia_origen_id = EXCLUDED.agencia_origen_id,
    agencia_destino_id = EXCLUDED.agencia_destino_id,
    destino_entrega_tipo = EXCLUDED.destino_entrega_tipo,
    transportista_transbordo_ruc_snapshot =
      EXCLUDED.transportista_transbordo_ruc_snapshot,
    transportista_transbordo_razon_social_snapshot =
      EXCLUDED.transportista_transbordo_razon_social_snapshot,
    transportista_transbordo_registro_mtc_snapshot =
      EXCLUDED.transportista_transbordo_registro_mtc_snapshot,
    agencia_origen_nombre_snapshot = EXCLUDED.agencia_origen_nombre_snapshot,
    agencia_origen_direccion_snapshot =
      EXCLUDED.agencia_origen_direccion_snapshot,
    agencia_origen_ubigeo_snapshot = EXCLUDED.agencia_origen_ubigeo_snapshot,
    agencia_destino_nombre_snapshot = EXCLUDED.agencia_destino_nombre_snapshot,
    agencia_destino_direccion_snapshot =
      EXCLUDED.agencia_destino_direccion_snapshot,
    agencia_destino_ubigeo_snapshot = EXCLUDED.agencia_destino_ubigeo_snapshot,
    transportista_ruc_snapshot = EXCLUDED.transportista_ruc_snapshot,
    transportista_razon_social_snapshot =
      EXCLUDED.transportista_razon_social_snapshot,
    transportista_registro_mtc_snapshot =
      EXCLUDED.transportista_registro_mtc_snapshot,
    conductor_tipo_documento_snapshot =
      EXCLUDED.conductor_tipo_documento_snapshot,
    conductor_documento_snapshot = EXCLUDED.conductor_documento_snapshot,
    conductor_nombres_snapshot = EXCLUDED.conductor_nombres_snapshot,
    conductor_apellidos_snapshot = EXCLUDED.conductor_apellidos_snapshot,
    conductor_licencia_snapshot = EXCLUDED.conductor_licencia_snapshot,
    vehiculo_placa_snapshot = EXCLUDED.vehiculo_placa_snapshot,
    vehiculo_marca_snapshot = EXCLUDED.vehiculo_marca_snapshot,
    vehiculo_modelo_snapshot = EXCLUDED.vehiculo_modelo_snapshot,
    vehiculo_constancia_snapshot = EXCLUDED.vehiculo_constancia_snapshot,
    observacion = EXCLUDED.observacion,
    payload_json = NULL,
    respuesta_json = NULL,
    codigo_sunat = NULL,
    descripcion_sunat = EXCLUDED.descripcion_sunat,
    observaciones_sunat = NULL,
    ultimo_http_status = NULL,
    ultimo_error_tipo = NULL,
    procesando_at = NULL,
    bloqueo_token = NULL,
    bloqueo_expira_at = NULL,
    updated_at = now();

  DELETE FROM public.guias_remision_detalles
  WHERE guia_id = v_guia_id;

  FOR v_detalle IN
    SELECT value FROM jsonb_array_elements(p_detalles)
  LOOP
    IF COALESCE(NULLIF(v_detalle->>'cantidad', '')::numeric, 0) <= 0 THEN
      RAISE EXCEPTION 'Todas las cantidades deben ser mayores a cero.';
    END IF;

    IF NULLIF(trim(v_detalle->>'descripcion'), '') IS NULL THEN
      RAISE EXCEPTION 'Cada línea debe tener descripción.';
    END IF;

    INSERT INTO public.guias_remision_detalles(
      guia_id,
      producto_id,
      detalle_venta_id,
      transferencia_id,
      almacen_id,
      codigo,
      descripcion,
      unidad,
      cantidad,
      piezas_reales,
      peso_unitario_kg,
      peso_total_kg
    )
    VALUES (
      v_guia_id,
      NULLIF(v_detalle->>'producto_id', '')::bigint,
      NULLIF(v_detalle->>'detalle_venta_id', '')::bigint,
      NULLIF(v_detalle->>'transferencia_id', '')::bigint,
      NULLIF(v_detalle->>'almacen_id', '')::bigint,
      NULLIF(trim(v_detalle->>'codigo'), ''),
      trim(v_detalle->>'descripcion'),
      upper(COALESCE(NULLIF(trim(v_detalle->>'unidad'), ''), 'NIU')),
      (v_detalle->>'cantidad')::numeric,
      NULLIF(v_detalle->>'piezas_reales', '')::integer,
      COALESCE(NULLIF(v_detalle->>'peso_unitario_kg', '')::numeric, 0),
      COALESCE(NULLIF(v_detalle->>'peso_total_kg', '')::numeric, 0)
    );
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'guia_id', v_guia_id,
    'estado', v_estado,
    'serie', v_serie,
    'correlativo', v_correlativo,
    'emitir', COALESCE(p_emitir, false),
    'stock_modificado', false
  );
END;
$$;
ALTER FUNCTION "public"."guardar_guia_remision_v3"("p_guia_id" "uuid", "p_request_id" "uuid", "p_emitir" boolean, "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb", "p_ind_transbordo" boolean, "p_transportista_transbordo_id" bigint, "p_agencia_origen_id" bigint, "p_agencia_destino_id" bigint, "p_destino_entrega_tipo" "text") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."guardar_guia_remision_v4"("p_guia_id" "uuid" DEFAULT NULL::"uuid", "p_request_id" "uuid" DEFAULT NULL::"uuid", "p_emitir" boolean DEFAULT false, "p_tipo_guia" "text" DEFAULT 'remitente'::"text", "p_origen_tipo" "text" DEFAULT 'manual'::"text", "p_venta_id" bigint DEFAULT NULL::bigint, "p_transferencia_id" bigint DEFAULT NULL::bigint, "p_guia_remitente_id" "uuid" DEFAULT NULL::"uuid", "p_documento_relacionado_tipo" "text" DEFAULT NULL::"text", "p_documento_relacionado_numero" "text" DEFAULT NULL::"text", "p_motivo_codigo" "text" DEFAULT '01'::"text", "p_motivo_descripcion" "text" DEFAULT 'VENTA'::"text", "p_modalidad_transporte" "text" DEFAULT '02'::"text", "p_fecha_emision" timestamp with time zone DEFAULT "now"(), "p_fecha_traslado" timestamp with time zone DEFAULT "now"(), "p_destinatario" "jsonb" DEFAULT '{}'::"jsonb", "p_remitente" "jsonb" DEFAULT '{}'::"jsonb", "p_partida" "jsonb" DEFAULT '{}'::"jsonb", "p_llegada" "jsonb" DEFAULT '{}'::"jsonb", "p_transportista_id" bigint DEFAULT NULL::bigint, "p_conductor_id" bigint DEFAULT NULL::bigint, "p_vehiculo_id" bigint DEFAULT NULL::bigint, "p_peso_total" numeric DEFAULT NULL::numeric, "p_cantidad_bultos" integer DEFAULT NULL::integer, "p_peso_editado" boolean DEFAULT false, "p_observacion" "text" DEFAULT NULL::"text", "p_detalles" "jsonb" DEFAULT '[]'::"jsonb", "p_ind_transbordo" boolean DEFAULT false, "p_transportista_transbordo_id" bigint DEFAULT NULL::bigint, "p_agencia_origen_id" bigint DEFAULT NULL::bigint, "p_agencia_destino_id" bigint DEFAULT NULL::bigint, "p_destino_entrega_tipo" "text" DEFAULT 'direccion_cliente'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_result jsonb;
  v_guia_id uuid;
BEGIN
  IF p_cantidad_bultos IS NOT NULL AND p_cantidad_bultos <= 0 THEN
    RAISE EXCEPTION 'El número de bultos debe ser mayor a cero.';
  END IF;

  v_result := public.guardar_guia_remision_v3(
    p_guia_id => p_guia_id,
    p_request_id => p_request_id,
    p_emitir => p_emitir,
    p_tipo_guia => p_tipo_guia,
    p_origen_tipo => p_origen_tipo,
    p_venta_id => p_venta_id,
    p_transferencia_id => p_transferencia_id,
    p_guia_remitente_id => p_guia_remitente_id,
    p_documento_relacionado_tipo => p_documento_relacionado_tipo,
    p_documento_relacionado_numero => p_documento_relacionado_numero,
    p_motivo_codigo => p_motivo_codigo,
    p_motivo_descripcion => p_motivo_descripcion,
    p_modalidad_transporte => p_modalidad_transporte,
    p_fecha_emision => p_fecha_emision,
    p_fecha_traslado => p_fecha_traslado,
    p_destinatario => p_destinatario,
    p_remitente => p_remitente,
    p_partida => p_partida,
    p_llegada => p_llegada,
    p_transportista_id => p_transportista_id,
    p_conductor_id => p_conductor_id,
    p_vehiculo_id => p_vehiculo_id,
    p_peso_total => p_peso_total,
    p_peso_editado => p_peso_editado,
    p_observacion => p_observacion,
    p_detalles => p_detalles,
    p_ind_transbordo => p_ind_transbordo,
    p_transportista_transbordo_id => p_transportista_transbordo_id,
    p_agencia_origen_id => p_agencia_origen_id,
    p_agencia_destino_id => p_agencia_destino_id,
    p_destino_entrega_tipo => p_destino_entrega_tipo
  );

  v_guia_id := NULLIF(v_result->>'guia_id', '')::uuid;
  IF v_guia_id IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la guía guardada.';
  END IF;

  UPDATE public.guias_remision
  SET cantidad_bultos = p_cantidad_bultos,
      updated_at = now()
  WHERE id = v_guia_id;

  RETURN v_result || jsonb_build_object(
    'cantidad_bultos', p_cantidad_bultos
  );
END;
$$;
ALTER FUNCTION "public"."guardar_guia_remision_v4"("p_guia_id" "uuid", "p_request_id" "uuid", "p_emitir" boolean, "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_cantidad_bultos" integer, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb", "p_ind_transbordo" boolean, "p_transportista_transbordo_id" bigint, "p_agencia_origen_id" bigint, "p_agencia_destino_id" bigint, "p_destino_entrega_tipo" "text") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Intenta vincular el auth_id
  UPDATE public.empleados
  SET auth_id = NEW.id
  WHERE email = NEW.email AND auth_id IS NULL;

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    -- Si ALGO sale mal (permisos, tablas), ignora el error y PERMITE que el usuario se registre
    RETURN NEW;
END;
$$;
ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."increment_stock"("p_producto_id" bigint, "p_almacen_id" bigint, "p_delta" integer) RETURNS integer
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  nuevo_stock INT;
BEGIN
  -- Upsert: si no existe la fila, crearla con la cantidad
  INSERT INTO inventario_almacen (producto_id, almacen_id, cantidad)
  VALUES (p_producto_id, p_almacen_id, GREATEST(p_delta, 0))
  ON CONFLICT (producto_id, almacen_id)
  DO UPDATE SET cantidad = inventario_almacen.cantidad + p_delta;

  SELECT cantidad INTO nuevo_stock
  FROM inventario_almacen
  WHERE producto_id = p_producto_id AND almacen_id = p_almacen_id;

  RETURN nuevo_stock;
END;
$$;
ALTER FUNCTION "public"."increment_stock"("p_producto_id" bigint, "p_almacen_id" bigint, "p_delta" integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."listar_documentos_electronicos_v1"("p_fecha_inicio" timestamp with time zone, "p_fecha_fin_exclusiva" timestamp with time zone, "p_limite" integer DEFAULT 50, "p_offset" integer DEFAULT 0) RETURNS TABLE("categoria" "text", "tipo_label" "text", "id" "text", "venta_id" bigint, "numero" "text", "estado" "text", "total" numeric, "tercero" "text", "fecha_documento" timestamp with time zone, "descripcion_sunat" "text", "pdf_path" "text", "xml_path" "text", "cdr_path" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."listar_documentos_electronicos_v1"("p_fecha_inicio" timestamp with time zone, "p_fecha_fin_exclusiva" timestamp with time zone, "p_limite" integer, "p_offset" integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."nota_credito_claim"("p_nota_credito_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text" DEFAULT 'emitir'::"text", "p_forzar" boolean DEFAULT false, "p_sistema" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."nota_credito_claim"("p_nota_credito_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text", "p_forzar" boolean, "p_sistema" boolean) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."nota_credito_finalizar"("p_nota_credito_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_nota record;
  v_estado text := LOWER(TRIM(COALESCE(p_estado, '')));
  v_intento_id uuid;
  v_codigo_http integer;
  v_duracion integer;
  v_mensaje text;
  v_stock_result jsonb;
  v_total_nc numeric(14,2);
  v_venta_total numeric(14,2);
BEGIN
  IF v_estado NOT IN ('aceptado', 'rechazado', 'pendiente_reintento', 'resultado_incierto') THEN
    RAISE EXCEPTION 'Estado final inválido: %', v_estado;
  END IF;

  SELECT * INTO v_nota
  FROM public.notas_credito
  WHERE id = p_nota_credito_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nota de crédito no encontrada';
  END IF;

  IF v_nota.estado = 'aceptado' AND v_estado <> 'aceptado' THEN
    RETURN jsonb_build_object(
      'success', true, 'estado', 'aceptado', 'idempotent', true,
      'ignored_state', v_estado, 'nota_credito_id', p_nota_credito_id
    );
  END IF;

  IF v_nota.bloqueo_token IS DISTINCT FROM p_bloqueo_token THEN
    IF v_nota.estado = 'aceptado' AND v_estado = 'aceptado' THEN
      RETURN jsonb_build_object(
        'success', true, 'estado', 'aceptado', 'idempotent', true,
        'nota_credito_id', p_nota_credito_id
      );
    END IF;
    RAISE EXCEPTION 'El bloqueo de la nota ya no es válido';
  END IF;

  v_intento_id := NULLIF(p_resultado->>'intento_id', '')::uuid;
  v_codigo_http := NULLIF(p_resultado->>'codigo_http', '')::integer;
  v_duracion := NULLIF(p_resultado->>'duracion_ms', '')::integer;
  v_mensaje := NULLIF(TRIM(p_resultado->>'mensaje_error'), '');

  UPDATE public.notas_credito
  SET
    estado = v_estado,
    payload_json = COALESCE(p_resultado->'payload_json', payload_json),
    respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
    xml_path = COALESCE(NULLIF(p_resultado->>'xml_path', ''), xml_path),
    cdr_path = COALESCE(NULLIF(p_resultado->>'cdr_path', ''), cdr_path),
    pdf_path = COALESCE(NULLIF(p_resultado->>'pdf_path', ''), pdf_path),
    hash_documento = COALESCE(NULLIF(p_resultado->>'hash_documento', ''), hash_documento),
    codigo_sunat = COALESCE(NULLIF(p_resultado->>'codigo_sunat', ''), codigo_sunat),
    descripcion_sunat = COALESCE(NULLIF(p_resultado->>'descripcion_sunat', ''), v_mensaje, descripcion_sunat),
    observaciones_sunat = COALESCE(p_resultado->'observaciones_sunat', observaciones_sunat),
    archivo_nombre_base = COALESCE(NULLIF(p_resultado->>'archivo_nombre_base', ''), archivo_nombre_base),
    ticket_sunat = COALESCE(NULLIF(p_resultado->>'ticket_sunat', ''), ticket_sunat),
    ultimo_error_tipo = CASE
      WHEN v_estado = 'aceptado' THEN NULL
      ELSE COALESCE(NULLIF(p_resultado->>'error_tipo', ''), ultimo_error_tipo)
    END,
    ultimo_http_status = v_codigo_http,
    enviado_at = CASE
      WHEN v_estado IN ('aceptado', 'rechazado', 'resultado_incierto')
        THEN COALESCE(enviado_at, now())
      ELSE enviado_at
    END,
    aceptado_at = CASE
      WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now())
      ELSE aceptado_at
    END,
    pdf_generado_at = CASE
      WHEN NULLIF(p_resultado->>'pdf_path', '') IS NOT NULL THEN now()
      ELSE pdf_generado_at
    END,
    procesando_at = NULL,
    bloqueo_token = NULL,
    bloqueo_expira_at = NULL
  WHERE id = p_nota_credito_id;

  IF v_intento_id IS NOT NULL THEN
    UPDATE public.notas_credito_intentos
    SET
      resultado = v_estado,
      codigo_http = v_codigo_http,
      codigo_error = NULLIF(p_resultado->>'codigo_error', ''),
      mensaje_error = v_mensaje,
      payload_json = COALESCE(p_resultado->'payload_json', payload_json),
      respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
      fecha_fin = now(),
      duracion_ms = COALESCE(
        v_duracion,
        GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (now() - fecha_inicio)) * 1000)::integer)
      )
    WHERE id = v_intento_id;
  END IF;

  IF v_estado = 'aceptado'
     AND v_nota.reponer_stock = true
     AND v_nota.stock_aplicado = false THEN
    v_stock_result := public._aplicar_stock_nota_credito(p_nota_credito_id);
  END IF;

  SELECT
    COALESCE(SUM(nc.total), 0),
    v.total
  INTO v_total_nc, v_venta_total
  FROM public.ventas AS v
  LEFT JOIN public.notas_credito AS nc
    ON nc.venta_id = v.id
   AND nc.estado = 'aceptado'
   AND nc.afecta_dinero = true
   AND COALESCE(nc.estado_baja_tributaria, 'ninguna') <> 'aceptada'
  WHERE v.id = v_nota.venta_id
  GROUP BY v.total;

  UPDATE public.ventas
  SET
    monto_notas_credito = ROUND(COALESCE(v_total_nc, 0), 2),
    estado_tributario = CASE
      WHEN COALESCE(v_total_nc, 0) >= COALESCE(v_venta_total, 0) - 0.02 THEN 'anulada'
      WHEN COALESCE(v_total_nc, 0) > 0.01 THEN 'parcialmente_ajustada'
      ELSE 'vigente'
    END
  WHERE id = v_nota.venta_id;

  RETURN jsonb_build_object(
    'success', true,
    'estado', v_estado,
    'nota_credito_id', p_nota_credito_id,
    'venta_id', v_nota.venta_id,
    'stock_aplicado', CASE
      WHEN v_estado = 'aceptado' THEN (
        SELECT stock_aplicado FROM public.notas_credito
        WHERE id = p_nota_credito_id
      )
      ELSE false
    END,
    'stock_resultado', v_stock_result,
    'stock_error', (
      SELECT stock_error FROM public.notas_credito
      WHERE id = p_nota_credito_id
    )
  );
END;
$$;
ALTER FUNCTION "public"."nota_credito_finalizar"("p_nota_credito_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."notificar_stock_bajo"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_delta_total bigint;
  v_stock_minimo integer;
  v_stock_total_nuevo bigint;
  v_stock_total_viejo bigint;
  v_nombre_producto text;
  v_tipo_venta text;
  v_cantidad_por_caja integer;
  v_tipo_alerta text;
  v_texto_stock text;
  v_cajas bigint;
  v_sueltos bigint;
  v_onesignal_rest_api_key text;
  v_request_id bigint;
  v_cuerpo_json jsonb;
BEGIN
  -- Solo la primera ejecucion diferida por producto consume el acumulador.
  -- Si una transaccion toco varias filas del mismo producto, las siguientes
  -- ejecuciones diferidas no encuentran contexto y terminan sin duplicar aviso.
  DELETE FROM public.stock_alert_tx_context
  WHERE txid = txid_current()
    AND producto_id = NEW.producto_id
  RETURNING delta_total INTO v_delta_total;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  SELECT
    p.stock_minimo,
    p.nombre,
    COALESCE(UPPER(p.tipo_venta), ''),
    GREATEST(COALESCE(p.cantidad_por_caja, 1), 1)
  INTO
    v_stock_minimo,
    v_nombre_producto,
    v_tipo_venta,
    v_cantidad_por_caja
  FROM public.productos AS p
  WHERE p.id = NEW.producto_id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  -- A estas alturas todas las mutaciones de inventario de la transaccion ya
  -- ocurrieron. Este es el total FINAL real, no un estado intermedio.
  SELECT COALESCE(SUM(COALESCE(ia.cantidad, 0)), 0)
  INTO v_stock_total_nuevo
  FROM public.inventario_almacen AS ia
  WHERE ia.producto_id = NEW.producto_id;

  -- delta_total = SUM(OLD.cantidad - NEW.cantidad).
  -- Por tanto: stock_anterior = stock_final + delta_total.
  v_stock_total_viejo := v_stock_total_nuevo + COALESCE(v_delta_total, 0);

  -- AGOTADO tiene prioridad. Asi un salto 13 -> 0 genera una sola alerta
  -- critica y no ademas una alerta de stock bajo.
  IF v_stock_total_viejo > 0
     AND v_stock_total_nuevo <= 0 THEN
    v_tipo_alerta := 'agotado';

  -- STOCK_BAJO solo se emite al cruzar el minimo y mientras quede stock.
  -- Un traslado puro tiene delta 0, por lo que 13 -> 13 nunca entra aqui.
  ELSIF v_stock_minimo IS NOT NULL
     AND v_stock_total_viejo > v_stock_minimo
     AND v_stock_total_nuevo <= v_stock_minimo
     AND v_stock_total_nuevo > 0 THEN
    v_tipo_alerta := 'stock_bajo';
  ELSE
    RETURN NEW;
  END IF;

  IF v_tipo_alerta = 'stock_bajo' THEN
    IF v_tipo_venta IN ('CAJA_PAQUETES', 'CAJA+PAQUETES', 'CAJA + PAQUETES') THEN
      IF v_cantidad_por_caja <= 1 THEN
        v_texto_stock := v_stock_total_nuevo ||
          CASE WHEN v_stock_total_nuevo = 1 THEN ' paquete' ELSE ' paquetes' END;
      ELSE
        v_cajas := v_stock_total_nuevo / v_cantidad_por_caja;
        v_sueltos := v_stock_total_nuevo % v_cantidad_por_caja;
        IF v_cajas = 0 THEN
          v_texto_stock := v_sueltos ||
            CASE WHEN v_sueltos = 1 THEN ' paquete' ELSE ' paquetes' END;
        ELSIF v_sueltos = 0 THEN
          v_texto_stock := v_cajas ||
            CASE WHEN v_cajas = 1 THEN ' caja' ELSE ' cajas' END;
        ELSE
          v_texto_stock :=
            v_cajas || CASE WHEN v_cajas = 1 THEN ' caja y ' ELSE ' cajas y ' END ||
            v_sueltos || CASE WHEN v_sueltos = 1 THEN ' paquete' ELSE ' paquetes' END;
        END IF;
      END IF;
    ELSIF v_tipo_venta IN (
      'CAJA_UNIDADES', 'CAJA+UNIDADES', 'CAJA + UNIDADES',
      'AMBOS', 'CAJA_UNIDAD', 'CAJAS_UNIDADES'
    ) THEN
      IF v_cantidad_por_caja <= 1 THEN
        v_texto_stock := v_stock_total_nuevo ||
          CASE WHEN v_stock_total_nuevo = 1 THEN ' unidad' ELSE ' unidades' END;
      ELSE
        v_cajas := v_stock_total_nuevo / v_cantidad_por_caja;
        v_sueltos := v_stock_total_nuevo % v_cantidad_por_caja;
        IF v_cajas = 0 THEN
          v_texto_stock := v_sueltos ||
            CASE WHEN v_sueltos = 1 THEN ' unidad' ELSE ' unidades' END;
        ELSIF v_sueltos = 0 THEN
          v_texto_stock := v_cajas ||
            CASE WHEN v_cajas = 1 THEN ' caja' ELSE ' cajas' END;
        ELSE
          v_texto_stock :=
            v_cajas || CASE WHEN v_cajas = 1 THEN ' caja y ' ELSE ' cajas y ' END ||
            v_sueltos || CASE WHEN v_sueltos = 1 THEN ' unidad' ELSE ' unidades' END;
        END IF;
      END IF;
    ELSIF v_tipo_venta IN ('PAQUETES', 'PAQUETE') THEN
      v_texto_stock := v_stock_total_nuevo ||
        CASE WHEN v_stock_total_nuevo = 1 THEN ' paquete' ELSE ' paquetes' END;
    ELSIF v_tipo_venta IN ('CAJA', 'SOLO_CAJAS') THEN
      v_texto_stock := v_stock_total_nuevo ||
        CASE WHEN v_stock_total_nuevo = 1 THEN ' caja' ELSE ' cajas' END;
    ELSE
      v_texto_stock := v_stock_total_nuevo ||
        CASE WHEN v_stock_total_nuevo = 1 THEN ' unidad' ELSE ' unidades' END;
    END IF;
  END IF;

  -- El secreto no debe vivir en Git. Si Vault no esta configurado, una alerta
  -- nunca debe hacer fallar la venta/traslado que origino el cambio de stock.
  BEGIN
    SELECT ds.decrypted_secret
    INTO v_onesignal_rest_api_key
    FROM vault.decrypted_secrets AS ds
    WHERE ds.name = 'onesignal_rest_api_key'
    ORDER BY ds.created_at DESC
    LIMIT 1;
  EXCEPTION
    WHEN undefined_table OR insufficient_privilege THEN
      RAISE WARNING 'OneSignal Vault no esta disponible; se omite alerta de stock.';
      RETURN NEW;
  END;

  IF NULLIF(TRIM(v_onesignal_rest_api_key), '') IS NULL THEN
    RAISE WARNING 'Falta el secreto onesignal_rest_api_key en Vault; se omite alerta de stock.';
    RETURN NEW;
  END IF;

  IF v_tipo_alerta = 'agotado' THEN
    v_cuerpo_json := jsonb_build_object(
      'app_id', '1db60a45-72fc-40eb-bc77-42eac4c83356',
      'target_channel', 'push',
      'included_segments', jsonb_build_array('All'),
      'headings', jsonb_build_object(
        'en',
        chr(128680) || ' ' || chr(161) || 'Producto Agotado!'
      ),
      'contents', jsonb_build_object(
        'en',
        'El producto "' || v_nombre_producto ||
        '" se ha quedado sin stock (0). ' || chr(161) || 'Revisar inventario!'
      ),
      'data', jsonb_build_object(
        'stock_alert_type', 'agotado',
        'producto_id', NEW.producto_id
      )
    );
  ELSE
    v_cuerpo_json := jsonb_build_object(
      'app_id', '1db60a45-72fc-40eb-bc77-42eac4c83356',
      'target_channel', 'push',
      'included_segments', jsonb_build_array('All'),
      'headings', jsonb_build_object(
        'en',
        chr(9888) || chr(65039) || ' Alerta de Stock Bajo'
      ),
      'contents', jsonb_build_object(
        'en',
        'El producto "' || v_nombre_producto ||
        '" est' || chr(225) || ' por agotarse. Quedan solo ' ||
        v_texto_stock || ' en total.'
      ),
      'data', jsonb_build_object(
        'stock_alert_type', 'stock_bajo',
        'producto_id', NEW.producto_id
      )
    );
  END IF;

  BEGIN
    SELECT net.http_post(
      url := 'https://api.onesignal.com/notifications',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Key ' || v_onesignal_rest_api_key
      ),
      body := v_cuerpo_json
    )
    INTO v_request_id;
  EXCEPTION
    WHEN OTHERS THEN
      -- La notificacion es secundaria: nunca debe revertir stock/Kardex/venta.
      RAISE WARNING 'No se pudo encolar la alerta de stock para producto %.', NEW.producto_id;
  END;

  RETURN NEW;
END;
$$;
ALTER FUNCTION "public"."notificar_stock_bajo"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."obtener_disponibilidad_nota_credito"("p_comprobante_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_comp record;
  v_detalles jsonb;
  v_notas jsonb;
  v_total_comprometido numeric(14,2);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT public.app_empleado_activo() THEN
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
$$;
ALTER FUNCTION "public"."obtener_disponibilidad_nota_credito"("p_comprobante_id" "uuid") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."obtener_tendencia_movimientos"("p_tipo" "text", "p_inicio" timestamp with time zone, "p_fin" timestamp with time zone) RETURNS TABLE("fecha_agrupada" "date", "total" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado: empleado no autenticado o inactivo.';
  END IF;

  RETURN QUERY
  SELECT
    DATE(m.fecha AT TIME ZONE 'America/Lima') AS fecha_agrupada,
    SUM(m.monto) AS total
  FROM public.movimientos AS m
  WHERE m.tipo = p_tipo
    AND m.fecha >= p_inicio
    AND m.fecha <= p_fin
  GROUP BY DATE(m.fecha AT TIME ZONE 'America/Lima')
  ORDER BY fecha_agrupada ASC;
END;
$$;
ALTER FUNCTION "public"."obtener_tendencia_movimientos"("p_tipo" "text", "p_inicio" timestamp with time zone, "p_fin" timestamp with time zone) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."procesar_pago_deuda"("p_es_cliente" boolean, "p_deuda_id" bigint, "p_monto" numeric, "p_metodo" "text", "p_fecha" timestamp without time zone, "p_descontar_de_caja" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_empleado_id  bigint;
  v_empleado_rol text;

  -- Venta (cobro a cliente)
  v_venta        public.ventas%ROWTYPE;
  v_saldo_venta  numeric(14,2);

  -- Gasto (pago a proveedor)
  v_gasto_total  numeric(14,2);
  v_gasto_saldo  numeric(14,2);
  v_nuevo_saldo  numeric(14,2);

  -- Caja / movimientos
  v_metodo_norm  text;
  v_es_efectivo  boolean;
  v_sesion_caja  uuid;
BEGIN
  -- -------------------------------------------------------------------------
  -- 1. AUTENTICACIÓN Y ROL
  -- -------------------------------------------------------------------------
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  SELECT e.id, LOWER(COALESCE(e.rol, ''))
  INTO v_empleado_id, v_empleado_rol
  FROM public.empleados AS e
  WHERE e.auth_id = auth.uid()
    AND COALESCE(e.activo, false) = true
    AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'operador')
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Empleado inactivo o rol no autorizado para registrar pagos';
  END IF;

  -- -------------------------------------------------------------------------
  -- 2. VALIDACIONES BÁSICAS
  -- -------------------------------------------------------------------------
  p_monto := ROUND(COALESCE(p_monto, 0), 2);

  IF p_monto <= 0 THEN
    RAISE EXCEPTION 'El monto del pago debe ser mayor a cero';
  END IF;

  v_metodo_norm := LOWER(TRIM(COALESCE(p_metodo, '')));

  IF v_metodo_norm = '' THEN
    RAISE EXCEPTION 'El método de pago es obligatorio';
  END IF;

  v_es_efectivo := v_metodo_norm = 'efectivo';

  -- -------------------------------------------------------------------------
  -- 2B. VALIDAR CAJA ABIERTA
  --   • Cobros al cliente en efectivo: SIEMPRE requiere caja abierta.
  --   • Pagos al proveedor: solo si el usuario eligió descontar de caja.
  -- -------------------------------------------------------------------------
  IF v_es_efectivo AND (p_es_cliente OR COALESCE(p_descontar_de_caja, false)) THEN
    SELECT sc.id
    INTO v_sesion_caja
    FROM public.sesiones_caja AS sc
    WHERE sc.estado = 'ABIERTA'
    ORDER BY sc.fecha_apertura DESC
    LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'La caja está cerrada. Ábrela antes de registrar este movimiento en efectivo.';
    END IF;
  END IF;

  -- -------------------------------------------------------------------------
  -- 3A. COBRO A CLIENTE (venta a crédito)
  -- -------------------------------------------------------------------------
  IF p_es_cliente THEN

    SELECT *
    INTO v_venta
    FROM public.ventas
    WHERE id = p_deuda_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'La venta % no existe', p_deuda_id;
    END IF;

    IF LOWER(COALESCE(v_venta.estado, '')) NOT IN ('pendiente') THEN
      RAISE EXCEPTION 'La venta % ya está pagada o no permite abonos', p_deuda_id;
    END IF;

    v_saldo_venta := ROUND(COALESCE(v_venta.saldo, 0), 2);

    IF p_monto > v_saldo_venta + 0.01 THEN
      RAISE EXCEPTION
        'El abono (%) supera el saldo pendiente (%)',
        p_monto, v_saldo_venta;
    END IF;

    -- Insertar pago
    INSERT INTO public.pagos_venta (venta_id, metodo, monto, fecha)
    VALUES (p_deuda_id, TRIM(p_metodo), p_monto, COALESCE(p_fecha, (now() AT TIME ZONE 'America/Lima')) AT TIME ZONE 'America/Lima');

    -- Recalcular saldo desde pagos reales (evita drift acumulado)
    SELECT GREATEST(
      ROUND(COALESCE(v_venta.total, 0) - COALESCE(SUM(pv.monto), 0), 2),
      0
    )
    INTO v_saldo_venta
    FROM public.pagos_venta AS pv
    WHERE pv.venta_id = p_deuda_id;

    UPDATE public.ventas
    SET
      saldo  = v_saldo_venta,
      estado = CASE
        WHEN v_saldo_venta <= 0.01 THEN 'pagado'
        ELSE 'pendiente'
      END
    WHERE id = p_deuda_id;

    RETURN jsonb_build_object(
      'success',  true,
      'tipo',     'cobro_cliente',
      'deuda_id', p_deuda_id,
      'monto',    p_monto,
      'saldo',    v_saldo_venta
    );

  -- -------------------------------------------------------------------------
  -- 3B. PAGO A PROVEEDOR (gasto a crédito)
  -- -------------------------------------------------------------------------
  ELSE

    SELECT
      ROUND(COALESCE(g.saldo, 0), 2)
    INTO v_gasto_saldo
    FROM public.gastos AS g
    WHERE g.id = p_deuda_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'El gasto % no existe', p_deuda_id;
    END IF;

    IF p_monto > v_gasto_saldo + 0.01 THEN
      RAISE EXCEPTION
        'El pago (%) supera el saldo pendiente del gasto (%)',
        p_monto, v_gasto_saldo;
    END IF;

    -- Insertar pago (¡AQUÍ ESTABA EL ERROR, AHORA INCLUYE afecta_caja_chica!)
    INSERT INTO public.pagos_gasto (gasto_id, metodo, monto, fecha, afecta_caja_chica)
    VALUES (
      p_deuda_id, 
      TRIM(p_metodo), 
      p_monto, 
      COALESCE(p_fecha, (now() AT TIME ZONE 'America/Lima')) AT TIME ZONE 'America/Lima',
      COALESCE(p_descontar_de_caja, false)
    );

    -- Recalcular saldo real
    v_nuevo_saldo := GREATEST(ROUND(v_gasto_saldo - p_monto, 2), 0);

    UPDATE public.gastos
    SET
      saldo  = v_nuevo_saldo,
      estado = CASE
        WHEN v_nuevo_saldo <= 0.01 THEN 'pagado'
        ELSE 'pendiente'
      END
    WHERE id = p_deuda_id;

    RETURN jsonb_build_object(
      'success',  true,
      'tipo',     'pago_proveedor',
      'deuda_id', p_deuda_id,
      'monto',    p_monto,
      'saldo',    v_nuevo_saldo
    );

  END IF;
END;
$$;
ALTER FUNCTION "public"."procesar_pago_deuda"("p_es_cliente" boolean, "p_deuda_id" bigint, "p_monto" numeric, "p_metodo" "text", "p_fecha" timestamp without time zone, "p_descontar_de_caja" boolean) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."procesar_pago_deuda_v2"("p_request_id" "uuid", "p_es_cliente" boolean, "p_deuda_id" bigint, "p_monto" numeric, "p_metodo" "text", "p_fecha" timestamp with time zone, "p_descontar_de_caja" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_auth_user_id uuid;
  v_empleado_id bigint;
  v_monto numeric(14,2);
  v_metodo text;
  v_metodo_norm text;
  v_fecha timestamptz;
  v_descontar_de_caja boolean;
  v_es_efectivo boolean;

  v_sesion public.sesiones_caja%ROWTYPE;
  v_ingresos_efectivo numeric := 0;
  v_egresos_gastos numeric := 0;
  v_egresos_personal numeric := 0;
  v_saldo_disponible numeric := 0;

  v_request public.pagos_deuda_requests%ROWTYPE;
  v_inserted integer := 0;
  v_resultado jsonb;
  v_pago_id bigint;

  v_venta public.ventas%ROWTYPE;
  v_saldo_venta numeric(14,2);
  v_gasto_saldo numeric(14,2);
  v_nuevo_saldo numeric(14,2);
BEGIN
  v_auth_user_id := auth.uid();
  IF v_auth_user_id IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'request_id es obligatorio';
  END IF;

  IF p_es_cliente IS NULL THEN
    RAISE EXCEPTION 'El tipo de deuda es obligatorio';
  END IF;

  IF p_deuda_id IS NULL THEN
    RAISE EXCEPTION 'La deuda es obligatoria';
  END IF;

  SELECT e.id
  INTO v_empleado_id
  FROM public.empleados AS e
  WHERE e.auth_id = v_auth_user_id
    AND COALESCE(e.activo, false) = true
    AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'operador')
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Empleado inactivo o rol no autorizado para registrar pagos';
  END IF;

  v_monto := ROUND(COALESCE(p_monto, 0), 2);
  IF v_monto <= 0 THEN
    RAISE EXCEPTION 'El monto del pago debe ser mayor a cero';
  END IF;

  v_metodo := TRIM(COALESCE(p_metodo, ''));
  IF v_metodo = '' THEN
    RAISE EXCEPTION 'El metodo de pago es obligatorio';
  END IF;

  v_metodo_norm := LOWER(v_metodo);
  v_fecha := COALESCE(p_fecha, now());
  v_es_efectivo := v_metodo_norm = 'efectivo';

  v_descontar_de_caja :=
    COALESCE(p_descontar_de_caja, false)
    AND NOT p_es_cliente
    AND v_es_efectivo;

  INSERT INTO public.pagos_deuda_requests (
    request_id,
    auth_user_id,
    empleado_id,
    es_cliente,
    deuda_id,
    monto,
    metodo,
    descontar_de_caja
  ) VALUES (
    p_request_id,
    v_auth_user_id,
    v_empleado_id,
    p_es_cliente,
    p_deuda_id,
    v_monto,
    v_metodo_norm,
    v_descontar_de_caja
  )
  ON CONFLICT (request_id) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT *
    INTO v_request
    FROM public.pagos_deuda_requests
    WHERE request_id = p_request_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'No se pudo recuperar la solicitud idempotente';
    END IF;

    IF v_request.auth_user_id IS DISTINCT FROM v_auth_user_id
       OR v_request.es_cliente IS DISTINCT FROM p_es_cliente
       OR v_request.deuda_id IS DISTINCT FROM p_deuda_id
       OR v_request.monto IS DISTINCT FROM v_monto
       OR v_request.metodo IS DISTINCT FROM v_metodo_norm
       OR v_request.descontar_de_caja IS DISTINCT FROM v_descontar_de_caja THEN
      RAISE EXCEPTION 'request_id reutilizado con datos de pago diferentes';
    END IF;

    IF v_request.resultado IS NULL THEN
      RAISE EXCEPTION 'La solicitud de pago no tiene un resultado confirmado';
    END IF;

    RETURN v_request.resultado || jsonb_build_object('idempotent', true);
  END IF;

  IF v_es_efectivo AND p_es_cliente THEN
    SELECT sc.*
    INTO v_sesion
    FROM public.sesiones_caja AS sc
    WHERE sc.estado = 'ABIERTA'
    ORDER BY sc.fecha_apertura DESC
    LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'La caja esta cerrada. Abrela antes de registrar este cobro en efectivo.';
    END IF;

    IF v_fecha < v_sesion.fecha_apertura THEN
      RAISE EXCEPTION 'La fecha del cobro en efectivo no puede ser anterior a la apertura de la caja.';
    END IF;
  END IF;

  IF v_descontar_de_caja THEN
    SELECT sc.*
    INTO v_sesion
    FROM public.sesiones_caja AS sc
    WHERE sc.estado = 'ABIERTA'
    ORDER BY sc.fecha_apertura DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'La caja esta cerrada. Abrela antes de descontar dinero en efectivo.';
    END IF;

    IF v_fecha < v_sesion.fecha_apertura THEN
      RAISE EXCEPTION 'La fecha del pago que afecta Caja Chica no puede ser anterior a la apertura de la caja.';
    END IF;

    SELECT COALESCE(SUM(pv.monto), 0)
    INTO v_ingresos_efectivo
    FROM public.pagos_venta AS pv
    WHERE pv.fecha >= v_sesion.fecha_apertura
      AND TRIM(UPPER(pv.metodo)) LIKE '%EFECTIVO%';

    SELECT COALESCE(SUM(pg.monto), 0)
    INTO v_egresos_gastos
    FROM public.pagos_gasto AS pg
    WHERE pg.fecha >= v_sesion.fecha_apertura
      AND TRIM(UPPER(pg.metodo)) LIKE '%EFECTIVO%'
      AND COALESCE(pg.afecta_caja_chica, false) = true;

    SELECT COALESCE(SUM(pe.monto), 0)
    INTO v_egresos_personal
    FROM public.pagos_empleados AS pe
    WHERE pe.fecha >= v_sesion.fecha_apertura
      AND TRIM(UPPER(pe.metodo)) LIKE '%EFECTIVO%'
      AND COALESCE(pe.afecta_caja_chica, false) = true;

    v_saldo_disponible :=
      v_sesion.monto_apertura
      + v_ingresos_efectivo
      - v_egresos_gastos
      - v_egresos_personal;

    IF v_monto > v_saldo_disponible + 0.000001 THEN
      RAISE EXCEPTION
        'Saldo insuficiente en Caja Chica. Disponible: S/ %, solicitado: S/ %.',
        round(v_saldo_disponible, 2), round(v_monto, 2);
    END IF;
  END IF;

  IF p_es_cliente THEN
    SELECT *
    INTO v_venta
    FROM public.ventas
    WHERE id = p_deuda_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'La venta % no existe', p_deuda_id;
    END IF;

    IF LOWER(COALESCE(v_venta.estado, '')) <> 'pendiente' THEN
      RAISE EXCEPTION 'La venta % ya esta pagada o no permite abonos', p_deuda_id;
    END IF;

    v_saldo_venta := ROUND(COALESCE(v_venta.saldo, 0), 2);
    IF v_monto > v_saldo_venta + 0.01 THEN
      RAISE EXCEPTION 'El abono (%) supera el saldo pendiente (%)', v_monto, v_saldo_venta;
    END IF;

    INSERT INTO public.pagos_venta (venta_id, metodo, monto, fecha, request_id)
    VALUES (p_deuda_id, v_metodo, v_monto, v_fecha, p_request_id)
    RETURNING id INTO v_pago_id;

    SELECT GREATEST(
      ROUND(COALESCE(v_venta.total, 0) - COALESCE(SUM(pv.monto), 0), 2),
      0
    )
    INTO v_saldo_venta
    FROM public.pagos_venta AS pv
    WHERE pv.venta_id = p_deuda_id;

    UPDATE public.ventas
    SET saldo = v_saldo_venta,
        estado = CASE WHEN v_saldo_venta <= 0.01 THEN 'pagado' ELSE 'pendiente' END
    WHERE id = p_deuda_id;

    v_resultado := jsonb_build_object(
      'success', true,
      'idempotent', false,
      'request_id', p_request_id,
      'tipo', 'cobro_cliente',
      'deuda_id', p_deuda_id,
      'pago_id', v_pago_id,
      'monto', v_monto,
      'saldo', v_saldo_venta
    );
  ELSE
    SELECT ROUND(COALESCE(g.saldo, 0), 2)
    INTO v_gasto_saldo
    FROM public.gastos AS g
    WHERE g.id = p_deuda_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'El gasto % no existe', p_deuda_id;
    END IF;

    IF v_monto > v_gasto_saldo + 0.01 THEN
      RAISE EXCEPTION 'El pago (%) supera el saldo pendiente del gasto (%)', v_monto, v_gasto_saldo;
    END IF;

    INSERT INTO public.pagos_gasto (
      gasto_id, metodo, monto, fecha, afecta_caja_chica, request_id
    ) VALUES (
      p_deuda_id, v_metodo, v_monto, v_fecha, v_descontar_de_caja, p_request_id
    )
    RETURNING id INTO v_pago_id;

    v_nuevo_saldo := GREATEST(ROUND(v_gasto_saldo - v_monto, 2), 0);

    UPDATE public.gastos
    SET saldo = v_nuevo_saldo,
        estado = CASE WHEN v_nuevo_saldo <= 0.01 THEN 'pagado' ELSE 'pendiente' END
    WHERE id = p_deuda_id;

    v_resultado := jsonb_build_object(
      'success', true,
      'idempotent', false,
      'request_id', p_request_id,
      'tipo', 'pago_proveedor',
      'deuda_id', p_deuda_id,
      'pago_id', v_pago_id,
      'monto', v_monto,
      'saldo', v_nuevo_saldo
    );
  END IF;

  UPDATE public.pagos_deuda_requests
  SET resultado = v_resultado, completed_at = now()
  WHERE request_id = p_request_id;

  RETURN v_resultado;
END;
$$;
ALTER FUNCTION "public"."procesar_pago_deuda_v2"("p_request_id" "uuid", "p_es_cliente" boolean, "p_deuda_id" bigint, "p_monto" numeric, "p_metodo" "text", "p_fecha" timestamp with time zone, "p_descontar_de_caja" boolean) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."process_sale_v3"("p_request_id" "uuid", "p_cliente_id" bigint, "p_total" numeric, "p_fecha" timestamp with time zone, "p_es_credito" boolean, "p_monto_abono" numeric, "p_detalles" "jsonb", "p_pagos" "jsonb", "p_cotizacion_id" bigint, "p_vendedor_id" bigint, "p_tipo_comprobante" "text", "p_descuento_global_porcentaje" numeric, "p_descuento_global_monto" numeric, "p_motivo_descuento" "text", "p_subtotal_bruto" numeric, "p_descuento_autorizado_por" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $_$
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
$_$;
ALTER FUNCTION "public"."process_sale_v3"("p_request_id" "uuid", "p_cliente_id" bigint, "p_total" numeric, "p_fecha" timestamp with time zone, "p_es_credito" boolean, "p_monto_abono" numeric, "p_detalles" "jsonb", "p_pagos" "jsonb", "p_cotizacion_id" bigint, "p_vendedor_id" bigint, "p_tipo_comprobante" "text", "p_descuento_global_porcentaje" numeric, "p_descuento_global_monto" numeric, "p_motivo_descuento" "text", "p_subtotal_bruto" numeric, "p_descuento_autorizado_por" bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."reactivar_almacen_seguro_v1"("p_almacen_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_almacen public.almacenes%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Usuario no autenticado';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.empleados AS e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND LOWER(COALESCE(e.rol, '')) = 'admin'
  ) THEN
    RAISE EXCEPTION 'Solo un administrador activo puede reactivar almacenes';
  END IF;

  SELECT * INTO v_almacen
  FROM public.almacenes
  WHERE id = p_almacen_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Almacen no encontrado';
  END IF;

  IF COALESCE(v_almacen.activo, false) = true THEN
    RETURN jsonb_build_object('success', true, 'idempotent', true, 'almacen_id', p_almacen_id, 'activo', true);
  END IF;

  UPDATE public.almacenes
  SET activo = true, updated_at = now()
  WHERE id = p_almacen_id;

  RETURN jsonb_build_object('success', true, 'idempotent', false, 'almacen_id', p_almacen_id, 'activo', true);
END;
$$;
ALTER FUNCTION "public"."reactivar_almacen_seguro_v1"("p_almacen_id" bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."recalcular_estado_tributario_venta"("p_venta_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_total_nc numeric(14,2);
  v_venta_total numeric(14,2);
  v_estado text;
BEGIN
  SELECT
    COALESCE(SUM(nc.total), 0),
    v.total
  INTO v_total_nc, v_venta_total
  FROM public.ventas v
  LEFT JOIN public.notas_credito nc
    ON nc.venta_id = v.id
   AND nc.estado = 'aceptado'
   AND nc.afecta_dinero = true
   AND COALESCE(nc.estado_baja_tributaria, 'ninguna') <> 'aceptada'
  WHERE v.id = p_venta_id
  GROUP BY v.total;

  IF v_venta_total IS NULL THEN
    RAISE EXCEPTION 'Venta no encontrada';
  END IF;

  v_estado := CASE
    WHEN COALESCE(v_total_nc, 0) >= COALESCE(v_venta_total, 0) - 0.02
      THEN 'anulada'
    WHEN COALESCE(v_total_nc, 0) > 0.01
      THEN 'parcialmente_ajustada'
    ELSE 'vigente'
  END;

  UPDATE public.ventas
  SET
    monto_notas_credito = ROUND(COALESCE(v_total_nc, 0), 2),
    estado_tributario = v_estado
  WHERE id = p_venta_id;

  RETURN jsonb_build_object(
    'venta_id', p_venta_id,
    'monto_notas_credito', ROUND(COALESCE(v_total_nc, 0), 2),
    'estado_tributario', v_estado
  );
END;
$$;
ALTER FUNCTION "public"."recalcular_estado_tributario_venta"("p_venta_id" bigint) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."registrar_gasto"("p_proveedor_id" bigint, "p_categoria" "text", "p_monto_total" numeric, "p_abono_inicial" numeric, "p_descripcion" "text", "p_metodo_pago" "text", "p_fecha" timestamp with time zone, "p_afecta_caja_chica" boolean DEFAULT false) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_pagos jsonb := '[]'::jsonb;
BEGIN
  IF COALESCE(p_abono_inicial, 0) < 0 THEN
    RAISE EXCEPTION 'El abono inicial no puede ser negativo.';
  END IF;

  IF COALESCE(p_abono_inicial, 0) > 0 THEN
    v_pagos := jsonb_build_array(
      jsonb_build_object(
        'metodo', p_metodo_pago,
        'monto', p_abono_inicial,
        'afecta_caja_chica', COALESCE(p_afecta_caja_chica, false)
      )
    );
  END IF;

  RETURN public.registrar_gasto_mixto(
    p_proveedor_id,
    p_categoria,
    p_monto_total,
    p_descripcion,
    p_fecha,
    v_pagos
  );
END;
$$;
ALTER FUNCTION "public"."registrar_gasto"("p_proveedor_id" bigint, "p_categoria" "text", "p_monto_total" numeric, "p_abono_inicial" numeric, "p_descripcion" "text", "p_metodo_pago" "text", "p_fecha" timestamp with time zone, "p_afecta_caja_chica" boolean) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."registrar_gasto_mixto"("p_proveedor_id" bigint, "p_categoria" "text", "p_monto_total" numeric, "p_descripcion" "text", "p_fecha" timestamp with time zone, "p_pagos_json" "jsonb") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_saldo_restante numeric;
  v_estado text;
  v_gasto_id bigint;
  v_total_pagado numeric := 0;
  v_salida_caja numeric := 0;
  v_pago jsonb;
  v_monto numeric;
  v_metodo text;
  v_afecta_caja boolean;
  v_fecha timestamp with time zone := COALESCE(p_fecha, now());
  v_sesion public.sesiones_caja%ROWTYPE;
  v_ingresos numeric := 0;
  v_egresos_gastos numeric := 0;
  v_egresos_personal numeric := 0;
  v_saldo_disponible numeric := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado: empleado no autenticado o inactivo.';
  END IF;

  IF p_monto_total IS NULL OR p_monto_total <= 0 THEN
    RAISE EXCEPTION 'El monto total del gasto debe ser mayor a cero.';
  END IF;

  IF p_pagos_json IS NOT NULL AND jsonb_typeof(p_pagos_json) <> 'array' THEN
    RAISE EXCEPTION 'Los pagos deben enviarse como un arreglo JSON.';
  END IF;

  IF p_pagos_json IS NOT NULL THEN
    FOR v_pago IN SELECT value FROM jsonb_array_elements(p_pagos_json)
    LOOP
      IF jsonb_typeof(v_pago) <> 'object' THEN
        RAISE EXCEPTION 'Cada pago debe ser un objeto JSON.';
      END IF;

      v_monto := COALESCE(NULLIF(v_pago->>'monto', '')::numeric, 0);
      v_metodo := UPPER(TRIM(COALESCE(v_pago->>'metodo', '')));

      IF v_monto <= 0 THEN
        RAISE EXCEPTION 'Todos los pagos deben tener un monto mayor a cero.';
      END IF;

      IF v_metodo = '' THEN
        RAISE EXCEPTION 'Todos los pagos deben indicar un método.';
      END IF;

      v_total_pagado := v_total_pagado + v_monto;
      v_afecta_caja :=
        COALESCE((v_pago->>'afecta_caja_chica')::boolean, false)
        AND v_metodo LIKE '%EFECTIVO%';

      IF v_afecta_caja THEN
        v_salida_caja := v_salida_caja + v_monto;
      END IF;
    END LOOP;
  END IF;

  IF v_total_pagado > p_monto_total + 0.02 THEN
    RAISE EXCEPTION
      'Los pagos (S/ %) superan el monto total del gasto (S/ %).',
      round(v_total_pagado, 2), round(p_monto_total, 2);
  END IF;

  IF v_salida_caja > 0 THEN
    SELECT sc.*
    INTO v_sesion
    FROM public.sesiones_caja AS sc
    WHERE sc.estado = 'ABIERTA'
    ORDER BY sc.fecha_apertura DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'La caja está cerrada. Ábrela antes de descontar dinero en efectivo.';
    END IF;

    IF v_fecha < v_sesion.fecha_apertura THEN
      RAISE EXCEPTION
        'La fecha de un pago que afecta Caja Chica no puede ser anterior a la apertura de la caja.';
    END IF;

    SELECT COALESCE(SUM(pv.monto), 0)
    INTO v_ingresos
    FROM public.pagos_venta AS pv
    WHERE pv.fecha >= v_sesion.fecha_apertura
      AND TRIM(UPPER(pv.metodo)) LIKE '%EFECTIVO%';

    SELECT COALESCE(SUM(pg.monto), 0)
    INTO v_egresos_gastos
    FROM public.pagos_gasto AS pg
    WHERE pg.fecha >= v_sesion.fecha_apertura
      AND TRIM(UPPER(pg.metodo)) LIKE '%EFECTIVO%'
      AND COALESCE(pg.afecta_caja_chica, false) = true;

    SELECT COALESCE(SUM(pe.monto), 0)
    INTO v_egresos_personal
    FROM public.pagos_empleados AS pe
    WHERE pe.fecha >= v_sesion.fecha_apertura
      AND TRIM(UPPER(pe.metodo)) LIKE '%EFECTIVO%'
      AND COALESCE(pe.afecta_caja_chica, false) = true;

    v_saldo_disponible :=
      v_sesion.monto_apertura
      + v_ingresos
      - v_egresos_gastos
      - v_egresos_personal;

    IF v_salida_caja > v_saldo_disponible + 0.000001 THEN
      RAISE EXCEPTION
        'Saldo insuficiente en Caja Chica. Disponible: S/ %, solicitado: S/ %.',
        round(v_saldo_disponible, 2), round(v_salida_caja, 2);
    END IF;
  END IF;

  v_saldo_restante := GREATEST(p_monto_total - v_total_pagado, 0);
  v_estado := CASE WHEN v_saldo_restante <= 0.02 THEN 'pagado' ELSE 'pendiente' END;

  INSERT INTO public.gastos (
    fecha,
    proveedor_id,
    categoria,
    monto,
    descripcion,
    estado,
    saldo
  )
  VALUES (
    v_fecha,
    p_proveedor_id,
    p_categoria,
    p_monto_total,
    p_descripcion,
    v_estado,
    v_saldo_restante
  )
  RETURNING id INTO v_gasto_id;

  IF p_pagos_json IS NOT NULL THEN
    FOR v_pago IN SELECT value FROM jsonb_array_elements(p_pagos_json)
    LOOP
      v_monto := COALESCE(NULLIF(v_pago->>'monto', '')::numeric, 0);
      v_metodo := TRIM(COALESCE(v_pago->>'metodo', ''));
      v_afecta_caja :=
        COALESCE((v_pago->>'afecta_caja_chica')::boolean, false)
        AND UPPER(v_metodo) LIKE '%EFECTIVO%';

      INSERT INTO public.pagos_gasto (
        gasto_id,
        metodo,
        monto,
        fecha,
        afecta_caja_chica
      )
      VALUES (
        v_gasto_id,
        v_metodo,
        v_monto,
        v_fecha,
        v_afecta_caja
      );
    END LOOP;
  END IF;

  RETURN v_gasto_id;
END;
$$;
ALTER FUNCTION "public"."registrar_gasto_mixto"("p_proveedor_id" bigint, "p_categoria" "text", "p_monto_total" numeric, "p_descripcion" "text", "p_fecha" timestamp with time zone, "p_pagos_json" "jsonb") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."registrar_ingreso_mercaderia_v2"("p_request_id" "uuid", "p_producto_id" bigint, "p_fecha" timestamp with time zone, "p_tipo_ingreso" "text", "p_documento" "text", "p_proveedor_id" bigint, "p_observaciones" "text", "p_almacenes" "jsonb", "p_ingreso_costo" numeric, "p_ingreso_p_unit" numeric, "p_ingreso_p_caja" numeric, "p_ingreso_p_c_comp" numeric) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."registrar_ingreso_mercaderia_v2"("p_request_id" "uuid", "p_producto_id" bigint, "p_fecha" timestamp with time zone, "p_tipo_ingreso" "text", "p_documento" "text", "p_proveedor_id" bigint, "p_observaciones" "text", "p_almacenes" "jsonb", "p_ingreso_costo" numeric, "p_ingreso_p_unit" numeric, "p_ingreso_p_caja" numeric, "p_ingreso_p_c_comp" numeric) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."registrar_merma_v2"("p_request_id" "uuid", "p_producto_id" bigint, "p_almacen_id" bigint, "p_cantidad" integer, "p_motivo" "text", "p_fecha" timestamp with time zone DEFAULT "now"()) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."registrar_merma_v2"("p_request_id" "uuid", "p_producto_id" bigint, "p_almacen_id" bigint, "p_cantidad" integer, "p_motivo" "text", "p_fecha" timestamp with time zone) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."registrar_pago_empleado_mixto"("p_empleado_id" bigint, "p_concepto" "text", "p_fecha" timestamp with time zone, "p_pagos_json" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_pago jsonb;
  v_monto numeric;
  v_metodo text;
  v_afecta_caja boolean;
  v_salida_caja numeric := 0;
  v_fecha timestamp with time zone := COALESCE(p_fecha, now());
  v_sesion public.sesiones_caja%ROWTYPE;
  v_ingresos numeric := 0;
  v_egresos_gastos numeric := 0;
  v_egresos_personal numeric := 0;
  v_saldo_disponible numeric := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.app_es_admin() THEN
    RAISE EXCEPTION 'Acceso denegado: solo un administrador activo puede registrar pagos a empleados.';
  END IF;

  IF p_empleado_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.empleados e WHERE e.id = p_empleado_id
  ) THEN
    RAISE EXCEPTION 'El empleado seleccionado no existe.';
  END IF;

  IF NULLIF(TRIM(COALESCE(p_concepto, '')), '') IS NULL THEN
    RAISE EXCEPTION 'El concepto del pago es obligatorio.';
  END IF;

  IF p_pagos_json IS NULL
     OR jsonb_typeof(p_pagos_json) <> 'array'
     OR jsonb_array_length(p_pagos_json) = 0 THEN
    RAISE EXCEPTION 'Debe registrar al menos un pago.';
  END IF;

  FOR v_pago IN SELECT value FROM jsonb_array_elements(p_pagos_json)
  LOOP
    IF jsonb_typeof(v_pago) <> 'object' THEN
      RAISE EXCEPTION 'Cada pago debe ser un objeto JSON.';
    END IF;

    v_monto := COALESCE(NULLIF(v_pago->>'monto', '')::numeric, 0);
    v_metodo := UPPER(TRIM(COALESCE(v_pago->>'metodo', '')));

    IF v_monto <= 0 THEN
      RAISE EXCEPTION 'Todos los pagos deben tener un monto mayor a cero.';
    END IF;

    IF v_metodo = '' THEN
      RAISE EXCEPTION 'Todos los pagos deben indicar un método.';
    END IF;

    v_afecta_caja :=
      COALESCE((v_pago->>'afecta_caja_chica')::boolean, false)
      AND v_metodo LIKE '%EFECTIVO%';

    IF v_afecta_caja THEN
      v_salida_caja := v_salida_caja + v_monto;
    END IF;
  END LOOP;

  IF v_salida_caja > 0 THEN
    SELECT sc.*
    INTO v_sesion
    FROM public.sesiones_caja AS sc
    WHERE sc.estado = 'ABIERTA'
    ORDER BY sc.fecha_apertura DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION
        'La caja está cerrada. Ábrela antes de descontar dinero en efectivo.';
    END IF;

    IF v_fecha < v_sesion.fecha_apertura THEN
      RAISE EXCEPTION
        'La fecha de un pago que afecta Caja Chica no puede ser anterior a la apertura de la caja.';
    END IF;

    SELECT COALESCE(SUM(pv.monto), 0)
    INTO v_ingresos
    FROM public.pagos_venta AS pv
    WHERE pv.fecha >= v_sesion.fecha_apertura
      AND TRIM(UPPER(pv.metodo)) LIKE '%EFECTIVO%';

    SELECT COALESCE(SUM(pg.monto), 0)
    INTO v_egresos_gastos
    FROM public.pagos_gasto AS pg
    WHERE pg.fecha >= v_sesion.fecha_apertura
      AND TRIM(UPPER(pg.metodo)) LIKE '%EFECTIVO%'
      AND COALESCE(pg.afecta_caja_chica, false) = true;

    SELECT COALESCE(SUM(pe.monto), 0)
    INTO v_egresos_personal
    FROM public.pagos_empleados AS pe
    WHERE pe.fecha >= v_sesion.fecha_apertura
      AND TRIM(UPPER(pe.metodo)) LIKE '%EFECTIVO%'
      AND COALESCE(pe.afecta_caja_chica, false) = true;

    v_saldo_disponible :=
      v_sesion.monto_apertura
      + v_ingresos
      - v_egresos_gastos
      - v_egresos_personal;

    IF v_salida_caja > v_saldo_disponible + 0.000001 THEN
      RAISE EXCEPTION
        'Saldo insuficiente en Caja Chica. Disponible: S/ %, solicitado: S/ %.',
        round(v_saldo_disponible, 2), round(v_salida_caja, 2);
    END IF;
  END IF;

  FOR v_pago IN SELECT value FROM jsonb_array_elements(p_pagos_json)
  LOOP
    v_monto := COALESCE(NULLIF(v_pago->>'monto', '')::numeric, 0);
    v_metodo := TRIM(COALESCE(v_pago->>'metodo', ''));
    v_afecta_caja :=
      COALESCE((v_pago->>'afecta_caja_chica')::boolean, false)
      AND UPPER(v_metodo) LIKE '%EFECTIVO%';

    INSERT INTO public.pagos_empleados (
      empleado_id,
      monto,
      concepto,
      metodo,
      fecha,
      afecta_caja_chica
    )
    VALUES (
      p_empleado_id,
      v_monto,
      TRIM(p_concepto),
      v_metodo,
      v_fecha,
      v_afecta_caja
    );
  END LOOP;
END;
$$;
ALTER FUNCTION "public"."registrar_pago_empleado_mixto"("p_empleado_id" bigint, "p_concepto" "text", "p_fecha" timestamp with time zone, "p_pagos_json" "jsonb") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."resolver_resultado_incierto_v1"("p_tipo_documento" "text", "p_documento_id" "uuid", "p_decision" "text", "p_motivo" "text", "p_referencia_externa" "text", "p_usuario_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."resolver_resultado_incierto_v1"("p_tipo_documento" "text", "p_documento_id" "uuid", "p_decision" "text", "p_motivo" "text", "p_referencia_externa" "text", "p_usuario_id" "uuid") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."set_facturacion_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
ALTER FUNCTION "public"."set_facturacion_updated_at"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."set_updated_at_documentos_tributarios"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
ALTER FUNCTION "public"."set_updated_at_documentos_tributarios"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."set_vendedor_observaciones_kardex"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."set_vendedor_observaciones_kardex"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."set_venta_fue_credito"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
    NEW.fue_credito :=
        COALESCE(NEW.fue_credito, false)
        OR COALESCE(NEW.saldo, 0) > 0;

    RETURN NEW;
END;
$$;
ALTER FUNCTION "public"."set_venta_fue_credito"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."solicitar_baja_tributaria_v1"("p_request_id" "uuid", "p_tipo_origen" "text", "p_origen_id" "uuid", "p_motivo" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."solicitar_baja_tributaria_v1"("p_request_id" "uuid", "p_tipo_origen" "text", "p_origen_id" "uuid", "p_motivo" "text") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."sync_dashboard_to_sheets"("p_desde" timestamp with time zone DEFAULT ("now"() - '30 days'::interval), "p_hasta" timestamp with time zone DEFAULT ("now"() + '00:05:00'::interval)) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
    payload jsonb;
    webhook_url text :=
        'https://script.google.com/macros/s/AKfycbxyI5QcN_VXtNnohnpLgMO4vcaiRYKOfr5hpbLhDqYM6kFLg9JiFB2LMH8U2sh38C4/exec';
BEGIN
    WITH kpis AS (
        SELECT
            (
                SELECT count(*)
                FROM public.productos p
                WHERE COALESCE(p.activo, true) = true
            )::bigint AS productos_activos,

            (
                SELECT count(*)
                FROM public.almacenes a
                WHERE COALESCE(a.activo, true) = true
            )::bigint AS almacenes_activos,

            (
                SELECT count(*)
                FROM public.inventario_almacen ia
                WHERE COALESCE(ia.cantidad, 0) <= 0
            )::bigint AS registros_sin_stock,

            (
                SELECT count(*)
                FROM public.inventario_almacen ia
                WHERE COALESCE(ia.cantidad, 0) > 0
            )::bigint AS registros_con_stock,

            (
                SELECT count(*)
                FROM public.inventario_movimientos m
                WHERE m.fecha >= now() - interval '24 hours'
            )::bigint AS movimientos_24h,

            (
                SELECT count(*)
                FROM public.inventario_movimientos m
                WHERE
                    m.fecha >= now() - interval '24 hours'
                    AND COALESCE(m.ingreso_cant, 0) > 0
            )::bigint AS entradas_24h,

            (
                SELECT count(*)
                FROM public.inventario_movimientos m
                WHERE
                    m.fecha >= now() - interval '24 hours'
                    AND COALESCE(m.salida_cant, 0) > 0
            )::bigint AS salidas_24h,

            (
                SELECT COALESCE(sum(m.salida_total), 0)
                FROM public.inventario_movimientos m
                WHERE
                    (p_desde IS NULL OR m.fecha >= p_desde)
                    AND
                    (p_hasta IS NULL OR m.fecha < p_hasta)
                    AND
                    COALESCE(m.salida_total, 0) > 0
            )::numeric AS ventas_periodo
    ),

    stock_almacen AS (
        SELECT
            a.nombre AS almacen,
            count(*) FILTER (
                WHERE COALESCE(ia.cantidad, 0) > 0
            )::bigint AS con_stock,
            count(*) FILTER (
                WHERE COALESCE(ia.cantidad, 0) <= 0
            )::bigint AS sin_stock

        FROM public.almacenes a
        LEFT JOIN public.inventario_almacen ia
            ON ia.almacen_id = a.id

        WHERE COALESCE(a.activo, true) = true

        GROUP BY a.id, a.nombre
        ORDER BY lower(a.nombre)
    ),

    ventas_dia AS (
        SELECT
            (
                date_trunc(
                    'day',
                    m.fecha AT TIME ZONE 'America/Lima'
                )
            )::date AS fecha,

            COALESCE(sum(m.salida_total), 0)::numeric AS total

        FROM public.inventario_movimientos m

        WHERE
            (p_desde IS NULL OR m.fecha >= p_desde)
            AND
            (p_hasta IS NULL OR m.fecha < p_hasta)
            AND
            COALESCE(m.salida_total, 0) > 0

        GROUP BY 1
        ORDER BY 1
    ),

    top_productos AS (
        SELECT
            m.producto_nombre AS producto,
            COALESCE(sum(m.salida_total), 0)::numeric AS total

        FROM public.inventario_movimientos m

        WHERE
            (p_desde IS NULL OR m.fecha >= p_desde)
            AND
            (p_hasta IS NULL OR m.fecha < p_hasta)
            AND
            COALESCE(m.salida_total, 0) > 0

        GROUP BY m.producto_nombre
        ORDER BY total DESC
        LIMIT 10
    )

    SELECT jsonb_build_object(
        'action', 'dashboard',
        'generatedAt', now(),
        'dashboard', jsonb_build_object(
            'generatedAt', now(),
            'periodStart', p_desde,
            'periodEnd', p_hasta,

            'kpis', (
                SELECT jsonb_build_object(
                    'productosActivos', k.productos_activos,
                    'almacenesActivos', k.almacenes_activos,
                    'registrosSinStock', k.registros_sin_stock,
                    'registrosConStock', k.registros_con_stock,
                    'movimientos24h', k.movimientos_24h,
                    'entradas24h', k.entradas_24h,
                    'salidas24h', k.salidas_24h,
                    'ventasPeriodo', k.ventas_periodo
                )
                FROM kpis k
            ),

            'stockPorAlmacen', COALESCE(
                (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'almacen', s.almacen,
                            'conStock', s.con_stock,
                            'sinStock', s.sin_stock
                        )
                        ORDER BY lower(s.almacen)
                    )
                    FROM stock_almacen s
                ),
                '[]'::jsonb
            ),

            'ventasPorDia', COALESCE(
                (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'fecha', v.fecha,
                            'total', v.total
                        )
                        ORDER BY v.fecha
                    )
                    FROM ventas_dia v
                ),
                '[]'::jsonb
            ),

            'topProductos', COALESCE(
                (
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'producto', t.producto,
                            'total', t.total
                        )
                        ORDER BY t.total DESC
                    )
                    FROM top_productos t
                ),
                '[]'::jsonb
            )
        )
    )
    INTO payload;

    PERFORM net.http_post(
        url := webhook_url,
        body := payload,
        headers := jsonb_build_object(
            'Content-Type', 'application/json'
        )
    );
END;
$$;
ALTER FUNCTION "public"."sync_dashboard_to_sheets"("p_desde" timestamp with time zone, "p_hasta" timestamp with time zone) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."sync_inventario_to_sheets"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
    payload jsonb;
    webhook_url text :=
        'https://script.google.com/macros/s/AKfycbxyI5QcN_VXtNnohnpLgMO4vcaiRYKOfr5hpbLhDqYM6kFLg9JiFB2LMH8U2sh38C4/exec';
BEGIN
    WITH base AS (
        SELECT
            ia.producto_id,
            p.nombre AS producto,
            ia.almacen_id,
            a.nombre AS almacen,
            COALESCE(ia.cantidad, 0) AS cantidad,

            GREATEST(
                COALESCE(
                    NULLIF(p.cantidad_por_caja, 0),
                    1
                ),
                1
            )::bigint AS pcs,

            CASE
                WHEN upper(trim(COALESCE(p.tipo_venta, 'SOLO_UNIDADES'))) = 'AMBOS'
                    THEN 'ambos'

                WHEN upper(trim(COALESCE(p.tipo_venta, ''))) IN (
                    'SOLO_CAJAS',
                    'SOLO_CAJA',
                    'CAJAS',
                    'CAJA'
                )
                    THEN 'solo_cajas'

                ELSE 'solo_unidades'
            END AS tipo_venta

        FROM public.inventario_almacen ia
        INNER JOIN public.productos p
            ON p.id = ia.producto_id
        INNER JOIN public.almacenes a
            ON a.id = ia.almacen_id

        WHERE
            COALESCE(p.activo, true) = true
            AND
            COALESCE(a.activo, true) = true
    ),

    formateados AS (
        SELECT
            b.*,

            CASE
                WHEN b.tipo_venta <> 'ambos'
                    THEN trunc(b.cantidad)::bigint::text

                WHEN trunc(b.cantidad)::bigint = 0
                    THEN '0U'

                WHEN trunc(b.cantidad)::bigint < b.pcs
                    THEN trunc(b.cantidad)::bigint::text || 'U'

                WHEN mod(trunc(b.cantidad)::bigint, b.pcs) = 0
                    THEN (
                        trunc(b.cantidad)::bigint / b.pcs
                    )::text || 'C'

                ELSE
                    (
                        trunc(b.cantidad)::bigint / b.pcs
                    )::text
                    || 'C '
                    || mod(
                        trunc(b.cantidad)::bigint,
                        b.pcs
                    )::text
                    || 'U'
            END AS stock_visual

        FROM base b
    )

    SELECT jsonb_build_object(
        'action', 'inventario',
        'generatedAt', now(),
        'inventory',
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'productoId', f.producto_id,
                    'producto', f.producto,
                    'tipoVenta', f.tipo_venta,
                    'pcs', f.pcs,
                    'almacenId', f.almacen_id,
                    'almacen', f.almacen,
                    'cantidad', f.cantidad,
                    'stockVisual', f.stock_visual
                )
                ORDER BY
                    lower(f.producto),
                    lower(f.almacen)
            ),
            '[]'::jsonb
        )
    )
    INTO payload
    FROM formateados f;

    PERFORM net.http_post(
        url := webhook_url,
        body := payload,
        headers := jsonb_build_object(
            'Content-Type', 'application/json'
        )
    );
END;
$$;
ALTER FUNCTION "public"."sync_inventario_to_sheets"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."sync_movimientos_to_sheets"("p_desde" timestamp with time zone DEFAULT ("now"() - '24:00:00'::interval), "p_hasta" timestamp with time zone DEFAULT ("now"() + '00:05:00'::interval)) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
DECLARE
    payload jsonb;
    webhook_url text :=
        'https://script.google.com/macros/s/AKfycbxyI5QcN_VXtNnohnpLgMO4vcaiRYKOfr5hpbLhDqYM6kFLg9JiFB2LMH8U2sh38C4/exec';
BEGIN
    WITH base AS (
        SELECT
            m.id::text AS movimiento_id,
            m.fecha,
            m.producto_id::text AS producto_id,
            m.producto_nombre,
            m.proveedor,

            GREATEST(
                COALESCE(
                    NULLIF(m.pcs, 0),
                    NULLIF(p.cantidad_por_caja, 0),
                    1
                )::bigint,
                1
            ) AS pcs,

            COALESCE(m.ingreso_cant, 0)::bigint AS ingreso_base,
            COALESCE(m.salida_cant, 0)::bigint AS salida_base,

            CASE
                WHEN upper(trim(COALESCE(p.tipo_venta, 'SOLO_UNIDADES'))) IN (
                    'AMBOS',
                    'CAJA_UNIDAD',
                    'CAJAS_UNIDADES',
                    'CAJA + UND',
                    'CAJA+UND'
                ) THEN 'ambos'

                WHEN upper(trim(COALESCE(p.tipo_venta, ''))) IN (
                    'SOLO_CAJAS',
                    'SOLO_CAJA',
                    'CAJAS',
                    'CAJA'
                ) THEN 'solo_cajas'

                ELSE 'solo_unidades'
            END AS tipo_venta,

            m.ingreso_costo,
            m.ingreso_p_unit,
            m.ingreso_p_caja,
            m.ingreso_p_c_comp,

            m.tipo,
            m.salida_cliente,
            m.salida_p_unit,
            m.salida_total,

            m.almacen_nombre,
            m.observaciones

        FROM public.inventario_movimientos m
        LEFT JOIN public.productos p
            ON p.id = m.producto_id

        WHERE
            (p_desde IS NULL OR m.fecha >= p_desde)
            AND
            (p_hasta IS NULL OR m.fecha < p_hasta)
    ),

    cantidades AS (
        SELECT
            b.*,
            (b.ingreso_base > 0) AS es_entrada,
            (b.salida_base > 0) AS es_salida,

            CASE
                WHEN b.ingreso_base > 0 THEN b.ingreso_base
                WHEN b.salida_base > 0 THEN b.salida_base
                ELSE 0
            END AS cantidad_base

        FROM base b
    ),

    formateados AS (
        SELECT
            c.*,

            CASE
                WHEN c.tipo_venta <> 'ambos'
                    THEN c.cantidad_base::text

                WHEN c.cantidad_base = 0
                    THEN '0U'

                WHEN c.cantidad_base < c.pcs
                    THEN c.cantidad_base::text || 'U'

                WHEN mod(c.cantidad_base, c.pcs) = 0
                    THEN (c.cantidad_base / c.pcs)::text || 'C'

                ELSE
                    (c.cantidad_base / c.pcs)::text
                    || 'C '
                    || mod(c.cantidad_base, c.pcs)::text
                    || 'U'
            END AS cantidad_visual,

            CASE
                WHEN c.tipo_venta = 'ambos' THEN 'Caja + Und'
                WHEN c.tipo_venta = 'solo_cajas' THEN 'Caja'
                ELSE 'Und'
            END AS unidad_visual

        FROM cantidades c
    )

    SELECT jsonb_build_object(
        'action', 'movimientos',
        'generatedAt', now(),
        'movements',
        COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'movimientoId', f.movimiento_id,
                    'productoId', f.producto_id,

                    'fecha', f.fecha,
                    'producto', f.producto_nombre,
                    'pcs', f.pcs,
                    'proveedor', f.proveedor,

                    'cantidad', f.cantidad_visual,
                    'cantidadVisual', f.cantidad_visual,
                    'cantidadBase', f.cantidad_base,
                    'ingresoBase', f.ingreso_base,
                    'salidaBase', f.salida_base,

                    'unidad', f.unidad_visual,
                    'unidadVisual', f.unidad_visual,
                    'tipoVenta', f.tipo_venta,

                    'esEntrada', f.es_entrada,
                    'esSalida', f.es_salida,

                    'costo', f.ingreso_costo,
                    'precioUnidad', f.ingreso_p_unit,
                    'precioCaja', f.ingreso_p_caja,
                    'precioCajaCompleta', f.ingreso_p_c_comp,

                    'tipo', f.tipo,
                    'cliente', f.salida_cliente,

                    -- Se conserva el precio histórico por unidad mínima.
                    'precioUnitarioVenta',
                        f.salida_p_unit,
                    'precioUnitarioVentaBase',
                        f.salida_p_unit,

                    'total', f.salida_total,
                    'almacen', f.almacen_nombre,
                    'observaciones', f.observaciones
                )
                ORDER BY f.fecha, f.movimiento_id
            ),
            '[]'::jsonb
        )
    )
    INTO payload
    FROM formateados f;

    IF jsonb_array_length(payload->'movements') > 0 THEN
        PERFORM net.http_post(
            url := webhook_url,
            body := payload,
            headers := jsonb_build_object(
                'Content-Type', 'application/json'
            )
        );
    END IF;
END;
$$;
ALTER FUNCTION "public"."sync_movimientos_to_sheets"("p_desde" timestamp with time zone, "p_hasta" timestamp with time zone) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."trasladar_stock"("p_producto_id" bigint, "p_origen_id" bigint, "p_destino_id" bigint, "p_cantidad" integer, "p_motivo" "text", "p_unidad_label" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  PERFORM public.trasladar_stock_v2(
    p_request_id := gen_random_uuid(),
    p_producto_id := p_producto_id,
    p_origen_id := p_origen_id,
    p_destino_id := p_destino_id,
    p_cantidad := p_cantidad,
    p_motivo := p_motivo,
    p_fecha := now()
  );
END;
$$;
ALTER FUNCTION "public"."trasladar_stock"("p_producto_id" bigint, "p_origen_id" bigint, "p_destino_id" bigint, "p_cantidad" integer, "p_motivo" "text", "p_unidad_label" "text") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."trasladar_stock_v2"("p_request_id" "uuid", "p_producto_id" bigint, "p_origen_id" bigint, "p_destino_id" bigint, "p_cantidad" integer, "p_motivo" "text" DEFAULT NULL::"text", "p_fecha" timestamp with time zone DEFAULT "now"()) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."trasladar_stock_v2"("p_request_id" "uuid", "p_producto_id" bigint, "p_origen_id" bigint, "p_destino_id" bigint, "p_cantidad" integer, "p_motivo" "text", "p_fecha" timestamp with time zone) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."tributario_claim_proceso"("p_proceso_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text" DEFAULT 'emitir'::"text", "p_forzar" boolean DEFAULT false, "p_sistema" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
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
$$;
ALTER FUNCTION "public"."tributario_claim_proceso"("p_proceso_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text", "p_forzar" boolean, "p_sistema" boolean) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."tributario_finalizar_proceso"("p_proceso_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_proceso record;
  v_estado text := lower(trim(COALESCE(p_estado, '')));
  v_intento_id uuid;
  v_codigo_http integer;
  v_duracion integer;
  v_mensaje text;
  v_det record;
  v_stock_result jsonb;
BEGIN
  IF v_estado NOT IN (
    'ticket_pendiente', 'aceptado', 'rechazado',
    'pendiente_reintento', 'resultado_incierto'
  ) THEN
    RAISE EXCEPTION 'Estado final inválido: %', v_estado;
  END IF;

  SELECT * INTO v_proceso
  FROM public.procesos_tributarios
  WHERE id = p_proceso_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Proceso tributario no encontrado'; END IF;

  IF v_proceso.estado = 'aceptado' AND v_estado <> 'aceptado' THEN
    RETURN jsonb_build_object('success', true, 'estado', 'aceptado',
      'idempotent', true, 'ignored_state', v_estado, 'proceso_id', p_proceso_id);
  END IF;

  IF v_proceso.bloqueo_token IS DISTINCT FROM p_bloqueo_token THEN
    IF v_proceso.estado = 'aceptado' AND v_estado = 'aceptado' THEN
      RETURN jsonb_build_object('success', true, 'estado', 'aceptado',
        'idempotent', true, 'proceso_id', p_proceso_id);
    END IF;
    RAISE EXCEPTION 'El bloqueo del proceso ya no es válido';
  END IF;

  v_intento_id := NULLIF(p_resultado->>'intento_id', '')::uuid;
  v_codigo_http := NULLIF(p_resultado->>'codigo_http', '')::integer;
  v_duracion := NULLIF(p_resultado->>'duracion_ms', '')::integer;
  v_mensaje := NULLIF(trim(p_resultado->>'mensaje_error'), '');

  UPDATE public.procesos_tributarios
  SET estado = v_estado,
      payload_json = COALESCE(p_resultado->'payload_json', payload_json),
      respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
      xml_path = COALESCE(NULLIF(p_resultado->>'xml_path', ''), xml_path),
      cdr_path = COALESCE(NULLIF(p_resultado->>'cdr_path', ''), cdr_path),
      pdf_path = COALESCE(NULLIF(p_resultado->>'pdf_path', ''), pdf_path),
      hash_documento = COALESCE(NULLIF(p_resultado->>'hash_documento', ''), hash_documento),
      ticket_sunat = COALESCE(NULLIF(p_resultado->>'ticket_sunat', ''), ticket_sunat),
      codigo_sunat = COALESCE(NULLIF(p_resultado->>'codigo_sunat', ''), codigo_sunat),
      descripcion_sunat = COALESCE(NULLIF(p_resultado->>'descripcion_sunat', ''), v_mensaje, descripcion_sunat),
      observaciones_sunat = COALESCE(p_resultado->'observaciones_sunat', observaciones_sunat),
      ultimo_error_tipo = CASE WHEN v_estado = 'aceptado' THEN NULL
        ELSE COALESCE(NULLIF(p_resultado->>'error_tipo', ''), ultimo_error_tipo) END,
      ultimo_http_status = v_codigo_http,
      enviado_at = CASE WHEN v_estado IN ('ticket_pendiente', 'aceptado', 'rechazado', 'resultado_incierto')
        THEN COALESCE(enviado_at, now()) ELSE enviado_at END,
      consultado_at = CASE WHEN COALESCE((p_resultado->>'fue_consulta')::boolean, false)
        THEN now() ELSE consultado_at END,
      aceptado_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now()) ELSE aceptado_at END,
      pdf_generado_at = CASE WHEN NULLIF(p_resultado->>'pdf_path', '') IS NOT NULL
        THEN now() ELSE pdf_generado_at END,
      procesando_at = NULL, bloqueo_token = NULL, bloqueo_expira_at = NULL
  WHERE id = p_proceso_id;

  IF v_intento_id IS NOT NULL THEN
    UPDATE public.procesos_tributarios_intentos
    SET resultado = v_estado, codigo_http = v_codigo_http,
        codigo_error = NULLIF(p_resultado->>'codigo_error', ''),
        mensaje_error = v_mensaje,
        payload_json = COALESCE(p_resultado->'payload_json', payload_json),
        respuesta_json = COALESCE(p_resultado->'respuesta_json', respuesta_json),
        fecha_fin = now(),
        duracion_ms = COALESCE(v_duracion,
          GREATEST(0, floor(extract(epoch FROM (now() - fecha_inicio)) * 1000)::integer))
    WHERE id = v_intento_id;
  END IF;

  UPDATE public.solicitudes_baja_tributaria
  SET estado = CASE v_estado
      WHEN 'ticket_pendiente' THEN 'ticket_pendiente'
      WHEN 'pendiente_reintento' THEN 'pendiente_reintento'
      WHEN 'resultado_incierto' THEN 'resultado_incierto'
      WHEN 'aceptado' THEN 'aceptada'
      WHEN 'rechazado' THEN 'rechazada'
      ELSE estado END,
      aceptado_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(aceptado_at, now()) ELSE aceptado_at END
  WHERE proceso_id = p_proceso_id;

  UPDATE public.comprobantes_electronicos ce
  SET estado_baja_tributaria = CASE v_estado
      WHEN 'ticket_pendiente' THEN 'ticket_pendiente'
      WHEN 'pendiente_reintento' THEN 'pendiente_reintento'
      WHEN 'resultado_incierto' THEN 'resultado_incierto'
      WHEN 'aceptado' THEN 'aceptada'
      WHEN 'rechazado' THEN 'rechazada'
      ELSE ce.estado_baja_tributaria END,
      baja_aceptada_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(ce.baja_aceptada_at, now()) ELSE ce.baja_aceptada_at END
  FROM public.solicitudes_baja_tributaria s
  WHERE s.proceso_id = p_proceso_id AND s.comprobante_id = ce.id;

  UPDATE public.notas_credito nc
  SET estado_baja_tributaria = CASE v_estado
      WHEN 'ticket_pendiente' THEN 'ticket_pendiente'
      WHEN 'pendiente_reintento' THEN 'pendiente_reintento'
      WHEN 'resultado_incierto' THEN 'resultado_incierto'
      WHEN 'aceptado' THEN 'aceptada'
      WHEN 'rechazado' THEN 'rechazada'
      ELSE nc.estado_baja_tributaria END,
      baja_aceptada_at = CASE WHEN v_estado = 'aceptado' THEN COALESCE(nc.baja_aceptada_at, now()) ELSE nc.baja_aceptada_at END
  FROM public.solicitudes_baja_tributaria s
  WHERE s.proceso_id = p_proceso_id AND s.nota_credito_id = nc.id;

  IF v_estado = 'aceptado' THEN
    UPDATE public.ventas v
    SET estado_tributario = 'baja_tributaria'
    FROM public.solicitudes_baja_tributaria s
    WHERE s.proceso_id = p_proceso_id
      AND s.tipo_origen = 'comprobante'
      AND s.venta_id = v.id;

    FOR v_det IN
      SELECT DISTINCT d.nota_credito_id, d.venta_id
      FROM public.procesos_tributarios_detalles d
      WHERE d.proceso_id = p_proceso_id AND d.nota_credito_id IS NOT NULL
    LOOP
      v_stock_result := public._revertir_stock_nota_credito_por_baja(v_det.nota_credito_id);
      PERFORM public.recalcular_estado_tributario_venta(v_det.venta_id);
    END LOOP;
  END IF;

  RETURN jsonb_build_object('success', true, 'estado', v_estado,
    'proceso_id', p_proceso_id, 'stock_resultado', v_stock_result);
END;
$$;
ALTER FUNCTION "public"."tributario_finalizar_proceso"("p_proceso_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb") OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."tributario_preparar_procesos"("p_tipo_proceso" "text" DEFAULT NULL::"text", "p_usuario_id" "uuid" DEFAULT NULL::"uuid", "p_sistema" boolean DEFAULT false, "p_limite_documentos" integer DEFAULT 500) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_tipo_filtro text := NULLIF(lower(trim(COALESCE(p_tipo_proceso, ''))), '');
  v_grupo record;
  v_proceso_id uuid;
  v_correlativo integer;
  v_identificador text;
  v_prefijo text;
  v_ids jsonb := '[]'::jsonb;
  v_count integer;
BEGIN
  IF v_tipo_filtro IS NOT NULL
     AND v_tipo_filtro NOT IN ('resumen_boletas', 'comunicacion_baja') THEN
    RAISE EXCEPTION 'Tipo de proceso inválido';
  END IF;

  IF COALESCE(p_sistema, false) THEN
    RAISE EXCEPTION 'El procesamiento tributario automático está desactivado';
  END IF;

  IF p_usuario_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.empleados e
      WHERE e.auth_id = p_usuario_id
        AND COALESCE(e.activo, false) = true
        AND lower(COALESCE(e.rol, '')) IN (
          'admin'
        )
  ) THEN
    RAISE EXCEPTION 'Usuario no autorizado para preparar procesos tributarios';
  END IF;

  FOR v_grupo IN
    SELECT s.tipo_proceso, s.fecha_documento
    FROM public.solicitudes_baja_tributaria s
    WHERE s.estado = 'pendiente'
      AND s.proceso_id IS NULL
      AND (v_tipo_filtro IS NULL OR s.tipo_proceso = v_tipo_filtro)
    GROUP BY s.tipo_proceso, s.fecha_documento
    ORDER BY s.fecha_documento, s.tipo_proceso
  LOOP
    PERFORM pg_advisory_xact_lock(
      hashtextextended(
        v_grupo.tipo_proceso || ':' || v_grupo.fecha_documento::text,
        0
      )
    );

    INSERT INTO public.correlativos_procesos_tributarios(
      tipo_proceso, fecha_referencia, ultimo_correlativo
    ) VALUES (
      v_grupo.tipo_proceso, v_grupo.fecha_documento, 1
    )
    ON CONFLICT (tipo_proceso, fecha_referencia)
    DO UPDATE SET
      ultimo_correlativo =
        public.correlativos_procesos_tributarios.ultimo_correlativo + 1,
      updated_at = now()
    RETURNING ultimo_correlativo INTO v_correlativo;

    v_prefijo := CASE
      WHEN v_grupo.tipo_proceso = 'resumen_boletas' THEN 'RC'
      ELSE 'RA'
    END;

    v_identificador :=
      v_prefijo || '-' ||
      to_char(v_grupo.fecha_documento, 'YYYYMMDD') || '-' ||
      lpad(v_correlativo::text, 3, '0');

    INSERT INTO public.procesos_tributarios(
      request_id, tipo_proceso, fecha_referencia, fecha_comunicacion,
      correlativo, identificador, creado_por
    ) VALUES (
      gen_random_uuid(), v_grupo.tipo_proceso, v_grupo.fecha_documento,
      (now() AT TIME ZONE 'America/Lima')::date,
      v_correlativo, v_identificador, p_usuario_id
    )
    RETURNING id INTO v_proceso_id;

    WITH seleccion AS (
      SELECT s.id
      FROM public.solicitudes_baja_tributaria s
      WHERE s.estado = 'pendiente'
        AND s.proceso_id IS NULL
        AND s.tipo_proceso = v_grupo.tipo_proceso
        AND s.fecha_documento = v_grupo.fecha_documento
      ORDER BY s.created_at, s.id
      LIMIT GREATEST(1, LEAST(COALESCE(p_limite_documentos, 500), 500))
      FOR UPDATE SKIP LOCKED
    ), insertados AS (
      INSERT INTO public.procesos_tributarios_detalles(
        proceso_id, solicitud_id, tipo_origen,
        comprobante_id, nota_credito_id, venta_id,
        tipo_doc, serie, correlativo, serie_numero,
        estado_resumen, motivo, moneda,
        cliente_tipo, cliente_numero,
        base_imponible, igv, total
      )
      SELECT
        v_proceso_id, s.id, s.tipo_origen,
        s.comprobante_id, s.nota_credito_id, s.venta_id,
        s.tipo_doc, s.serie, s.correlativo,
        s.serie || '-' || s.correlativo,
        '3', s.motivo, s.moneda,
        COALESCE(NULLIF(s.cliente_tipo, ''), '0'),
        COALESCE(NULLIF(s.cliente_numero, ''), '0'),
        s.base_imponible, s.igv, s.total
      FROM public.solicitudes_baja_tributaria s
      JOIN seleccion x ON x.id = s.id
      RETURNING solicitud_id
    )
    UPDATE public.solicitudes_baja_tributaria s
    SET
      estado = 'agrupada',
      proceso_id = v_proceso_id
    FROM insertados i
    WHERE s.id = i.solicitud_id;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    IF v_count = 0 THEN
      DELETE FROM public.procesos_tributarios
      WHERE id = v_proceso_id;
    ELSE
      UPDATE public.comprobantes_electronicos ce
      SET estado_baja_tributaria = 'agrupada'
      FROM public.solicitudes_baja_tributaria s
      WHERE s.proceso_id = v_proceso_id
        AND s.comprobante_id = ce.id;

      UPDATE public.notas_credito nc
      SET estado_baja_tributaria = 'agrupada'
      FROM public.solicitudes_baja_tributaria s
      WHERE s.proceso_id = v_proceso_id
        AND s.nota_credito_id = nc.id;

      v_ids := v_ids || jsonb_build_array(v_proceso_id);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'procesos_creados', jsonb_array_length(v_ids),
    'proceso_ids', v_ids
  );
END;
$$;
ALTER FUNCTION "public"."tributario_preparar_procesos"("p_tipo_proceso" "text", "p_usuario_id" "uuid", "p_sistema" boolean, "p_limite_documentos" integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."tributario_reintentar_stock_bajas"("p_limite" integer DEFAULT 20) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_nota record;
  v_result jsonb;
  v_total integer := 0;
BEGIN
  FOR v_nota IN
    SELECT id
    FROM public.notas_credito
    WHERE estado_baja_tributaria = 'aceptada'
      AND baja_stock_revertido = false
    ORDER BY baja_stock_ultimo_intento_at NULLS FIRST, created_at
    LIMIT GREATEST(1, LEAST(COALESCE(p_limite, 20), 100))
  LOOP
    v_result := public._revertir_stock_nota_credito_por_baja(v_nota.id);
    v_total := v_total + 1;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'procesadas', v_total);
END;
$$;
ALTER FUNCTION "public"."tributario_reintentar_stock_bajas"("p_limite" integer) OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."validar_origen_nota_credito_vigente"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
DECLARE
  v_estado_baja text;
BEGIN
  SELECT COALESCE(estado_baja_tributaria, 'ninguna')
  INTO v_estado_baja
  FROM public.comprobantes_electronicos
  WHERE id = NEW.comprobante_id;

  IF v_estado_baja IS DISTINCT FROM 'ninguna' THEN
    RAISE EXCEPTION
      'No se puede emitir una nota: el comprobante original tiene una baja tributaria en estado %',
      v_estado_baja;
  END IF;

  RETURN NEW;
END;
$$;
ALTER FUNCTION "public"."validar_origen_nota_credito_vigente"() OWNER TO "postgres";
CREATE OR REPLACE FUNCTION "public"."vincular_usuario_empleado"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
  UPDATE empleados
  SET auth_id = NEW.id
  WHERE email = NEW.email AND auth_id IS NULL;

  RETURN NEW;
END;
$$;
ALTER FUNCTION "public"."vincular_usuario_empleado"() OWNER TO "postgres";
SET default_tablespace = '';
SET default_table_access_method = "heap";
CREATE TABLE IF NOT EXISTS "public"."almacenes" (
    "id" bigint NOT NULL,
    "nombre" "text" NOT NULL,
    "direccion" "text",
    "activo" boolean DEFAULT true,
    "ubigeo" "text",
    "departamento" "text",
    "provincia" "text",
    "distrito" "text",
    "cod_local" "text" DEFAULT '0000'::"text",
    "referencia" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "almacenes_ubigeo_formato_check" CHECK ((("ubigeo" IS NULL) OR ("ubigeo" ~ '^[0-9]{6}$'::"text")))
);
ALTER TABLE "public"."almacenes" OWNER TO "postgres";
CREATE SEQUENCE IF NOT EXISTS "public"."almacenes_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE "public"."almacenes_id_seq" OWNER TO "postgres";
ALTER SEQUENCE "public"."almacenes_id_seq" OWNED BY "public"."almacenes"."id";
CREATE TABLE IF NOT EXISTS "public"."clientes" (
    "id" bigint NOT NULL,
    "nombre" "text" NOT NULL,
    "dni_ruc" "text",
    "direccion" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "tipo_doc" "text",
    CONSTRAINT "clientes_documento_formato_check" CHECK ((("dni_ruc" IS NULL) OR (("tipo_doc" = '1'::"text") AND ("dni_ruc" ~ '^[0-9]{8}$'::"text")) OR (("tipo_doc" = '6'::"text") AND ("dni_ruc" ~ '^[0-9]{11}$'::"text")))),
    CONSTRAINT "clientes_tipo_doc_check" CHECK ((("tipo_doc" IS NULL) OR ("tipo_doc" = ANY (ARRAY['1'::"text", '6'::"text", '0'::"text"]))))
);
ALTER TABLE "public"."clientes" OWNER TO "postgres";
CREATE SEQUENCE IF NOT EXISTS "public"."clientes_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE "public"."clientes_id_seq" OWNER TO "postgres";
ALTER SEQUENCE "public"."clientes_id_seq" OWNED BY "public"."clientes"."id";
CREATE TABLE IF NOT EXISTS "public"."comprobantes_electronicos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "venta_id" bigint NOT NULL,
    "tipo_documento_sunat" "text" NOT NULL,
    "serie" "text" NOT NULL,
    "correlativo" bigint NOT NULL,
    "fecha_emision" "date" NOT NULL,
    "moneda" "text" DEFAULT 'PEN'::"text" NOT NULL,
    "estado" "text" DEFAULT 'pendiente'::"text" NOT NULL,
    "subtotal_bruto" numeric(14,2) DEFAULT 0 NOT NULL,
    "descuento_global_porcentaje" numeric(7,4) DEFAULT 0 NOT NULL,
    "descuento_global_monto" numeric(14,2) DEFAULT 0 NOT NULL,
    "total" numeric(14,2) DEFAULT 0 NOT NULL,
    "xml_path" "text",
    "cdr_path" "text",
    "pdf_path" "text",
    "hash_documento" "text",
    "codigo_sunat" "text",
    "descripcion_sunat" "text",
    "observaciones_sunat" "jsonb",
    "payload_json" "jsonb",
    "respuesta_json" "jsonb",
    "request_id" "uuid",
    "enviado_at" timestamp with time zone,
    "aceptado_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "fecha_emision_ts" timestamp with time zone,
    "base_imponible" numeric(14,2) DEFAULT 0 NOT NULL,
    "igv" numeric(14,2) DEFAULT 0 NOT NULL,
    "cliente_tipo_documento" "text",
    "cliente_numero_documento" "text",
    "cliente_razon_social" "text",
    "cliente_direccion" "text",
    "empresa_ruc" "text",
    "empresa_razon_social" "text",
    "empresa_nombre_comercial" "text",
    "empresa_direccion" "text",
    "empresa_ubigeo" "text",
    "empresa_departamento" "text",
    "empresa_provincia" "text",
    "empresa_distrito" "text",
    "empresa_cod_local" "text",
    "empresa_telefono" "text",
    "empresa_logo_url" "text",
    "numero_reintentos" integer DEFAULT 0 NOT NULL,
    "ultimo_error_tipo" "text",
    "ultimo_http_status" integer,
    "procesando_at" timestamp with time zone,
    "ultimo_intento_at" timestamp with time zone,
    "proveedor_facturacion" "text" DEFAULT 'APISPERU'::"text" NOT NULL,
    "api_version" "text" DEFAULT '1.3'::"text" NOT NULL,
    "archivo_nombre_base" "text",
    "ticket_sunat" "text",
    "bloqueo_token" "uuid",
    "bloqueo_expira_at" timestamp with time zone,
    "ultimo_intento_por" "uuid",
    "consultado_at" timestamp with time zone,
    "pdf_generado_at" timestamp with time zone,
    "estado_baja_tributaria" "text" DEFAULT 'ninguna'::"text" NOT NULL,
    "solicitud_baja_id" "uuid",
    "baja_motivo" "text",
    "baja_aceptada_at" timestamp with time zone,
    CONSTRAINT "comprobantes_estado_baja_tributaria_check" CHECK (("estado_baja_tributaria" = ANY (ARRAY['ninguna'::"text", 'solicitada'::"text", 'agrupada'::"text", 'ticket_pendiente'::"text", 'pendiente_reintento'::"text", 'resultado_incierto'::"text", 'aceptada'::"text", 'rechazada'::"text"]))),
    CONSTRAINT "comprobantes_estado_check" CHECK (("estado" = ANY (ARRAY['pendiente'::"text", 'pendiente_envio'::"text", 'procesando'::"text", 'ticket_pendiente'::"text", 'pendiente_reintento'::"text", 'resultado_incierto'::"text", 'aceptado'::"text", 'rechazado'::"text"])))
);
ALTER TABLE "public"."comprobantes_electronicos" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."configuracion_negocio" (
    "id" integer DEFAULT 1 NOT NULL,
    "razon_social" "text",
    "ruc" "text",
    "direccion" "text",
    "logo_url" "text",
    "telefono" "text",
    "nombre_comercial" "text",
    "ubigeo" "text",
    "departamento" "text",
    "provincia" "text",
    "distrito" "text",
    "cod_local" "text" DEFAULT '0000'::"text",
    "facturacion_habilitada" boolean DEFAULT false NOT NULL,
    "ambiente_facturacion" "text" DEFAULT 'beta'::"text" NOT NULL,
    "precios_incluyen_igv" boolean DEFAULT true NOT NULL,
    "porcentaje_igv" numeric(5,2) DEFAULT 18.00 NOT NULL,
    "descuento_sin_autorizacion_hasta" numeric(7,4) DEFAULT 10.0000 NOT NULL,
    "descuento_con_motivo_desde" numeric(7,4) DEFAULT 10.0000 NOT NULL,
    "descuento_con_pin_desde" numeric(7,4) DEFAULT 30.0000 NOT NULL,
    "generar_constancia_descuento" boolean DEFAULT true NOT NULL,
    "gre_transportista_habilitada" boolean DEFAULT false NOT NULL
);
ALTER TABLE "public"."configuracion_negocio" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."constancias_descuento" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "venta_id" bigint NOT NULL,
    "comprobante_id" "uuid",
    "codigo" "text" NOT NULL,
    "subtotal_bruto" numeric(14,2) NOT NULL,
    "descuento_porcentaje" numeric(7,4) NOT NULL,
    "descuento_monto" numeric(14,2) NOT NULL,
    "total_final" numeric(14,2) NOT NULL,
    "motivo" "text",
    "aplicado_por" bigint,
    "pdf_path" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "autorizado_por" bigint,
    "autorizado_at" timestamp with time zone
);
ALTER TABLE ONLY "public"."constancias_descuento" FORCE ROW LEVEL SECURITY;
ALTER TABLE "public"."constancias_descuento" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."correlativos_procesos_tributarios" (
    "tipo_proceso" "text" NOT NULL,
    "fecha_referencia" "date" NOT NULL,
    "ultimo_correlativo" integer DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "correlativos_proceso_tipo_check" CHECK (("tipo_proceso" = ANY (ARRAY['resumen_boletas'::"text", 'comunicacion_baja'::"text"])))
);
ALTER TABLE "public"."correlativos_procesos_tributarios" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."cotizaciones" (
    "id" bigint NOT NULL,
    "cliente_id" bigint,
    "fecha" timestamp with time zone DEFAULT "now"(),
    "total" numeric NOT NULL,
    "estado" "text" DEFAULT 'pendiente'::"text",
    "observaciones" "text",
    "validez_dias" integer DEFAULT 15,
    "request_id" "uuid" NOT NULL,
    "creado_por" "uuid"
);
ALTER TABLE "public"."cotizaciones" OWNER TO "postgres";
ALTER TABLE "public"."cotizaciones" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."cotizaciones_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."detalle_cotizaciones" (
    "id" bigint NOT NULL,
    "cotizacion_id" bigint,
    "producto_id" bigint,
    "cantidad" integer NOT NULL,
    "precio_unitario" numeric NOT NULL,
    "subtotal" numeric NOT NULL,
    "almacen_id" bigint,
    "tipo_unidad" "text",
    "piezas_reales" integer NOT NULL,
    "precio_unitario_comercial" numeric NOT NULL,
    "tipo_venta_snapshot" "text" NOT NULL,
    "pcs_snapshot" integer NOT NULL,
    "unidad_base_snapshot" "text" NOT NULL,
    "producto_nombre_snapshot" "text" NOT NULL,
    "codigo_snapshot" "text"
);
ALTER TABLE "public"."detalle_cotizaciones" OWNER TO "postgres";
ALTER TABLE "public"."detalle_cotizaciones" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."detalle_cotizaciones_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."detalle_ventas" (
    "id" bigint NOT NULL,
    "venta_id" bigint,
    "producto_id" bigint,
    "cantidad" integer NOT NULL,
    "precio_unitario" numeric NOT NULL,
    "subtotal" numeric NOT NULL,
    "almacen_id" bigint,
    "tipo_unidad" "text" DEFAULT 'unidad'::"text",
    "descuento_global_asignado" numeric(14,2) DEFAULT 0 NOT NULL,
    "subtotal_final" numeric(14,2) DEFAULT 0 NOT NULL,
    "piezas_reales" integer,
    "precio_unitario_comercial" numeric(14,4),
    "tipo_venta_snapshot" "text",
    "pcs_snapshot" integer,
    "unidad_base_snapshot" "text"
);
ALTER TABLE "public"."detalle_ventas" OWNER TO "postgres";
CREATE SEQUENCE IF NOT EXISTS "public"."detalle_ventas_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE "public"."detalle_ventas_id_seq" OWNER TO "postgres";
ALTER SEQUENCE "public"."detalle_ventas_id_seq" OWNED BY "public"."detalle_ventas"."id";
CREATE TABLE IF NOT EXISTS "public"."documentos_tributarios_reconciliaciones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tipo_documento" "text" NOT NULL,
    "documento_id" "uuid" NOT NULL,
    "decision" "text" NOT NULL,
    "estado_anterior" "text" NOT NULL,
    "estado_nuevo" "text" NOT NULL,
    "motivo" "text" NOT NULL,
    "referencia_externa" "text",
    "realizado_por" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "documentos_tributarios_reconciliaciones_decision_check" CHECK (("decision" = ANY (ARRAY['habilitar_reintento'::"text", 'mantener_incierto'::"text"]))),
    CONSTRAINT "documentos_tributarios_reconciliaciones_motivo_check" CHECK ((("char_length"(TRIM(BOTH FROM "motivo")) >= 10) AND ("char_length"(TRIM(BOTH FROM "motivo")) <= 500))),
    CONSTRAINT "documentos_tributarios_reconciliaciones_tipo_documento_check" CHECK (("tipo_documento" = ANY (ARRAY['comprobante'::"text", 'nota_credito'::"text", 'guia'::"text", 'proceso'::"text"])))
);
ALTER TABLE ONLY "public"."documentos_tributarios_reconciliaciones" FORCE ROW LEVEL SECURITY;
ALTER TABLE "public"."documentos_tributarios_reconciliaciones" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."empleados" (
    "id" bigint NOT NULL,
    "nombre" "text" NOT NULL,
    "cargo" "text",
    "telefono" "text",
    "activo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "email" "text",
    "rol" "text" DEFAULT 'operador'::"text" NOT NULL,
    "auth_id" "uuid",
    "creado_por" "uuid",
    "fecha_creacion_usuario" timestamp with time zone DEFAULT "now"(),
    "ultimo_acceso" timestamp with time zone,
    "fecha_actualizacion" timestamp with time zone DEFAULT "now"(),
    "eliminado_por" "uuid",
    "fecha_eliminacion" timestamp with time zone,
    CONSTRAINT "empleados_rol_check" CHECK (("rol" = ANY (ARRAY['admin'::"text", 'operador'::"text"])))
);
ALTER TABLE "public"."empleados" OWNER TO "postgres";
CREATE SEQUENCE IF NOT EXISTS "public"."empleados_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE "public"."empleados_id_seq" OWNER TO "postgres";
ALTER SEQUENCE "public"."empleados_id_seq" OWNED BY "public"."empleados"."id";
CREATE TABLE IF NOT EXISTS "public"."facturacion_intentos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "comprobante_id" "uuid" NOT NULL,
    "numero_intento" integer NOT NULL,
    "resultado" "text" NOT NULL,
    "codigo_http" integer,
    "codigo_error" "text",
    "mensaje_error" "text",
    "respuesta_json" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "payload_json" "jsonb",
    "fecha_inicio" timestamp with time zone DEFAULT "now"() NOT NULL,
    "fecha_fin" timestamp with time zone,
    "duracion_ms" integer,
    "accion" "text" DEFAULT 'emitir'::"text" NOT NULL,
    "usuario_id" "uuid",
    "lock_token" "uuid"
);
ALTER TABLE "public"."facturacion_intentos" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."gastos" (
    "id" bigint NOT NULL,
    "proveedor_id" bigint,
    "monto" numeric NOT NULL,
    "categoria" "text",
    "descripcion" "text",
    "estado" "text",
    "saldo" numeric,
    "fecha" timestamp with time zone DEFAULT "now"()
);
ALTER TABLE "public"."gastos" OWNER TO "postgres";
CREATE SEQUENCE IF NOT EXISTS "public"."gastos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE "public"."gastos_id_seq" OWNER TO "postgres";
ALTER SEQUENCE "public"."gastos_id_seq" OWNED BY "public"."gastos"."id";
CREATE TABLE IF NOT EXISTS "public"."gre_conductores" (
    "id" bigint NOT NULL,
    "tipo_documento" "text" DEFAULT '1'::"text" NOT NULL,
    "numero_documento" "text" NOT NULL,
    "nombres" "text" NOT NULL,
    "numero_licencia" "text",
    "telefono" "text",
    "activo" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "apellidos" "text",
    CONSTRAINT "gre_conductores_tipo_doc_check" CHECK (("tipo_documento" = ANY (ARRAY['1'::"text", '4'::"text", '7'::"text"])))
);
ALTER TABLE "public"."gre_conductores" OWNER TO "postgres";
ALTER TABLE "public"."gre_conductores" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."gre_conductores_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."gre_transportistas" (
    "id" bigint NOT NULL,
    "ruc" "text" NOT NULL,
    "razon_social" "text" NOT NULL,
    "registro_mtc" "text",
    "direccion" "text",
    "telefono" "text",
    "activo" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "gre_transportistas_ruc_check" CHECK (("ruc" ~ '^[0-9]{11}$'::"text"))
);
ALTER TABLE "public"."gre_transportistas" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."gre_transportistas_agencias" (
    "id" bigint NOT NULL,
    "transportista_id" bigint NOT NULL,
    "nombre" "text" NOT NULL,
    "departamento" "text",
    "provincia" "text",
    "distrito" "text",
    "direccion" "text" NOT NULL,
    "ubigeo" "text" NOT NULL,
    "telefono" "text",
    "codigo_interno" "text",
    "permite_origen" boolean DEFAULT true NOT NULL,
    "permite_destino" boolean DEFAULT true NOT NULL,
    "activo" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "gre_transportistas_agencias_direccion_check" CHECK (("char_length"(TRIM(BOTH FROM "direccion")) >= 5)),
    CONSTRAINT "gre_transportistas_agencias_nombre_check" CHECK (("char_length"(TRIM(BOTH FROM "nombre")) >= 2)),
    CONSTRAINT "gre_transportistas_agencias_ubigeo_check" CHECK (("ubigeo" ~ '^[0-9]{6}$'::"text"))
);
ALTER TABLE "public"."gre_transportistas_agencias" OWNER TO "postgres";
ALTER TABLE "public"."gre_transportistas_agencias" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."gre_transportistas_agencias_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
ALTER TABLE "public"."gre_transportistas" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."gre_transportistas_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."gre_ubigeos" (
    "codigo" "text" NOT NULL,
    "departamento" "text" NOT NULL,
    "provincia" "text" NOT NULL,
    "distrito" "text" NOT NULL,
    "activo" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "gre_ubigeos_codigo_check" CHECK (("codigo" ~ '^[0-9]{6}$'::"text"))
);
ALTER TABLE "public"."gre_ubigeos" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."gre_vehiculos" (
    "id" bigint NOT NULL,
    "placa" "text" NOT NULL,
    "marca" "text",
    "modelo" "text",
    "transportista_id" bigint,
    "activo" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "constancia_inscripcion" "text",
    CONSTRAINT "gre_vehiculos_placa_check" CHECK (("upper"(TRIM(BOTH FROM "placa")) ~ '^[A-Z0-9-]{5,10}$'::"text"))
);
ALTER TABLE "public"."gre_vehiculos" OWNER TO "postgres";
ALTER TABLE "public"."gre_vehiculos" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."gre_vehiculos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."guias_remision" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "request_id" "uuid" NOT NULL,
    "tipo_guia" "text" NOT NULL,
    "tipo_documento_sunat" "text" NOT NULL,
    "serie" "text",
    "correlativo" bigint,
    "estado" "text" DEFAULT 'pendiente_envio'::"text" NOT NULL,
    "origen_tipo" "text" DEFAULT 'manual'::"text" NOT NULL,
    "venta_id" bigint,
    "transferencia_id" bigint,
    "comprobante_id" "uuid",
    "guia_remitente_id" "uuid",
    "documento_relacionado_tipo" "text",
    "documento_relacionado_numero" "text",
    "motivo_codigo" "text" NOT NULL,
    "motivo_descripcion" "text" NOT NULL,
    "modalidad_transporte" "text" NOT NULL,
    "fecha_emision" timestamp with time zone DEFAULT "now"() NOT NULL,
    "fecha_traslado" timestamp with time zone NOT NULL,
    "destinatario_tipo_documento" "text",
    "destinatario_numero_documento" "text",
    "destinatario_razon_social" "text",
    "destinatario_direccion" "text",
    "destinatario_ubigeo" "text",
    "remitente_tipo_documento" "text",
    "remitente_numero_documento" "text",
    "remitente_razon_social" "text",
    "partida_direccion" "text",
    "partida_ubigeo" "text",
    "llegada_direccion" "text",
    "llegada_ubigeo" "text",
    "peso_total" numeric(14,4),
    "unidad_peso" "text" DEFAULT 'KGM'::"text" NOT NULL,
    "peso_editado" boolean DEFAULT false NOT NULL,
    "transportista_id" bigint,
    "conductor_id" bigint,
    "vehiculo_id" bigint,
    "transportista_ruc_snapshot" "text",
    "transportista_razon_social_snapshot" "text",
    "transportista_registro_mtc_snapshot" "text",
    "conductor_tipo_documento_snapshot" "text",
    "conductor_documento_snapshot" "text",
    "conductor_nombres_snapshot" "text",
    "conductor_licencia_snapshot" "text",
    "vehiculo_placa_snapshot" "text",
    "vehiculo_marca_snapshot" "text",
    "vehiculo_modelo_snapshot" "text",
    "observacion" "text",
    "payload_json" "jsonb",
    "respuesta_json" "jsonb",
    "ticket_sunat" "text",
    "codigo_sunat" "text",
    "descripcion_sunat" "text",
    "observaciones_sunat" "jsonb",
    "xml_path" "text",
    "cdr_path" "text",
    "pdf_path" "text",
    "hash_documento" "text",
    "ultimo_http_status" integer,
    "ultimo_error_tipo" "text",
    "ultimo_intento_at" timestamp with time zone,
    "enviado_at" timestamp with time zone,
    "aceptado_at" timestamp with time zone,
    "consultado_at" timestamp with time zone,
    "procesando_at" timestamp with time zone,
    "bloqueo_token" "uuid",
    "bloqueo_expira_at" timestamp with time zone,
    "creado_por" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "conductor_apellidos_snapshot" "text",
    "vehiculo_constancia_snapshot" "text",
    "es_prueba" boolean DEFAULT true NOT NULL,
    "ind_transbordo" boolean DEFAULT false NOT NULL,
    "transportista_transbordo_id" bigint,
    "agencia_origen_id" bigint,
    "agencia_destino_id" bigint,
    "destino_entrega_tipo" "text" DEFAULT 'direccion_cliente'::"text" NOT NULL,
    "transportista_transbordo_ruc_snapshot" "text",
    "transportista_transbordo_razon_social_snapshot" "text",
    "transportista_transbordo_registro_mtc_snapshot" "text",
    "agencia_origen_nombre_snapshot" "text",
    "agencia_origen_direccion_snapshot" "text",
    "agencia_origen_ubigeo_snapshot" "text",
    "agencia_destino_nombre_snapshot" "text",
    "agencia_destino_direccion_snapshot" "text",
    "agencia_destino_ubigeo_snapshot" "text",
    "ambiente_emision" "text" DEFAULT 'sin_definir'::"text" NOT NULL,
    "ultimo_intento_por" "uuid",
    "cantidad_bultos" integer,
    CONSTRAINT "guias_remision_ambiente_emision_check" CHECK (("ambiente_emision" = ANY (ARRAY['sin_definir'::"text", 'beta'::"text", 'produccion'::"text"]))),
    CONSTRAINT "guias_remision_cantidad_bultos_check" CHECK ((("cantidad_bultos" IS NULL) OR ("cantidad_bultos" > 0))),
    CONSTRAINT "guias_remision_destino_entrega_tipo_check" CHECK (("destino_entrega_tipo" = ANY (ARRAY['agencia'::"text", 'direccion_cliente'::"text"]))),
    CONSTRAINT "guias_remision_estado_check" CHECK (("estado" = ANY (ARRAY['borrador'::"text", 'pendiente_envio'::"text", 'procesando'::"text", 'ticket_pendiente'::"text", 'pendiente_reintento'::"text", 'resultado_incierto'::"text", 'xml_validado_prueba'::"text", 'aceptado'::"text", 'rechazado'::"text"]))),
    CONSTRAINT "guias_remision_llegada_ubigeo_check" CHECK ((("estado" = 'borrador'::"text") OR ("llegada_ubigeo" ~ '^[0-9]{6}$'::"text"))),
    CONSTRAINT "guias_remision_modalidad_check" CHECK (("modalidad_transporte" = ANY (ARRAY['01'::"text", '02'::"text"]))),
    CONSTRAINT "guias_remision_motivo_check" CHECK (("motivo_codigo" = ANY (ARRAY['01'::"text", '02'::"text", '04'::"text", '08'::"text", '09'::"text", '13'::"text", '14'::"text", '18'::"text", '19'::"text"]))),
    CONSTRAINT "guias_remision_origen_check" CHECK (("origen_tipo" = ANY (ARRAY['manual'::"text", 'venta'::"text", 'traslado'::"text"]))),
    CONSTRAINT "guias_remision_partida_ubigeo_check" CHECK ((("estado" = 'borrador'::"text") OR ("partida_ubigeo" ~ '^[0-9]{6}$'::"text"))),
    CONSTRAINT "guias_remision_peso_check" CHECK ((("estado" = 'borrador'::"text") OR (("peso_total" IS NOT NULL) AND ("peso_total" > (0)::numeric)))),
    CONSTRAINT "guias_remision_serie_check" CHECK (("serie" = "upper"("serie"))),
    CONSTRAINT "guias_remision_tipo_check" CHECK (("tipo_guia" = ANY (ARRAY['remitente'::"text", 'transportista'::"text"]))),
    CONSTRAINT "guias_remision_tipo_doc_check" CHECK (("tipo_documento_sunat" = ANY (ARRAY['09'::"text", '31'::"text"])))
);
ALTER TABLE "public"."guias_remision" OWNER TO "postgres";
COMMENT ON COLUMN "public"."guias_remision"."cantidad_bultos" IS 'Número total opcional de bultos o unidades físicas de manipulación del traslado.';
CREATE TABLE IF NOT EXISTS "public"."guias_remision_detalles" (
    "id" bigint NOT NULL,
    "guia_id" "uuid" NOT NULL,
    "producto_id" bigint,
    "detalle_venta_id" bigint,
    "transferencia_id" bigint,
    "almacen_id" bigint,
    "codigo" "text",
    "descripcion" "text" NOT NULL,
    "unidad" "text" NOT NULL,
    "cantidad" numeric(14,4) NOT NULL,
    "piezas_reales" integer,
    "peso_unitario_kg" numeric(14,4) DEFAULT 0 NOT NULL,
    "peso_total_kg" numeric(14,4) DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "guias_remision_detalles_cantidad_check" CHECK (("cantidad" > (0)::numeric)),
    CONSTRAINT "guias_remision_detalles_peso_check" CHECK ((("peso_unitario_kg" >= (0)::numeric) AND ("peso_total_kg" >= (0)::numeric)))
);
ALTER TABLE "public"."guias_remision_detalles" OWNER TO "postgres";
ALTER TABLE "public"."guias_remision_detalles" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."guias_remision_detalles_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."guias_remision_intentos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "guia_id" "uuid" NOT NULL,
    "numero_intento" integer NOT NULL,
    "accion" "text" NOT NULL,
    "resultado" "text" DEFAULT 'procesando'::"text" NOT NULL,
    "codigo_http" integer,
    "codigo_error" "text",
    "mensaje_error" "text",
    "payload_json" "jsonb",
    "respuesta_json" "jsonb",
    "fecha_inicio" timestamp with time zone DEFAULT "now"() NOT NULL,
    "fecha_fin" timestamp with time zone,
    "duracion_ms" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "usuario_id" "uuid",
    "lock_token" "uuid"
);
ALTER TABLE "public"."guias_remision_intentos" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."inventario_almacen" (
    "id" bigint NOT NULL,
    "producto_id" bigint,
    "almacen_id" bigint,
    "cantidad" integer DEFAULT 0
);
ALTER TABLE "public"."inventario_almacen" OWNER TO "postgres";
CREATE SEQUENCE IF NOT EXISTS "public"."inventario_almacen_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE "public"."inventario_almacen_id_seq" OWNER TO "postgres";
ALTER SEQUENCE "public"."inventario_almacen_id_seq" OWNED BY "public"."inventario_almacen"."id";
CREATE TABLE IF NOT EXISTS "public"."inventario_movimientos" (
    "id" bigint NOT NULL,
    "fecha" timestamp with time zone DEFAULT "now"(),
    "producto_id" bigint,
    "producto_nombre" "text" NOT NULL,
    "pcs" integer DEFAULT 1,
    "proveedor" "text",
    "ingreso_cant" numeric DEFAULT 0,
    "ingreso_und" "text",
    "ingreso_costo" numeric DEFAULT 0,
    "ingreso_p_unit" numeric DEFAULT 0,
    "ingreso_p_caja" numeric DEFAULT 0,
    "ingreso_p_c_comp" numeric DEFAULT 0,
    "tipo" "text" NOT NULL,
    "salida_cliente" "text",
    "salida_cant" numeric DEFAULT 0,
    "salida_und" "text",
    "salida_p_unit" numeric DEFAULT 0,
    "salida_total" numeric DEFAULT 0,
    "saldo" numeric DEFAULT 0 NOT NULL,
    "almacen_id" bigint,
    "almacen_nombre" "text",
    "observaciones" "text",
    "venta_id" bigint,
    "vendedor_id" bigint,
    "tipo_venta_snapshot" "text",
    "unidad_base_snapshot" "text",
    "request_id" "uuid",
    "venta_id_original" bigint,
    "vendedor_nombre_snapshot" "text",
    "anulado_por_id" bigint,
    "anulado_por_nombre_snapshot" "text",
    "motivo_anulacion" "text"
);
ALTER TABLE "public"."inventario_movimientos" OWNER TO "postgres";
ALTER TABLE "public"."inventario_movimientos" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."inventario_movimientos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);
CREATE TABLE IF NOT EXISTS "public"."inventario_operaciones_idempotentes" (
    "request_id" "uuid" NOT NULL,
    "tipo_operacion" "text" NOT NULL,
    "producto_id" bigint NOT NULL,
    "resultado" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);
ALTER TABLE "public"."inventario_operaciones_idempotentes" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."pagos_empleados" (
    "id" bigint NOT NULL,
    "empleado_id" bigint,
    "concepto" "text",
    "metodo" "text" NOT NULL,
    "monto" numeric NOT NULL,
    "fecha" timestamp with time zone DEFAULT "now"(),
    "afecta_caja_chica" boolean DEFAULT false
);
ALTER TABLE "public"."pagos_empleados" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."pagos_gasto" (
    "id" bigint NOT NULL,
    "gasto_id" bigint,
    "metodo" "text" NOT NULL,
    "monto" numeric NOT NULL,
    "fecha" timestamp with time zone DEFAULT "now"(),
    "afecta_caja_chica" boolean DEFAULT false,
    "request_id" "uuid"
);
ALTER TABLE "public"."pagos_gasto" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."pagos_venta" (
    "id" bigint NOT NULL,
    "venta_id" bigint,
    "metodo" "text" NOT NULL,
    "monto" numeric NOT NULL,
    "fecha" timestamp with time zone DEFAULT "now"(),
    "request_id" "uuid"
);
ALTER TABLE "public"."pagos_venta" OWNER TO "postgres";
CREATE OR REPLACE VIEW "public"."movimientos" WITH ("security_invoker"='true') AS
 SELECT "pv"."id",
    ('Cobro de Venta #'::"text" || "pv"."venta_id") AS "descripcion",
    "pv"."monto",
    'ingreso'::"text" AS "tipo",
    "pv"."fecha",
    "pv"."venta_id",
    NULL::bigint AS "gasto_id",
    NULL::bigint AS "pago_empleado_id",
    "pv"."metodo",
    true AS "afecta_caja_chica"
   FROM "public"."pagos_venta" "pv"
UNION ALL
 SELECT "pg"."id",
    ('Pago de Gasto: '::"text" || COALESCE("g"."categoria", 'Varios'::"text")) AS "descripcion",
    "pg"."monto",
    'egreso'::"text" AS "tipo",
    "pg"."fecha",
    NULL::bigint AS "venta_id",
    "pg"."gasto_id",
    NULL::bigint AS "pago_empleado_id",
    "pg"."metodo",
    COALESCE("pg"."afecta_caja_chica", false) AS "afecta_caja_chica"
   FROM ("public"."pagos_gasto" "pg"
     LEFT JOIN "public"."gastos" "g" ON (("pg"."gasto_id" = "g"."id")))
UNION ALL
 SELECT "pe"."id",
    ((('Pago a Personal: '::"text" || COALESCE("e"."nombre", 'Empleado'::"text")) || ' - '::"text") || COALESCE("pe"."concepto", ''::"text")) AS "descripcion",
    "pe"."monto",
    'egreso'::"text" AS "tipo",
    "pe"."fecha",
    NULL::bigint AS "venta_id",
    NULL::bigint AS "gasto_id",
    "pe"."id" AS "pago_empleado_id",
    "pe"."metodo",
    COALESCE("pe"."afecta_caja_chica", false) AS "afecta_caja_chica"
   FROM ("public"."pagos_empleados" "pe"
     LEFT JOIN "public"."empleados" "e" ON (("pe"."empleado_id" = "e"."id")));
ALTER VIEW "public"."movimientos" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."notas_credito" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "request_id" "uuid" NOT NULL,
    "comprobante_id" "uuid" NOT NULL,
    "venta_id" bigint NOT NULL,
    "tipo_origen" "text" NOT NULL,
    "tipo_doc_afectado" "text" NOT NULL,
    "serie_afectada" "text" NOT NULL,
    "correlativo_afectado" bigint NOT NULL,
    "motivo_codigo" "text" NOT NULL,
    "motivo_descripcion" "text" NOT NULL,
    "serie" "text" NOT NULL,
    "correlativo" bigint NOT NULL,
    "fecha_emision" "date" NOT NULL,
    "fecha_emision_ts" timestamp with time zone NOT NULL,
    "moneda" "text" DEFAULT 'PEN'::"text" NOT NULL,
    "estado" "text" DEFAULT 'pendiente_envio'::"text" NOT NULL,
    "afecta_stock" boolean DEFAULT false NOT NULL,
    "afecta_dinero" boolean DEFAULT true NOT NULL,
    "reponer_stock" boolean DEFAULT false NOT NULL,
    "stock_aplicado" boolean DEFAULT false NOT NULL,
    "stock_error" "text",
    "stock_reintentos" integer DEFAULT 0 NOT NULL,
    "stock_ultimo_intento_at" timestamp with time zone,
    "base_imponible" numeric(14,2) DEFAULT 0 NOT NULL,
    "igv" numeric(14,2) DEFAULT 0 NOT NULL,
    "total" numeric(14,2) DEFAULT 0 NOT NULL,
    "cliente_tipo_documento" "text",
    "cliente_numero_documento" "text",
    "cliente_razon_social" "text",
    "cliente_direccion" "text",
    "empresa_ruc" "text",
    "empresa_razon_social" "text",
    "empresa_nombre_comercial" "text",
    "empresa_direccion" "text",
    "empresa_ubigeo" "text",
    "empresa_departamento" "text",
    "empresa_provincia" "text",
    "empresa_distrito" "text",
    "empresa_cod_local" "text",
    "empresa_telefono" "text",
    "empresa_logo_url" "text",
    "payload_json" "jsonb",
    "respuesta_json" "jsonb",
    "xml_path" "text",
    "cdr_path" "text",
    "pdf_path" "text",
    "hash_documento" "text",
    "codigo_sunat" "text",
    "descripcion_sunat" "text",
    "observaciones_sunat" "jsonb",
    "archivo_nombre_base" "text",
    "ticket_sunat" "text",
    "numero_reintentos" integer DEFAULT 0 NOT NULL,
    "ultimo_error_tipo" "text",
    "ultimo_http_status" integer,
    "ultimo_intento_at" timestamp with time zone,
    "procesando_at" timestamp with time zone,
    "bloqueo_token" "uuid",
    "bloqueo_expira_at" timestamp with time zone,
    "ultimo_intento_por" "uuid",
    "enviado_at" timestamp with time zone,
    "aceptado_at" timestamp with time zone,
    "pdf_generado_at" timestamp with time zone,
    "creado_por" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "estado_baja_tributaria" "text" DEFAULT 'ninguna'::"text" NOT NULL,
    "solicitud_baja_id" "uuid",
    "baja_motivo" "text",
    "baja_aceptada_at" timestamp with time zone,
    "baja_stock_revertido" boolean DEFAULT false NOT NULL,
    "baja_stock_error" "text",
    "baja_stock_reintentos" integer DEFAULT 0 NOT NULL,
    "baja_stock_ultimo_intento_at" timestamp with time zone,
    CONSTRAINT "notas_credito_estado_baja_tributaria_check" CHECK (("estado_baja_tributaria" = ANY (ARRAY['ninguna'::"text", 'solicitada'::"text", 'agrupada'::"text", 'ticket_pendiente'::"text", 'pendiente_reintento'::"text", 'resultado_incierto'::"text", 'aceptada'::"text", 'rechazada'::"text"]))),
    CONSTRAINT "notas_credito_estado_check" CHECK (("estado" = ANY (ARRAY['pendiente_envio'::"text", 'procesando'::"text", 'pendiente_reintento'::"text", 'resultado_incierto'::"text", 'aceptado'::"text", 'rechazado'::"text"]))),
    CONSTRAINT "notas_credito_motivo_check" CHECK (("motivo_codigo" = ANY (ARRAY['01'::"text", '03'::"text", '04'::"text", '07'::"text"]))),
    CONSTRAINT "notas_credito_serie_check" CHECK (("serie" = "upper"("serie"))),
    CONSTRAINT "notas_credito_total_check" CHECK (("total" >= (0)::numeric))
);
ALTER TABLE "public"."notas_credito" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."notas_credito_detalles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nota_credito_id" "uuid" NOT NULL,
    "detalle_venta_id" bigint,
    "producto_id" bigint,
    "almacen_id" bigint,
    "codigo_producto" "text",
    "descripcion_original" "text" NOT NULL,
    "descripcion_corregida" "text",
    "tipo_unidad" "text" DEFAULT 'unidad'::"text" NOT NULL,
    "unidad_sunat" "text" DEFAULT 'NIU'::"text" NOT NULL,
    "cantidad_visual" integer DEFAULT 1 NOT NULL,
    "piezas_reales" integer DEFAULT 0 NOT NULL,
    "precio_unitario_comercial" numeric(14,6) DEFAULT 0 NOT NULL,
    "subtotal" numeric(14,2) DEFAULT 0 NOT NULL,
    "base_imponible" numeric(14,2) DEFAULT 0 NOT NULL,
    "igv" numeric(14,2) DEFAULT 0 NOT NULL,
    "tipo_venta_snapshot" "text",
    "pcs_snapshot" integer,
    "unidad_base_snapshot" "text",
    "repone_stock" boolean DEFAULT false NOT NULL,
    "stock_aplicado" boolean DEFAULT false NOT NULL,
    "movimiento_inventario_id" bigint,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "baja_stock_revertido" boolean DEFAULT false NOT NULL,
    "baja_request_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "movimiento_baja_id" bigint,
    CONSTRAINT "notas_credito_detalles_cantidad_check" CHECK (("cantidad_visual" > 0)),
    CONSTRAINT "notas_credito_detalles_piezas_check" CHECK (("piezas_reales" >= 0)),
    CONSTRAINT "notas_credito_detalles_subtotal_check" CHECK (("subtotal" >= (0)::numeric))
);
ALTER TABLE "public"."notas_credito_detalles" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."notas_credito_intentos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nota_credito_id" "uuid" NOT NULL,
    "numero_intento" integer NOT NULL,
    "accion" "text" DEFAULT 'emitir'::"text" NOT NULL,
    "resultado" "text" DEFAULT 'procesando'::"text" NOT NULL,
    "codigo_http" integer,
    "codigo_error" "text",
    "mensaje_error" "text",
    "payload_json" "jsonb",
    "respuesta_json" "jsonb",
    "usuario_id" "uuid",
    "lock_token" "uuid",
    "fecha_inicio" timestamp with time zone DEFAULT "now"() NOT NULL,
    "fecha_fin" timestamp with time zone,
    "duracion_ms" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);
ALTER TABLE "public"."notas_credito_intentos" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."pagos_deuda_requests" (
    "request_id" "uuid" NOT NULL,
    "auth_user_id" "uuid" NOT NULL,
    "empleado_id" bigint NOT NULL,
    "es_cliente" boolean NOT NULL,
    "deuda_id" bigint NOT NULL,
    "monto" numeric(14,2) NOT NULL,
    "metodo" "text" NOT NULL,
    "descontar_de_caja" boolean DEFAULT false NOT NULL,
    "resultado" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone,
    CONSTRAINT "pagos_deuda_requests_metodo_check" CHECK (("length"(TRIM(BOTH FROM "metodo")) > 0)),
    CONSTRAINT "pagos_deuda_requests_monto_check" CHECK (("monto" > (0)::numeric))
);
ALTER TABLE "public"."pagos_deuda_requests" OWNER TO "postgres";
CREATE SEQUENCE IF NOT EXISTS "public"."pagos_empleados_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE "public"."pagos_empleados_id_seq" OWNER TO "postgres";
ALTER SEQUENCE "public"."pagos_empleados_id_seq" OWNED BY "public"."pagos_empleados"."id";
CREATE SEQUENCE IF NOT EXISTS "public"."pagos_gasto_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE "public"."pagos_gasto_id_seq" OWNER TO "postgres";
ALTER SEQUENCE "public"."pagos_gasto_id_seq" OWNED BY "public"."pagos_gasto"."id";
CREATE SEQUENCE IF NOT EXISTS "public"."pagos_venta_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE "public"."pagos_venta_id_seq" OWNER TO "postgres";
ALTER SEQUENCE "public"."pagos_venta_id_seq" OWNED BY "public"."pagos_venta"."id";
CREATE TABLE IF NOT EXISTS "public"."personas_cache" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tipo" "text" NOT NULL,
    "numero" "text" NOT NULL,
    "nombres" "text",
    "apellido_paterno" "text",
    "apellido_materno" "text",
    "nombre_completo" "text",
    "razon_social" "text",
    "data" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "personas_cache_numero_formato_check" CHECK (((("tipo" = 'dni'::"text") AND ("numero" ~ '^[0-9]{8}$'::"text")) OR (("tipo" = 'ruc'::"text") AND ("numero" ~ '^[0-9]{11}$'::"text")))),
    CONSTRAINT "personas_cache_tipo_check" CHECK (("tipo" = ANY (ARRAY['dni'::"text", 'ruc'::"text"])))
);
ALTER TABLE "public"."personas_cache" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."procesos_tributarios" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "request_id" "uuid" NOT NULL,
    "tipo_proceso" "text" NOT NULL,
    "fecha_referencia" "date" NOT NULL,
    "fecha_comunicacion" "date" NOT NULL,
    "correlativo" integer NOT NULL,
    "identificador" "text" NOT NULL,
    "estado" "text" DEFAULT 'pendiente_envio'::"text" NOT NULL,
    "ticket_sunat" "text",
    "payload_json" "jsonb",
    "respuesta_json" "jsonb",
    "xml_path" "text",
    "cdr_path" "text",
    "pdf_path" "text",
    "hash_documento" "text",
    "codigo_sunat" "text",
    "descripcion_sunat" "text",
    "observaciones_sunat" "jsonb",
    "numero_reintentos" integer DEFAULT 0 NOT NULL,
    "ultimo_error_tipo" "text",
    "ultimo_http_status" integer,
    "ultimo_intento_at" timestamp with time zone,
    "procesando_at" timestamp with time zone,
    "bloqueo_token" "uuid",
    "bloqueo_expira_at" timestamp with time zone,
    "ultimo_intento_por" "uuid",
    "enviado_at" timestamp with time zone,
    "consultado_at" timestamp with time zone,
    "aceptado_at" timestamp with time zone,
    "pdf_generado_at" timestamp with time zone,
    "creado_por" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "procesos_tributarios_correlativo_check" CHECK (("correlativo" > 0)),
    CONSTRAINT "procesos_tributarios_estado_check" CHECK (("estado" = ANY (ARRAY['pendiente_envio'::"text", 'procesando'::"text", 'ticket_pendiente'::"text", 'pendiente_reintento'::"text", 'resultado_incierto'::"text", 'aceptado'::"text", 'rechazado'::"text"]))),
    CONSTRAINT "procesos_tributarios_tipo_check" CHECK (("tipo_proceso" = ANY (ARRAY['resumen_boletas'::"text", 'comunicacion_baja'::"text"])))
);
ALTER TABLE "public"."procesos_tributarios" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."procesos_tributarios_detalles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "proceso_id" "uuid" NOT NULL,
    "solicitud_id" "uuid" NOT NULL,
    "tipo_origen" "text" NOT NULL,
    "comprobante_id" "uuid",
    "nota_credito_id" "uuid",
    "venta_id" bigint NOT NULL,
    "tipo_doc" "text" NOT NULL,
    "serie" "text" NOT NULL,
    "correlativo" bigint NOT NULL,
    "serie_numero" "text" NOT NULL,
    "estado_resumen" "text" DEFAULT '3'::"text" NOT NULL,
    "motivo" "text" NOT NULL,
    "moneda" "text" DEFAULT 'PEN'::"text" NOT NULL,
    "cliente_tipo" "text",
    "cliente_numero" "text",
    "base_imponible" numeric(14,2) DEFAULT 0 NOT NULL,
    "igv" numeric(14,2) DEFAULT 0 NOT NULL,
    "total" numeric(14,2) DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "procesos_detalles_estado_resumen_check" CHECK (("estado_resumen" = ANY (ARRAY['1'::"text", '2'::"text", '3'::"text"]))),
    CONSTRAINT "procesos_detalles_serie_check" CHECK (("serie" = "upper"("serie")))
);
ALTER TABLE "public"."procesos_tributarios_detalles" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."procesos_tributarios_intentos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "proceso_id" "uuid" NOT NULL,
    "numero_intento" integer NOT NULL,
    "accion" "text" NOT NULL,
    "resultado" "text" DEFAULT 'procesando'::"text" NOT NULL,
    "codigo_http" integer,
    "codigo_error" "text",
    "mensaje_error" "text",
    "payload_json" "jsonb",
    "respuesta_json" "jsonb",
    "usuario_id" "uuid",
    "lock_token" "uuid",
    "fecha_inicio" timestamp with time zone DEFAULT "now"() NOT NULL,
    "fecha_fin" timestamp with time zone,
    "duracion_ms" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "procesos_tributarios_intentos_accion_check" CHECK (("accion" = ANY (ARRAY['emitir'::"text", 'reintentar'::"text", 'consultar'::"text"])))
);
ALTER TABLE "public"."procesos_tributarios_intentos" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."productos" (
    "id" bigint NOT NULL,
    "nombre" "text" NOT NULL,
    "precio_unidad" numeric NOT NULL,
    "precio_caja" numeric,
    "precio_compra" numeric,
    "imagen_path" "text",
    "unidad_medida" "text",
    "proveedor_id" bigint,
    "permitir_sin_stock" boolean DEFAULT false,
    "cantidad_por_caja" integer,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "tipo_venta" "text" DEFAULT 'AMBOS'::"text",
    "activo" boolean DEFAULT true,
    "codigo" "text",
    "peso_kg" numeric(14,4) DEFAULT 0 NOT NULL,
    "unidad_gre" "text" DEFAULT 'NIU'::"text" NOT NULL,
    "stock_minimo" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "productos_codigo_formato_check" CHECK ((("codigo" IS NULL) OR ("upper"(TRIM(BOTH FROM "codigo")) ~ '^[A-Z0-9._/-]+$'::"text"))),
    CONSTRAINT "productos_codigo_longitud_check" CHECK ((("codigo" IS NULL) OR (("length"(TRIM(BOTH FROM "codigo")) >= 1) AND ("length"(TRIM(BOTH FROM "codigo")) <= 50)))),
    CONSTRAINT "productos_peso_kg_check" CHECK (("peso_kg" >= (0)::numeric)),
    CONSTRAINT "productos_unidad_gre_check" CHECK (("unidad_gre" ~ '^[A-Z0-9]{2,3}$'::"text"))
);
ALTER TABLE "public"."productos" OWNER TO "postgres";
COMMENT ON COLUMN "public"."productos"."precio_caja" IS 'Precio de cada elemento contenido en el empaque mayorista. El precio completo se calcula como precio_caja * cantidad_por_caja.';
COMMENT ON COLUMN "public"."productos"."cantidad_por_caja" IS 'PAQUETES: piezas físicas por paquete (solo precio). CAJA_PAQUETES: paquetes por caja. CAJA_UNIDADES: unidades por caja.';
COMMENT ON COLUMN "public"."productos"."codigo" IS 'Código interno único del producto. No sustituye codigo_barras.';
CREATE SEQUENCE IF NOT EXISTS "public"."productos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE "public"."productos_id_seq" OWNER TO "postgres";
ALTER SEQUENCE "public"."productos_id_seq" OWNED BY "public"."productos"."id";
CREATE TABLE IF NOT EXISTS "public"."proveedores" (
    "id" bigint NOT NULL,
    "nombre" "text" NOT NULL,
    "telefono" "text",
    "ruc" "text",
    "direccion" "text",
    "estado" "text",
    "activo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "tipo_doc" "text"
);
ALTER TABLE "public"."proveedores" OWNER TO "postgres";
CREATE SEQUENCE IF NOT EXISTS "public"."proveedores_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE "public"."proveedores_id_seq" OWNER TO "postgres";
ALTER SEQUENCE "public"."proveedores_id_seq" OWNED BY "public"."proveedores"."id";
CREATE OR REPLACE VIEW "public"."reportes_movimientos_financieros" WITH ("security_invoker"='true') AS
 SELECT "pv"."id",
    'pago_venta'::"text" AS "origen",
    "pv"."id" AS "origen_id",
    ('Cobro de Venta #'::"text" || "pv"."venta_id") AS "descripcion",
    "pv"."monto",
    'ingreso'::"text" AS "tipo",
    COALESCE(NULLIF(TRIM(BOTH FROM "pv"."metodo"), ''::"text"), 'Otro'::"text") AS "metodo",
    "pv"."fecha",
    "pv"."venta_id",
    NULL::bigint AS "gasto_id",
    NULL::bigint AS "pago_empleado_id"
   FROM "public"."pagos_venta" "pv"
  WHERE "public"."app_es_admin"()
UNION ALL
 SELECT "pg"."id",
    'pago_gasto'::"text" AS "origen",
    "pg"."id" AS "origen_id",
    ('Pago de Gasto: '::"text" || COALESCE("g"."categoria", 'Varios'::"text")) AS "descripcion",
    "pg"."monto",
    'egreso'::"text" AS "tipo",
    COALESCE(NULLIF(TRIM(BOTH FROM "pg"."metodo"), ''::"text"), 'Otro'::"text") AS "metodo",
    "pg"."fecha",
    NULL::bigint AS "venta_id",
    "pg"."gasto_id",
    NULL::bigint AS "pago_empleado_id"
   FROM ("public"."pagos_gasto" "pg"
     LEFT JOIN "public"."gastos" "g" ON (("g"."id" = "pg"."gasto_id")))
  WHERE "public"."app_es_admin"()
UNION ALL
 SELECT "pe"."id",
    'pago_empleado'::"text" AS "origen",
    "pe"."id" AS "origen_id",
    (('Pago a Personal: '::"text" || COALESCE("e"."nombre", 'Empleado'::"text")) ||
        CASE
            WHEN (NULLIF(TRIM(BOTH FROM COALESCE("pe"."concepto", ''::"text")), ''::"text") IS NULL) THEN ''::"text"
            ELSE (' - '::"text" || "pe"."concepto")
        END) AS "descripcion",
    "pe"."monto",
    'egreso'::"text" AS "tipo",
    COALESCE(NULLIF(TRIM(BOTH FROM "pe"."metodo"), ''::"text"), 'Otro'::"text") AS "metodo",
    "pe"."fecha",
    NULL::bigint AS "venta_id",
    NULL::bigint AS "gasto_id",
    "pe"."id" AS "pago_empleado_id"
   FROM ("public"."pagos_empleados" "pe"
     LEFT JOIN "public"."empleados" "e" ON (("e"."id" = "pe"."empleado_id")))
  WHERE "public"."app_es_admin"();
ALTER VIEW "public"."reportes_movimientos_financieros" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."series_comprobantes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tipo_documento_sunat" "text" NOT NULL,
    "serie" "text" NOT NULL,
    "ultimo_correlativo" bigint DEFAULT 0 NOT NULL,
    "activo" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "series_comprobantes_serie_check" CHECK (("serie" = "upper"("serie")))
);
ALTER TABLE "public"."series_comprobantes" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."sesiones_caja" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "usuario_id" "uuid",
    "fecha_apertura" timestamp with time zone DEFAULT "now"() NOT NULL,
    "monto_apertura" numeric NOT NULL,
    "fecha_cierre" timestamp with time zone,
    "monto_cierre_esperado" numeric,
    "monto_cierre_real" numeric,
    "estado" "text" DEFAULT 'ABIERTA'::"text" NOT NULL,
    "observaciones" "text",
    CONSTRAINT "sesiones_caja_estado_check" CHECK (("estado" = ANY (ARRAY['ABIERTA'::"text", 'CERRADA'::"text"])))
);
ALTER TABLE "public"."sesiones_caja" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."solicitudes_baja_tributaria" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "request_id" "uuid" NOT NULL,
    "tipo_origen" "text" NOT NULL,
    "comprobante_id" "uuid",
    "nota_credito_id" "uuid",
    "venta_id" bigint NOT NULL,
    "tipo_proceso" "text" NOT NULL,
    "tipo_doc" "text" NOT NULL,
    "serie" "text" NOT NULL,
    "correlativo" bigint NOT NULL,
    "fecha_documento" "date" NOT NULL,
    "motivo" "text" NOT NULL,
    "moneda" "text" DEFAULT 'PEN'::"text" NOT NULL,
    "base_imponible" numeric(14,2) DEFAULT 0 NOT NULL,
    "igv" numeric(14,2) DEFAULT 0 NOT NULL,
    "total" numeric(14,2) DEFAULT 0 NOT NULL,
    "cliente_tipo" "text",
    "cliente_numero" "text",
    "estado" "text" DEFAULT 'pendiente'::"text" NOT NULL,
    "proceso_id" "uuid",
    "creado_por" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "aceptado_at" timestamp with time zone,
    CONSTRAINT "solicitudes_baja_estado_check" CHECK (("estado" = ANY (ARRAY['pendiente'::"text", 'agrupada'::"text", 'ticket_pendiente'::"text", 'pendiente_reintento'::"text", 'resultado_incierto'::"text", 'aceptada'::"text", 'rechazada'::"text", 'cancelada'::"text"]))),
    CONSTRAINT "solicitudes_baja_motivo_check" CHECK ((("length"(TRIM(BOTH FROM "motivo")) >= 3) AND ("length"(TRIM(BOTH FROM "motivo")) <= 250))),
    CONSTRAINT "solicitudes_baja_origen_check" CHECK (((("tipo_origen" = 'comprobante'::"text") AND ("comprobante_id" IS NOT NULL) AND ("nota_credito_id" IS NULL)) OR (("tipo_origen" = 'nota_credito'::"text") AND ("nota_credito_id" IS NOT NULL) AND ("comprobante_id" IS NULL)))),
    CONSTRAINT "solicitudes_baja_serie_check" CHECK (("serie" = "upper"("serie"))),
    CONSTRAINT "solicitudes_baja_tipo_proceso_check" CHECK (("tipo_proceso" = ANY (ARRAY['resumen_boletas'::"text", 'comunicacion_baja'::"text"])))
);
ALTER TABLE "public"."solicitudes_baja_tributaria" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."stock_alert_tx_context" (
    "txid" bigint NOT NULL,
    "producto_id" bigint NOT NULL,
    "delta_total" bigint DEFAULT 0 NOT NULL
);
ALTER TABLE "public"."stock_alert_tx_context" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."sys_processed_requests" (
    "request_id" "uuid" NOT NULL,
    "producto_id" bigint,
    "resultado" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);
ALTER TABLE "public"."sys_processed_requests" OWNER TO "postgres";
CREATE TABLE IF NOT EXISTS "public"."transferencias_stock" (
    "id" bigint NOT NULL,
    "producto_id" bigint,
    "almacen_origen_id" bigint,
    "almacen_destino_id" bigint,
    "cantidad" integer NOT NULL,
    "fecha" timestamp with time zone DEFAULT "now"(),
    "request_id" "uuid",
    "motivo" "text",
    "movimiento_salida_id" bigint,
    "movimiento_entrada_id" bigint
);
ALTER TABLE "public"."transferencias_stock" OWNER TO "postgres";
CREATE SEQUENCE IF NOT EXISTS "public"."transferencias_stock_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE "public"."transferencias_stock_id_seq" OWNER TO "postgres";
ALTER SEQUENCE "public"."transferencias_stock_id_seq" OWNED BY "public"."transferencias_stock"."id";
CREATE TABLE IF NOT EXISTS "public"."ventas" (
    "id" bigint NOT NULL,
    "cliente_id" bigint,
    "total" numeric NOT NULL,
    "estado" "text",
    "saldo" numeric,
    "fecha" timestamp with time zone DEFAULT "now"(),
    "tipo_comprobante_solicitado" "text" DEFAULT 'ticket_interno'::"text",
    "estado_facturacion" "text" DEFAULT 'no_aplica'::"text",
    "subtotal_bruto" numeric(14,2) DEFAULT 0,
    "descuento_global_porcentaje" numeric(7,4) DEFAULT 0,
    "descuento_global_monto" numeric(14,2) DEFAULT 0,
    "motivo_descuento" "text",
    "vendedor_id" bigint,
    "request_id" "uuid",
    "descuento_autorizado_por" bigint,
    "descuento_autorizado_at" timestamp with time zone,
    "monto_notas_credito" numeric(14,2) DEFAULT 0 NOT NULL,
    "estado_tributario" "text" DEFAULT 'vigente'::"text" NOT NULL,
    "fue_credito" boolean DEFAULT false NOT NULL
);
ALTER TABLE "public"."ventas" OWNER TO "postgres";
CREATE SEQUENCE IF NOT EXISTS "public"."ventas_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;
ALTER SEQUENCE "public"."ventas_id_seq" OWNER TO "postgres";
ALTER SEQUENCE "public"."ventas_id_seq" OWNED BY "public"."ventas"."id";
CREATE TABLE IF NOT EXISTS "public"."ventas_requests_anulados" (
    "request_id" "uuid" NOT NULL,
    "venta_id_original" bigint NOT NULL,
    "anulada_por" "uuid",
    "anulada_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "vendedor_id_original" bigint,
    "vendedor_nombre_snapshot" "text",
    "anulada_por_empleado_id" bigint,
    "anulada_por_nombre_snapshot" "text",
    "motivo" "text",
    "venta_snapshot" "jsonb"
);
ALTER TABLE "public"."ventas_requests_anulados" OWNER TO "postgres";
ALTER TABLE ONLY "public"."almacenes" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."almacenes_id_seq"'::"regclass");
ALTER TABLE ONLY "public"."clientes" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."clientes_id_seq"'::"regclass");
ALTER TABLE ONLY "public"."detalle_ventas" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."detalle_ventas_id_seq"'::"regclass");
ALTER TABLE ONLY "public"."empleados" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."empleados_id_seq"'::"regclass");
ALTER TABLE ONLY "public"."gastos" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."gastos_id_seq"'::"regclass");
ALTER TABLE ONLY "public"."inventario_almacen" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."inventario_almacen_id_seq"'::"regclass");
ALTER TABLE ONLY "public"."pagos_empleados" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."pagos_empleados_id_seq"'::"regclass");
ALTER TABLE ONLY "public"."pagos_gasto" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."pagos_gasto_id_seq"'::"regclass");
ALTER TABLE ONLY "public"."pagos_venta" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."pagos_venta_id_seq"'::"regclass");
ALTER TABLE ONLY "public"."productos" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."productos_id_seq"'::"regclass");
ALTER TABLE ONLY "public"."proveedores" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."proveedores_id_seq"'::"regclass");
ALTER TABLE ONLY "public"."transferencias_stock" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."transferencias_stock_id_seq"'::"regclass");
ALTER TABLE ONLY "public"."ventas" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."ventas_id_seq"'::"regclass");
ALTER TABLE ONLY "public"."almacenes"
    ADD CONSTRAINT "almacenes_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."clientes"
    ADD CONSTRAINT "clientes_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."comprobantes_electronicos"
    ADD CONSTRAINT "comprobantes_electronicos_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."comprobantes_electronicos"
    ADD CONSTRAINT "comprobantes_electronicos_request_unique" UNIQUE ("request_id");
ALTER TABLE ONLY "public"."comprobantes_electronicos"
    ADD CONSTRAINT "comprobantes_electronicos_unique" UNIQUE ("tipo_documento_sunat", "serie", "correlativo");
ALTER TABLE "public"."configuracion_negocio"
    ADD CONSTRAINT "configuracion_negocio_ambiente_check" CHECK (("ambiente_facturacion" = ANY (ARRAY['beta'::"text", 'produccion'::"text", 'nubefact_beta'::"text", 'nubefact_produccion'::"text"]))) NOT VALID;
ALTER TABLE "public"."configuracion_negocio"
    ADD CONSTRAINT "configuracion_negocio_igv_check" CHECK ((("porcentaje_igv" >= (0)::numeric) AND ("porcentaje_igv" <= (100)::numeric))) NOT VALID;
ALTER TABLE ONLY "public"."configuracion_negocio"
    ADD CONSTRAINT "configuracion_negocio_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."constancias_descuento"
    ADD CONSTRAINT "constancias_descuento_codigo_key" UNIQUE ("codigo");
ALTER TABLE ONLY "public"."constancias_descuento"
    ADD CONSTRAINT "constancias_descuento_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."correlativos_procesos_tributarios"
    ADD CONSTRAINT "correlativos_procesos_tributarios_pkey" PRIMARY KEY ("tipo_proceso", "fecha_referencia");
ALTER TABLE "public"."cotizaciones"
    ADD CONSTRAINT "cotizaciones_estado_check" CHECK (("lower"("estado") = ANY (ARRAY['pendiente'::"text", 'aprobada'::"text", 'anulada'::"text", 'vencida'::"text"]))) NOT VALID;
ALTER TABLE ONLY "public"."cotizaciones"
    ADD CONSTRAINT "cotizaciones_pkey" PRIMARY KEY ("id");
ALTER TABLE "public"."cotizaciones"
    ADD CONSTRAINT "cotizaciones_total_check" CHECK (("total" > (0)::numeric)) NOT VALID;
ALTER TABLE "public"."cotizaciones"
    ADD CONSTRAINT "cotizaciones_validez_check" CHECK ((("validez_dias" >= 1) AND ("validez_dias" <= 3650))) NOT VALID;
ALTER TABLE "public"."detalle_cotizaciones"
    ADD CONSTRAINT "detalle_cotizaciones_cantidad_check" CHECK (("cantidad" > 0)) NOT VALID;
ALTER TABLE "public"."detalle_cotizaciones"
    ADD CONSTRAINT "detalle_cotizaciones_piezas_check" CHECK (("piezas_reales" > 0)) NOT VALID;
ALTER TABLE ONLY "public"."detalle_cotizaciones"
    ADD CONSTRAINT "detalle_cotizaciones_pkey" PRIMARY KEY ("id");
ALTER TABLE "public"."detalle_cotizaciones"
    ADD CONSTRAINT "detalle_cotizaciones_precios_check" CHECK ((("precio_unitario" >= (0)::numeric) AND ("precio_unitario_comercial" >= (0)::numeric) AND ("subtotal" >= (0)::numeric))) NOT VALID;
ALTER TABLE "public"."detalle_cotizaciones"
    ADD CONSTRAINT "detalle_cotizaciones_tipo_unidad_check" CHECK (("tipo_unidad" = ANY (ARRAY['caja'::"text", 'paquete'::"text", 'unidad'::"text"]))) NOT VALID;
ALTER TABLE "public"."detalle_cotizaciones"
    ADD CONSTRAINT "detalle_cotizaciones_tipo_venta_check" CHECK (("tipo_venta_snapshot" = ANY (ARRAY['PAQUETES'::"text", 'CAJA_PAQUETES'::"text", 'CAJA_UNIDADES'::"text"]))) NOT VALID;
ALTER TABLE ONLY "public"."detalle_ventas"
    ADD CONSTRAINT "detalle_ventas_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."documentos_tributarios_reconciliaciones"
    ADD CONSTRAINT "documentos_tributarios_reconciliaciones_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."empleados"
    ADD CONSTRAINT "empleados_email_key" UNIQUE ("email");
ALTER TABLE ONLY "public"."empleados"
    ADD CONSTRAINT "empleados_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."facturacion_intentos"
    ADD CONSTRAINT "facturacion_intentos_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."facturacion_intentos"
    ADD CONSTRAINT "facturacion_intentos_unique" UNIQUE ("comprobante_id", "numero_intento");
ALTER TABLE ONLY "public"."gastos"
    ADD CONSTRAINT "gastos_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."gre_conductores"
    ADD CONSTRAINT "gre_conductores_documento_unique" UNIQUE ("tipo_documento", "numero_documento");
ALTER TABLE ONLY "public"."gre_conductores"
    ADD CONSTRAINT "gre_conductores_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."gre_transportistas_agencias"
    ADD CONSTRAINT "gre_transportistas_agencias_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."gre_transportistas"
    ADD CONSTRAINT "gre_transportistas_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."gre_transportistas"
    ADD CONSTRAINT "gre_transportistas_ruc_unique" UNIQUE ("ruc");
ALTER TABLE ONLY "public"."gre_ubigeos"
    ADD CONSTRAINT "gre_ubigeos_pkey" PRIMARY KEY ("codigo");
ALTER TABLE ONLY "public"."gre_vehiculos"
    ADD CONSTRAINT "gre_vehiculos_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."gre_vehiculos"
    ADD CONSTRAINT "gre_vehiculos_placa_unique" UNIQUE ("placa");
ALTER TABLE ONLY "public"."guias_remision_detalles"
    ADD CONSTRAINT "guias_remision_detalles_pkey" PRIMARY KEY ("id");
ALTER TABLE "public"."guias_remision"
    ADD CONSTRAINT "guias_remision_direcciones_detalladas_check" CHECK ((("estado" = 'borrador'::"text") OR (("char_length"(TRIM(BOTH FROM COALESCE("partida_direccion", ''::"text"))) >= 5) AND ("char_length"(TRIM(BOTH FROM COALESCE("llegada_direccion", ''::"text"))) >= 5)))) NOT VALID;
ALTER TABLE ONLY "public"."guias_remision_intentos"
    ADD CONSTRAINT "guias_remision_intentos_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."guias_remision_intentos"
    ADD CONSTRAINT "guias_remision_intentos_unique" UNIQUE ("guia_id", "numero_intento");
ALTER TABLE ONLY "public"."guias_remision"
    ADD CONSTRAINT "guias_remision_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."guias_remision"
    ADD CONSTRAINT "guias_remision_request_id_key" UNIQUE ("request_id");
ALTER TABLE ONLY "public"."guias_remision"
    ADD CONSTRAINT "guias_remision_serie_correlativo_unique" UNIQUE ("tipo_documento_sunat", "serie", "correlativo");
ALTER TABLE ONLY "public"."inventario_almacen"
    ADD CONSTRAINT "inventario_almacen_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."inventario_almacen"
    ADD CONSTRAINT "inventario_almacen_producto_id_almacen_id_key" UNIQUE ("producto_id", "almacen_id");
ALTER TABLE ONLY "public"."inventario_movimientos"
    ADD CONSTRAINT "inventario_movimientos_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."inventario_operaciones_idempotentes"
    ADD CONSTRAINT "inventario_operaciones_idempotentes_pkey" PRIMARY KEY ("request_id");
ALTER TABLE ONLY "public"."notas_credito_detalles"
    ADD CONSTRAINT "notas_credito_detalles_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."notas_credito_intentos"
    ADD CONSTRAINT "notas_credito_intentos_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."notas_credito_intentos"
    ADD CONSTRAINT "notas_credito_intentos_unique" UNIQUE ("nota_credito_id", "numero_intento");
ALTER TABLE ONLY "public"."notas_credito"
    ADD CONSTRAINT "notas_credito_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."notas_credito"
    ADD CONSTRAINT "notas_credito_request_id_key" UNIQUE ("request_id");
ALTER TABLE ONLY "public"."notas_credito"
    ADD CONSTRAINT "notas_credito_serie_correlativo_unique" UNIQUE ("serie", "correlativo");
ALTER TABLE ONLY "public"."pagos_deuda_requests"
    ADD CONSTRAINT "pagos_deuda_requests_pkey" PRIMARY KEY ("request_id");
ALTER TABLE ONLY "public"."pagos_empleados"
    ADD CONSTRAINT "pagos_empleados_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."pagos_gasto"
    ADD CONSTRAINT "pagos_gasto_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."pagos_venta"
    ADD CONSTRAINT "pagos_venta_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."personas_cache"
    ADD CONSTRAINT "personas_cache_numero_key" UNIQUE ("numero");
ALTER TABLE ONLY "public"."personas_cache"
    ADD CONSTRAINT "personas_cache_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."procesos_tributarios_detalles"
    ADD CONSTRAINT "procesos_tributarios_detalles_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."procesos_tributarios_detalles"
    ADD CONSTRAINT "procesos_tributarios_detalles_solicitud_id_key" UNIQUE ("solicitud_id");
ALTER TABLE ONLY "public"."procesos_tributarios"
    ADD CONSTRAINT "procesos_tributarios_identificador_key" UNIQUE ("identificador");
ALTER TABLE ONLY "public"."procesos_tributarios_intentos"
    ADD CONSTRAINT "procesos_tributarios_intentos_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."procesos_tributarios_intentos"
    ADD CONSTRAINT "procesos_tributarios_intentos_unique" UNIQUE ("proceso_id", "numero_intento");
ALTER TABLE ONLY "public"."procesos_tributarios"
    ADD CONSTRAINT "procesos_tributarios_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."procesos_tributarios"
    ADD CONSTRAINT "procesos_tributarios_request_id_key" UNIQUE ("request_id");
ALTER TABLE ONLY "public"."procesos_tributarios"
    ADD CONSTRAINT "procesos_tributarios_unique" UNIQUE ("tipo_proceso", "fecha_referencia", "correlativo");
ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."proveedores"
    ADD CONSTRAINT "proveedores_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."series_comprobantes"
    ADD CONSTRAINT "series_comprobantes_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."series_comprobantes"
    ADD CONSTRAINT "series_comprobantes_unique" UNIQUE ("tipo_documento_sunat", "serie");
ALTER TABLE ONLY "public"."sesiones_caja"
    ADD CONSTRAINT "sesiones_caja_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."solicitudes_baja_tributaria"
    ADD CONSTRAINT "solicitudes_baja_tributaria_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."solicitudes_baja_tributaria"
    ADD CONSTRAINT "solicitudes_baja_tributaria_request_id_key" UNIQUE ("request_id");
ALTER TABLE ONLY "public"."stock_alert_tx_context"
    ADD CONSTRAINT "stock_alert_tx_context_pkey" PRIMARY KEY ("txid", "producto_id");
ALTER TABLE ONLY "public"."sys_processed_requests"
    ADD CONSTRAINT "sys_processed_requests_pkey" PRIMARY KEY ("request_id");
ALTER TABLE ONLY "public"."transferencias_stock"
    ADD CONSTRAINT "transferencias_stock_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."ventas"
    ADD CONSTRAINT "ventas_pkey" PRIMARY KEY ("id");
ALTER TABLE ONLY "public"."ventas_requests_anulados"
    ADD CONSTRAINT "ventas_requests_anulados_pkey" PRIMARY KEY ("request_id");
CREATE UNIQUE INDEX "clientes_dni_ruc_unique" ON "public"."clientes" USING "btree" ("dni_ruc") WHERE (("dni_ruc" IS NOT NULL) AND ("dni_ruc" <> ''::"text"));
CREATE INDEX "cotizaciones_cliente_id_idx" ON "public"."cotizaciones" USING "btree" ("cliente_id");
CREATE INDEX "cotizaciones_estado_idx" ON "public"."cotizaciones" USING "btree" ("estado");
CREATE INDEX "cotizaciones_fecha_idx" ON "public"."cotizaciones" USING "btree" ("fecha" DESC);
CREATE UNIQUE INDEX "cotizaciones_request_id_uidx" ON "public"."cotizaciones" USING "btree" ("request_id");
CREATE INDEX "detalle_cotizaciones_almacen_id_idx" ON "public"."detalle_cotizaciones" USING "btree" ("almacen_id");
CREATE INDEX "detalle_cotizaciones_cotizacion_id_idx" ON "public"."detalle_cotizaciones" USING "btree" ("cotizacion_id");
CREATE INDEX "detalle_cotizaciones_producto_id_idx" ON "public"."detalle_cotizaciones" USING "btree" ("producto_id");
CREATE INDEX "gre_transportistas_agencias_transportista_idx" ON "public"."gre_transportistas_agencias" USING "btree" ("transportista_id", "activo");
CREATE UNIQUE INDEX "gre_transportistas_agencias_unique_active" ON "public"."gre_transportistas_agencias" USING "btree" ("transportista_id", "lower"(TRIM(BOTH FROM "nombre")), "ubigeo", "lower"(TRIM(BOTH FROM "direccion"))) WHERE ("activo" = true);
CREATE INDEX "guias_remision_transbordo_idx" ON "public"."guias_remision" USING "btree" ("ind_transbordo", "created_at" DESC) WHERE ("ind_transbordo" = true);
CREATE INDEX "idx_comprobantes_bloqueo" ON "public"."comprobantes_electronicos" USING "btree" ("bloqueo_expira_at") WHERE ("estado" = 'procesando'::"text");
CREATE INDEX "idx_comprobantes_estado" ON "public"."comprobantes_electronicos" USING "btree" ("estado");
CREATE INDEX "idx_comprobantes_pendientes" ON "public"."comprobantes_electronicos" USING "btree" ("estado", "ultimo_intento_at", "created_at", "id") WHERE ("estado" = ANY (ARRAY['pendiente'::"text", 'pendiente_envio'::"text", 'pendiente_reintento'::"text", 'procesando'::"text"]));
CREATE INDEX "idx_comprobantes_resultado_incierto" ON "public"."comprobantes_electronicos" USING "btree" ("ultimo_intento_at", "created_at", "id") WHERE ("estado" = 'resultado_incierto'::"text");
CREATE INDEX "idx_comprobantes_venta" ON "public"."comprobantes_electronicos" USING "btree" ("venta_id");
CREATE INDEX "idx_constancias_descuento_venta" ON "public"."constancias_descuento" USING "btree" ("venta_id");
CREATE INDEX "idx_detalle_ventas_venta" ON "public"."detalle_ventas" USING "btree" ("venta_id");
CREATE INDEX "idx_facturacion_intentos_accion_fecha" ON "public"."facturacion_intentos" USING "btree" ("comprobante_id", "accion", "created_at" DESC);
CREATE INDEX "idx_facturacion_intentos_comprobante" ON "public"."facturacion_intentos" USING "btree" ("comprobante_id", "numero_intento" DESC);
CREATE INDEX "idx_facturacion_intentos_comprobante_fecha" ON "public"."facturacion_intentos" USING "btree" ("comprobante_id", "numero_intento" DESC, "created_at" DESC);
CREATE INDEX "idx_gre_ubigeos_busqueda" ON "public"."gre_ubigeos" USING "btree" ("departamento", "provincia", "distrito");
CREATE INDEX "idx_guias_remision_detalles_guia" ON "public"."guias_remision_detalles" USING "btree" ("guia_id", "id");
CREATE INDEX "idx_guias_remision_estado" ON "public"."guias_remision" USING "btree" ("estado", "created_at" DESC);
CREATE INDEX "idx_guias_remision_intentos_guia" ON "public"."guias_remision_intentos" USING "btree" ("guia_id", "numero_intento" DESC);
CREATE INDEX "idx_guias_remision_pendientes" ON "public"."guias_remision" USING "btree" ("ultimo_intento_at", "created_at", "id") WHERE ("estado" = ANY (ARRAY['pendiente_envio'::"text", 'ticket_pendiente'::"text", 'pendiente_reintento'::"text", 'procesando'::"text"]));
CREATE INDEX "idx_guias_remision_ticket" ON "public"."guias_remision" USING "btree" ("ticket_sunat") WHERE ("ticket_sunat" IS NOT NULL);
CREATE INDEX "idx_guias_remision_transferencia" ON "public"."guias_remision" USING "btree" ("transferencia_id", "created_at" DESC);
CREATE INDEX "idx_guias_remision_venta" ON "public"."guias_remision" USING "btree" ("venta_id", "created_at" DESC);
CREATE INDEX "idx_guias_resultado_incierto" ON "public"."guias_remision" USING "btree" ("ultimo_intento_at", "created_at", "id") WHERE ("estado" = 'resultado_incierto'::"text");
CREATE INDEX "idx_inv_mov_anulado_por" ON "public"."inventario_movimientos" USING "btree" ("anulado_por_id");
CREATE INDEX "idx_inv_mov_venta_original" ON "public"."inventario_movimientos" USING "btree" ("venta_id_original");
CREATE INDEX "idx_inventario_movimientos_almacen_fecha_id" ON "public"."inventario_movimientos" USING "btree" ("almacen_id", "fecha" DESC, "id" DESC);
CREATE INDEX "idx_inventario_movimientos_fecha_id" ON "public"."inventario_movimientos" USING "btree" ("fecha" DESC, "id" DESC);
CREATE INDEX "idx_inventario_movimientos_producto_fecha_id" ON "public"."inventario_movimientos" USING "btree" ("producto_id", "fecha" DESC, "id" DESC);
CREATE INDEX "idx_inventario_movimientos_producto_id" ON "public"."inventario_movimientos" USING "btree" ("producto_id");
CREATE INDEX "idx_inventario_movimientos_request_id" ON "public"."inventario_movimientos" USING "btree" ("request_id") WHERE ("request_id" IS NOT NULL);
CREATE INDEX "idx_inventario_movimientos_tipo_fecha_id" ON "public"."inventario_movimientos" USING "btree" ("tipo", "fecha" DESC, "id" DESC);
CREATE INDEX "idx_inventario_movimientos_vendedor" ON "public"."inventario_movimientos" USING "btree" ("vendedor_id");
CREATE INDEX "idx_inventario_movimientos_venta" ON "public"."inventario_movimientos" USING "btree" ("venta_id");
CREATE INDEX "idx_notas_credito_comprobante" ON "public"."notas_credito" USING "btree" ("comprobante_id", "created_at" DESC);
CREATE INDEX "idx_notas_credito_detalle_venta" ON "public"."notas_credito_detalles" USING "btree" ("detalle_venta_id");
CREATE INDEX "idx_notas_credito_intentos_fecha" ON "public"."notas_credito_intentos" USING "btree" ("nota_credito_id", "numero_intento" DESC, "created_at" DESC);
CREATE INDEX "idx_notas_credito_pendientes" ON "public"."notas_credito" USING "btree" ("created_at", "id") WHERE ("estado" = ANY (ARRAY['pendiente_envio'::"text", 'pendiente_reintento'::"text", 'procesando'::"text"]));
CREATE INDEX "idx_notas_credito_resultado_incierto" ON "public"."notas_credito" USING "btree" ("created_at", "id") WHERE ("estado" = 'resultado_incierto'::"text");
CREATE INDEX "idx_notas_credito_venta" ON "public"."notas_credito" USING "btree" ("venta_id", "created_at" DESC);
CREATE INDEX "idx_notas_resultado_incierto" ON "public"."notas_credito" USING "btree" ("ultimo_intento_at", "created_at", "id") WHERE ("estado" = 'resultado_incierto'::"text");
CREATE INDEX "idx_pagos_empleados_empleado_fecha" ON "public"."pagos_empleados" USING "btree" ("empleado_id", "fecha" DESC);
CREATE INDEX "idx_pagos_empleados_fecha_id" ON "public"."pagos_empleados" USING "btree" ("fecha" DESC, "id" DESC);
CREATE INDEX "idx_pagos_gasto_fecha_id" ON "public"."pagos_gasto" USING "btree" ("fecha" DESC, "id" DESC);
CREATE INDEX "idx_pagos_gasto_gasto_fecha" ON "public"."pagos_gasto" USING "btree" ("gasto_id", "fecha" DESC);
CREATE INDEX "idx_pagos_venta_fecha_id" ON "public"."pagos_venta" USING "btree" ("fecha" DESC, "id" DESC);
CREATE INDEX "idx_pagos_venta_venta_fecha" ON "public"."pagos_venta" USING "btree" ("venta_id", "fecha" DESC);
CREATE INDEX "idx_personas_cache_tipo_numero" ON "public"."personas_cache" USING "btree" ("tipo", "numero");
CREATE INDEX "idx_procesos_detalles_proceso" ON "public"."procesos_tributarios_detalles" USING "btree" ("proceso_id", "created_at");
CREATE INDEX "idx_procesos_intentos_fecha" ON "public"."procesos_tributarios_intentos" USING "btree" ("proceso_id", "numero_intento" DESC, "created_at" DESC);
CREATE INDEX "idx_procesos_resultado_incierto" ON "public"."procesos_tributarios" USING "btree" ("ultimo_intento_at", "created_at", "id") WHERE ("estado" = 'resultado_incierto'::"text");
CREATE INDEX "idx_procesos_tributarios_fecha" ON "public"."procesos_tributarios" USING "btree" ("tipo_proceso", "fecha_referencia", "created_at" DESC);
CREATE INDEX "idx_procesos_tributarios_pendientes" ON "public"."procesos_tributarios" USING "btree" ("estado", "ultimo_intento_at", "created_at", "id") WHERE ("estado" = ANY (ARRAY['pendiente_envio'::"text", 'procesando'::"text", 'ticket_pendiente'::"text", 'pendiente_reintento'::"text"]));
CREATE INDEX "idx_procesos_tributarios_ticket" ON "public"."procesos_tributarios" USING "btree" ("ticket_sunat") WHERE ("ticket_sunat" IS NOT NULL);
CREATE UNIQUE INDEX "idx_producto_unico" ON "public"."productos" USING "btree" ("lower"(TRIM(BOTH FROM "nombre")), COALESCE("proveedor_id", (0)::bigint), "tipo_venta");
CREATE INDEX "idx_reconciliaciones_documento" ON "public"."documentos_tributarios_reconciliaciones" USING "btree" ("tipo_documento", "documento_id", "created_at" DESC);
CREATE INDEX "idx_series_comprobantes_tipo_activo" ON "public"."series_comprobantes" USING "btree" ("tipo_documento_sunat", "activo");
CREATE INDEX "idx_solicitudes_baja_pendientes" ON "public"."solicitudes_baja_tributaria" USING "btree" ("tipo_proceso", "fecha_documento", "created_at", "id") WHERE ("estado" = ANY (ARRAY['pendiente'::"text", 'pendiente_reintento'::"text"]));
CREATE INDEX "idx_solicitudes_baja_venta" ON "public"."solicitudes_baja_tributaria" USING "btree" ("venta_id", "created_at" DESC);
CREATE INDEX "idx_sys_processed_requests_producto_id" ON "public"."sys_processed_requests" USING "btree" ("producto_id");
CREATE INDEX "idx_ventas_estado_facturacion" ON "public"."ventas" USING "btree" ("estado_facturacion");
CREATE INDEX "idx_ventas_fecha_facturacion" ON "public"."ventas" USING "btree" ("fecha", "estado_facturacion");
CREATE INDEX "idx_ventas_requests_anulados_venta" ON "public"."ventas_requests_anulados" USING "btree" ("venta_id_original");
CREATE INDEX "idx_ventas_tipo_comprobante" ON "public"."ventas" USING "btree" ("tipo_comprobante_solicitado");
CREATE UNIQUE INDEX "pagos_gasto_request_id_uidx" ON "public"."pagos_gasto" USING "btree" ("request_id") WHERE ("request_id" IS NOT NULL);
CREATE UNIQUE INDEX "pagos_venta_request_id_uidx" ON "public"."pagos_venta" USING "btree" ("request_id") WHERE ("request_id" IS NOT NULL);
CREATE UNIQUE INDEX "productos_codigo_unique" ON "public"."productos" USING "btree" ("upper"(TRIM(BOTH FROM "codigo"))) WHERE (("codigo" IS NOT NULL) AND (TRIM(BOTH FROM "codigo") <> ''::"text"));
CREATE UNIQUE INDEX "series_comprobantes_una_activa_por_tipo" ON "public"."series_comprobantes" USING "btree" ("tipo_documento_sunat") WHERE ("activo" = true);
CREATE UNIQUE INDEX "sesiones_caja_unica_abierta_idx" ON "public"."sesiones_caja" USING "btree" ((1)) WHERE ("estado" = 'ABIERTA'::"text");
CREATE UNIQUE INDEX "solicitudes_baja_comprobante_unique" ON "public"."solicitudes_baja_tributaria" USING "btree" ("comprobante_id") WHERE (("comprobante_id" IS NOT NULL) AND ("estado" <> 'cancelada'::"text"));
CREATE UNIQUE INDEX "solicitudes_baja_nota_unique" ON "public"."solicitudes_baja_tributaria" USING "btree" ("nota_credito_id") WHERE (("nota_credito_id" IS NOT NULL) AND ("estado" <> 'cancelada'::"text"));
CREATE UNIQUE INDEX "transferencias_stock_request_unique" ON "public"."transferencias_stock" USING "btree" ("request_id") WHERE ("request_id" IS NOT NULL);
CREATE UNIQUE INDEX "ventas_request_id_unique" ON "public"."ventas" USING "btree" ("request_id") WHERE ("request_id" IS NOT NULL);
CREATE OR REPLACE TRIGGER "trg_autoclasificar_tipo_doc" BEFORE INSERT OR UPDATE OF "dni_ruc", "tipo_doc" ON "public"."clientes" FOR EACH ROW EXECUTE FUNCTION "public"."fn_autoclasificar_tipo_doc_cliente"();
CREATE OR REPLACE TRIGGER "trg_comprobantes_electronicos_updated_at" BEFORE UPDATE ON "public"."comprobantes_electronicos" FOR EACH ROW EXECUTE FUNCTION "public"."set_facturacion_updated_at"();
CREATE OR REPLACE TRIGGER "trg_gre_conductores_updated_at" BEFORE UPDATE ON "public"."gre_conductores" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at_documentos_tributarios"();
CREATE OR REPLACE TRIGGER "trg_gre_normalizar_detalle_unidad" BEFORE INSERT OR UPDATE ON "public"."guias_remision_detalles" FOR EACH ROW EXECUTE FUNCTION "public"."gre_normalizar_detalle_unidad"();
CREATE OR REPLACE TRIGGER "trg_gre_transportistas_agencias_updated_at" BEFORE UPDATE ON "public"."gre_transportistas_agencias" FOR EACH ROW EXECUTE FUNCTION "public"."_gre_agencia_set_updated_at"();
CREATE OR REPLACE TRIGGER "trg_gre_transportistas_updated_at" BEFORE UPDATE ON "public"."gre_transportistas" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at_documentos_tributarios"();
CREATE OR REPLACE TRIGGER "trg_gre_vehiculos_updated_at" BEFORE UPDATE ON "public"."gre_vehiculos" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at_documentos_tributarios"();
CREATE OR REPLACE TRIGGER "trg_guias_remision_updated_at" BEFORE UPDATE ON "public"."guias_remision" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at_documentos_tributarios"();
CREATE OR REPLACE TRIGGER "trg_notas_credito_updated_at" BEFORE UPDATE ON "public"."notas_credito" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at_documentos_tributarios"();
CREATE OR REPLACE TRIGGER "trg_procesos_tributarios_updated_at" BEFORE UPDATE ON "public"."procesos_tributarios" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at_documentos_tributarios"();
CREATE OR REPLACE TRIGGER "trg_series_comprobantes_updated_at" BEFORE UPDATE ON "public"."series_comprobantes" FOR EACH ROW EXECUTE FUNCTION "public"."set_facturacion_updated_at"();
CREATE OR REPLACE TRIGGER "trg_set_vendedor_observaciones_kardex" BEFORE INSERT ON "public"."inventario_movimientos" FOR EACH ROW EXECUTE FUNCTION "public"."set_vendedor_observaciones_kardex"();
CREATE OR REPLACE TRIGGER "trg_set_venta_fue_credito" BEFORE INSERT ON "public"."ventas" FOR EACH ROW EXECUTE FUNCTION "public"."set_venta_fue_credito"();
CREATE OR REPLACE TRIGGER "trg_solicitudes_baja_updated_at" BEFORE UPDATE ON "public"."solicitudes_baja_tributaria" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at_documentos_tributarios"();
CREATE OR REPLACE TRIGGER "trg_validar_desactivacion_almacen_v1" BEFORE UPDATE OF "activo" ON "public"."almacenes" FOR EACH ROW EXECUTE FUNCTION "public"."_validar_desactivacion_almacen_v1"();
CREATE OR REPLACE TRIGGER "trg_validar_origen_nota_credito_vigente" BEFORE INSERT ON "public"."notas_credito" FOR EACH ROW EXECUTE FUNCTION "public"."validar_origen_nota_credito_vigente"();
CREATE OR REPLACE TRIGGER "trg_validar_stock_en_almacen_activo_v1" BEFORE INSERT OR UPDATE OF "almacen_id", "cantidad" ON "public"."inventario_almacen" FOR EACH ROW EXECUTE FUNCTION "public"."_validar_stock_en_almacen_activo_v1"();
CREATE OR REPLACE TRIGGER "trigger_stock_alert_acumular_tx" AFTER UPDATE OF "cantidad" ON "public"."inventario_almacen" FOR EACH ROW WHEN (("old"."cantidad" IS DISTINCT FROM "new"."cantidad")) EXECUTE FUNCTION "public"."_stock_alert_acumular_tx"();
CREATE CONSTRAINT TRIGGER "trigger_stock_alert_evaluar_tx" AFTER UPDATE ON "public"."inventario_almacen" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW WHEN (("old"."cantidad" IS DISTINCT FROM "new"."cantidad")) EXECUTE FUNCTION "public"."notificar_stock_bajo"();
ALTER TABLE ONLY "public"."comprobantes_electronicos"
    ADD CONSTRAINT "comprobantes_electronicos_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id");
ALTER TABLE ONLY "public"."comprobantes_electronicos"
    ADD CONSTRAINT "comprobantes_solicitud_baja_id_fkey" FOREIGN KEY ("solicitud_baja_id") REFERENCES "public"."solicitudes_baja_tributaria"("id");
ALTER TABLE ONLY "public"."constancias_descuento"
    ADD CONSTRAINT "constancias_descuento_aplicado_por_fkey" FOREIGN KEY ("aplicado_por") REFERENCES "public"."empleados"("id");
ALTER TABLE ONLY "public"."constancias_descuento"
    ADD CONSTRAINT "constancias_descuento_autorizado_por_fkey" FOREIGN KEY ("autorizado_por") REFERENCES "public"."empleados"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."constancias_descuento"
    ADD CONSTRAINT "constancias_descuento_comprobante_id_fkey" FOREIGN KEY ("comprobante_id") REFERENCES "public"."comprobantes_electronicos"("id");
ALTER TABLE ONLY "public"."constancias_descuento"
    ADD CONSTRAINT "constancias_descuento_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id");
ALTER TABLE ONLY "public"."cotizaciones"
    ADD CONSTRAINT "cotizaciones_cliente_id_fkey" FOREIGN KEY ("cliente_id") REFERENCES "public"."clientes"("id");
ALTER TABLE ONLY "public"."detalle_cotizaciones"
    ADD CONSTRAINT "detalle_cotizaciones_almacen_id_fkey" FOREIGN KEY ("almacen_id") REFERENCES "public"."almacenes"("id");
ALTER TABLE ONLY "public"."detalle_cotizaciones"
    ADD CONSTRAINT "detalle_cotizaciones_cotizacion_id_fkey" FOREIGN KEY ("cotizacion_id") REFERENCES "public"."cotizaciones"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."detalle_cotizaciones"
    ADD CONSTRAINT "detalle_cotizaciones_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id");
ALTER TABLE ONLY "public"."detalle_ventas"
    ADD CONSTRAINT "detalle_ventas_almacen_id_fkey" FOREIGN KEY ("almacen_id") REFERENCES "public"."almacenes"("id");
ALTER TABLE ONLY "public"."detalle_ventas"
    ADD CONSTRAINT "detalle_ventas_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id");
ALTER TABLE ONLY "public"."detalle_ventas"
    ADD CONSTRAINT "detalle_ventas_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."empleados"
    ADD CONSTRAINT "empleados_auth_id_fkey" FOREIGN KEY ("auth_id") REFERENCES "auth"."users"("id");
ALTER TABLE ONLY "public"."empleados"
    ADD CONSTRAINT "empleados_creado_por_fkey" FOREIGN KEY ("creado_por") REFERENCES "auth"."users"("id");
ALTER TABLE ONLY "public"."empleados"
    ADD CONSTRAINT "empleados_eliminado_por_fkey" FOREIGN KEY ("eliminado_por") REFERENCES "auth"."users"("id");
ALTER TABLE ONLY "public"."facturacion_intentos"
    ADD CONSTRAINT "facturacion_intentos_comprobante_id_fkey" FOREIGN KEY ("comprobante_id") REFERENCES "public"."comprobantes_electronicos"("id");
ALTER TABLE ONLY "public"."gastos"
    ADD CONSTRAINT "gastos_proveedor_id_fkey" FOREIGN KEY ("proveedor_id") REFERENCES "public"."proveedores"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."gre_transportistas_agencias"
    ADD CONSTRAINT "gre_transportistas_agencias_transportista_id_fkey" FOREIGN KEY ("transportista_id") REFERENCES "public"."gre_transportistas"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."gre_vehiculos"
    ADD CONSTRAINT "gre_vehiculos_transportista_id_fkey" FOREIGN KEY ("transportista_id") REFERENCES "public"."gre_transportistas"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."guias_remision"
    ADD CONSTRAINT "guias_remision_agencia_destino_id_fkey" FOREIGN KEY ("agencia_destino_id") REFERENCES "public"."gre_transportistas_agencias"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."guias_remision"
    ADD CONSTRAINT "guias_remision_agencia_origen_id_fkey" FOREIGN KEY ("agencia_origen_id") REFERENCES "public"."gre_transportistas_agencias"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."guias_remision"
    ADD CONSTRAINT "guias_remision_comprobante_id_fkey" FOREIGN KEY ("comprobante_id") REFERENCES "public"."comprobantes_electronicos"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."guias_remision"
    ADD CONSTRAINT "guias_remision_conductor_id_fkey" FOREIGN KEY ("conductor_id") REFERENCES "public"."gre_conductores"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."guias_remision_detalles"
    ADD CONSTRAINT "guias_remision_detalles_almacen_id_fkey" FOREIGN KEY ("almacen_id") REFERENCES "public"."almacenes"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."guias_remision_detalles"
    ADD CONSTRAINT "guias_remision_detalles_detalle_venta_id_fkey" FOREIGN KEY ("detalle_venta_id") REFERENCES "public"."detalle_ventas"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."guias_remision_detalles"
    ADD CONSTRAINT "guias_remision_detalles_guia_id_fkey" FOREIGN KEY ("guia_id") REFERENCES "public"."guias_remision"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."guias_remision_detalles"
    ADD CONSTRAINT "guias_remision_detalles_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."guias_remision_detalles"
    ADD CONSTRAINT "guias_remision_detalles_transferencia_id_fkey" FOREIGN KEY ("transferencia_id") REFERENCES "public"."transferencias_stock"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."guias_remision"
    ADD CONSTRAINT "guias_remision_guia_remitente_id_fkey" FOREIGN KEY ("guia_remitente_id") REFERENCES "public"."guias_remision"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."guias_remision_intentos"
    ADD CONSTRAINT "guias_remision_intentos_guia_id_fkey" FOREIGN KEY ("guia_id") REFERENCES "public"."guias_remision"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."guias_remision"
    ADD CONSTRAINT "guias_remision_transferencia_id_fkey" FOREIGN KEY ("transferencia_id") REFERENCES "public"."transferencias_stock"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."guias_remision"
    ADD CONSTRAINT "guias_remision_transportista_id_fkey" FOREIGN KEY ("transportista_id") REFERENCES "public"."gre_transportistas"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."guias_remision"
    ADD CONSTRAINT "guias_remision_transportista_transbordo_id_fkey" FOREIGN KEY ("transportista_transbordo_id") REFERENCES "public"."gre_transportistas"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."guias_remision"
    ADD CONSTRAINT "guias_remision_vehiculo_id_fkey" FOREIGN KEY ("vehiculo_id") REFERENCES "public"."gre_vehiculos"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."guias_remision"
    ADD CONSTRAINT "guias_remision_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."inventario_almacen"
    ADD CONSTRAINT "inventario_almacen_almacen_id_fkey" FOREIGN KEY ("almacen_id") REFERENCES "public"."almacenes"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."inventario_almacen"
    ADD CONSTRAINT "inventario_almacen_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."inventario_movimientos"
    ADD CONSTRAINT "inventario_movimientos_almacen_id_fkey" FOREIGN KEY ("almacen_id") REFERENCES "public"."almacenes"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."inventario_movimientos"
    ADD CONSTRAINT "inventario_movimientos_anulado_por_id_fkey" FOREIGN KEY ("anulado_por_id") REFERENCES "public"."empleados"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."inventario_movimientos"
    ADD CONSTRAINT "inventario_movimientos_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."inventario_movimientos"
    ADD CONSTRAINT "inventario_movimientos_vendedor_id_fkey" FOREIGN KEY ("vendedor_id") REFERENCES "public"."empleados"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."inventario_movimientos"
    ADD CONSTRAINT "inventario_movimientos_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."inventario_operaciones_idempotentes"
    ADD CONSTRAINT "inventario_operaciones_idempotentes_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."notas_credito"
    ADD CONSTRAINT "notas_credito_comprobante_id_fkey" FOREIGN KEY ("comprobante_id") REFERENCES "public"."comprobantes_electronicos"("id");
ALTER TABLE ONLY "public"."notas_credito_detalles"
    ADD CONSTRAINT "notas_credito_detalles_almacen_id_fkey" FOREIGN KEY ("almacen_id") REFERENCES "public"."almacenes"("id");
ALTER TABLE ONLY "public"."notas_credito_detalles"
    ADD CONSTRAINT "notas_credito_detalles_detalle_venta_id_fkey" FOREIGN KEY ("detalle_venta_id") REFERENCES "public"."detalle_ventas"("id");
ALTER TABLE ONLY "public"."notas_credito_detalles"
    ADD CONSTRAINT "notas_credito_detalles_nota_credito_id_fkey" FOREIGN KEY ("nota_credito_id") REFERENCES "public"."notas_credito"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."notas_credito_detalles"
    ADD CONSTRAINT "notas_credito_detalles_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id");
ALTER TABLE ONLY "public"."notas_credito_intentos"
    ADD CONSTRAINT "notas_credito_intentos_nota_credito_id_fkey" FOREIGN KEY ("nota_credito_id") REFERENCES "public"."notas_credito"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."notas_credito"
    ADD CONSTRAINT "notas_credito_solicitud_baja_id_fkey" FOREIGN KEY ("solicitud_baja_id") REFERENCES "public"."solicitudes_baja_tributaria"("id");
ALTER TABLE ONLY "public"."notas_credito"
    ADD CONSTRAINT "notas_credito_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id");
ALTER TABLE ONLY "public"."pagos_deuda_requests"
    ADD CONSTRAINT "pagos_deuda_requests_empleado_id_fkey" FOREIGN KEY ("empleado_id") REFERENCES "public"."empleados"("id");
ALTER TABLE ONLY "public"."pagos_empleados"
    ADD CONSTRAINT "pagos_empleados_empleado_id_fkey" FOREIGN KEY ("empleado_id") REFERENCES "public"."empleados"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."pagos_gasto"
    ADD CONSTRAINT "pagos_gasto_gasto_id_fkey" FOREIGN KEY ("gasto_id") REFERENCES "public"."gastos"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."pagos_gasto"
    ADD CONSTRAINT "pagos_gasto_request_id_fkey" FOREIGN KEY ("request_id") REFERENCES "public"."pagos_deuda_requests"("request_id") ON DELETE RESTRICT;
ALTER TABLE ONLY "public"."pagos_venta"
    ADD CONSTRAINT "pagos_venta_request_id_fkey" FOREIGN KEY ("request_id") REFERENCES "public"."pagos_deuda_requests"("request_id") ON DELETE RESTRICT;
ALTER TABLE ONLY "public"."pagos_venta"
    ADD CONSTRAINT "pagos_venta_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."procesos_tributarios_detalles"
    ADD CONSTRAINT "procesos_tributarios_detalles_comprobante_id_fkey" FOREIGN KEY ("comprobante_id") REFERENCES "public"."comprobantes_electronicos"("id");
ALTER TABLE ONLY "public"."procesos_tributarios_detalles"
    ADD CONSTRAINT "procesos_tributarios_detalles_nota_credito_id_fkey" FOREIGN KEY ("nota_credito_id") REFERENCES "public"."notas_credito"("id");
ALTER TABLE ONLY "public"."procesos_tributarios_detalles"
    ADD CONSTRAINT "procesos_tributarios_detalles_proceso_id_fkey" FOREIGN KEY ("proceso_id") REFERENCES "public"."procesos_tributarios"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."procesos_tributarios_detalles"
    ADD CONSTRAINT "procesos_tributarios_detalles_solicitud_id_fkey" FOREIGN KEY ("solicitud_id") REFERENCES "public"."solicitudes_baja_tributaria"("id");
ALTER TABLE ONLY "public"."procesos_tributarios_detalles"
    ADD CONSTRAINT "procesos_tributarios_detalles_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id");
ALTER TABLE ONLY "public"."procesos_tributarios_intentos"
    ADD CONSTRAINT "procesos_tributarios_intentos_proceso_id_fkey" FOREIGN KEY ("proceso_id") REFERENCES "public"."procesos_tributarios"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_proveedor_id_fkey" FOREIGN KEY ("proveedor_id") REFERENCES "public"."proveedores"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."sesiones_caja"
    ADD CONSTRAINT "sesiones_caja_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "auth"."users"("id");
ALTER TABLE ONLY "public"."solicitudes_baja_tributaria"
    ADD CONSTRAINT "solicitudes_baja_proceso_id_fkey" FOREIGN KEY ("proceso_id") REFERENCES "public"."procesos_tributarios"("id");
ALTER TABLE ONLY "public"."solicitudes_baja_tributaria"
    ADD CONSTRAINT "solicitudes_baja_tributaria_comprobante_id_fkey" FOREIGN KEY ("comprobante_id") REFERENCES "public"."comprobantes_electronicos"("id");
ALTER TABLE ONLY "public"."solicitudes_baja_tributaria"
    ADD CONSTRAINT "solicitudes_baja_tributaria_nota_credito_id_fkey" FOREIGN KEY ("nota_credito_id") REFERENCES "public"."notas_credito"("id");
ALTER TABLE ONLY "public"."solicitudes_baja_tributaria"
    ADD CONSTRAINT "solicitudes_baja_tributaria_venta_id_fkey" FOREIGN KEY ("venta_id") REFERENCES "public"."ventas"("id");
ALTER TABLE ONLY "public"."stock_alert_tx_context"
    ADD CONSTRAINT "stock_alert_tx_context_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."transferencias_stock"
    ADD CONSTRAINT "transferencias_stock_almacen_destino_id_fkey" FOREIGN KEY ("almacen_destino_id") REFERENCES "public"."almacenes"("id");
ALTER TABLE ONLY "public"."transferencias_stock"
    ADD CONSTRAINT "transferencias_stock_almacen_origen_id_fkey" FOREIGN KEY ("almacen_origen_id") REFERENCES "public"."almacenes"("id");
ALTER TABLE ONLY "public"."transferencias_stock"
    ADD CONSTRAINT "transferencias_stock_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;
ALTER TABLE ONLY "public"."ventas"
    ADD CONSTRAINT "ventas_cliente_id_fkey" FOREIGN KEY ("cliente_id") REFERENCES "public"."clientes"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."ventas"
    ADD CONSTRAINT "ventas_descuento_autorizado_por_fkey" FOREIGN KEY ("descuento_autorizado_por") REFERENCES "public"."empleados"("id") ON DELETE SET NULL;
ALTER TABLE ONLY "public"."ventas"
    ADD CONSTRAINT "ventas_vendedor_id_fkey" FOREIGN KEY ("vendedor_id") REFERENCES "public"."empleados"("id");
ALTER TABLE "public"."almacenes" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "almacenes_admin_insert" ON "public"."almacenes" FOR INSERT TO "authenticated" WITH CHECK ("public"."app_es_admin"());
CREATE POLICY "almacenes_admin_update" ON "public"."almacenes" FOR UPDATE TO "authenticated" USING ("public"."app_es_admin"()) WITH CHECK ("public"."app_es_admin"());
CREATE POLICY "almacenes_select" ON "public"."almacenes" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
ALTER TABLE "public"."clientes" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "clientes_empleado_delete" ON "public"."clientes" FOR DELETE TO "authenticated" USING ("public"."app_empleado_activo"());
CREATE POLICY "clientes_empleado_insert" ON "public"."clientes" FOR INSERT TO "authenticated" WITH CHECK ("public"."app_empleado_activo"());
CREATE POLICY "clientes_empleado_select" ON "public"."clientes" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
CREATE POLICY "clientes_empleado_update" ON "public"."clientes" FOR UPDATE TO "authenticated" USING ("public"."app_empleado_activo"()) WITH CHECK ("public"."app_empleado_activo"());
ALTER TABLE "public"."comprobantes_electronicos" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "comprobantes_select" ON "public"."comprobantes_electronicos" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
ALTER TABLE "public"."configuracion_negocio" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "configuracion_select" ON "public"."configuracion_negocio" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
ALTER TABLE "public"."constancias_descuento" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "constancias_descuento_select" ON "public"."constancias_descuento" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
ALTER TABLE "public"."correlativos_procesos_tributarios" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."cotizaciones" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "cotizaciones_select_empleado" ON "public"."cotizaciones" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
ALTER TABLE "public"."detalle_cotizaciones" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "detalle_cotizaciones_select_empleado" ON "public"."detalle_cotizaciones" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
ALTER TABLE "public"."detalle_ventas" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "detalle_ventas_select" ON "public"."detalle_ventas" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
ALTER TABLE "public"."documentos_tributarios_reconciliaciones" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."empleados" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "empleados_admin_delete" ON "public"."empleados" FOR DELETE TO "authenticated" USING ("public"."app_es_admin"());
CREATE POLICY "empleados_admin_insert" ON "public"."empleados" FOR INSERT TO "authenticated" WITH CHECK ("public"."app_es_admin"());
CREATE POLICY "empleados_admin_update" ON "public"."empleados" FOR UPDATE TO "authenticated" USING ("public"."app_es_admin"()) WITH CHECK ("public"."app_es_admin"());
CREATE POLICY "empleados_select_activos" ON "public"."empleados" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
ALTER TABLE "public"."facturacion_intentos" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."gastos" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "gastos_delete_empleado" ON "public"."gastos" FOR DELETE TO "authenticated" USING ("public"."app_empleado_activo"());
CREATE POLICY "gastos_select_empleado" ON "public"."gastos" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
CREATE POLICY "gastos_update_empleado" ON "public"."gastos" FOR UPDATE TO "authenticated" USING ("public"."app_empleado_activo"()) WITH CHECK ("public"."app_empleado_activo"());
ALTER TABLE "public"."gre_conductores" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "gre_conductores_operativos" ON "public"."gre_conductores" TO "authenticated" USING ("public"."app_empleado_activo"()) WITH CHECK ("public"."app_empleado_activo"());
ALTER TABLE "public"."gre_transportistas" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."gre_transportistas_agencias" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "gre_transportistas_agencias_insert" ON "public"."gre_transportistas_agencias" FOR INSERT TO "authenticated" WITH CHECK ("public"."_gre_empleado_activo"());
CREATE POLICY "gre_transportistas_agencias_select" ON "public"."gre_transportistas_agencias" FOR SELECT TO "authenticated" USING ("public"."_gre_empleado_activo"());
CREATE POLICY "gre_transportistas_agencias_update" ON "public"."gre_transportistas_agencias" FOR UPDATE TO "authenticated" USING ("public"."_gre_empleado_activo"()) WITH CHECK ("public"."_gre_empleado_activo"());
CREATE POLICY "gre_transportistas_operativos" ON "public"."gre_transportistas" TO "authenticated" USING ("public"."app_empleado_activo"()) WITH CHECK ("public"."app_empleado_activo"());
ALTER TABLE "public"."gre_ubigeos" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "gre_ubigeos_select" ON "public"."gre_ubigeos" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
ALTER TABLE "public"."gre_vehiculos" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "gre_vehiculos_operativos" ON "public"."gre_vehiculos" TO "authenticated" USING ("public"."app_empleado_activo"()) WITH CHECK ("public"."app_empleado_activo"());
CREATE POLICY "guias_detalles_select" ON "public"."guias_remision_detalles" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
CREATE POLICY "guias_intentos_admin" ON "public"."guias_remision_intentos" FOR SELECT TO "authenticated" USING ("public"."app_es_admin"());
ALTER TABLE "public"."guias_remision" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."guias_remision_detalles" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."guias_remision_intentos" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "guias_select" ON "public"."guias_remision" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
CREATE POLICY "intentos_select_admin" ON "public"."facturacion_intentos" FOR SELECT TO "authenticated" USING ("public"."app_es_admin"());
ALTER TABLE "public"."inventario_almacen" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "inventario_almacen_select" ON "public"."inventario_almacen" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
ALTER TABLE "public"."inventario_movimientos" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "inventario_movimientos_admin_select" ON "public"."inventario_movimientos" FOR SELECT TO "authenticated" USING ("public"."app_es_admin"());
ALTER TABLE "public"."inventario_operaciones_idempotentes" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."notas_credito" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."notas_credito_detalles" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."notas_credito_intentos" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "notas_detalles_select" ON "public"."notas_credito_detalles" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
CREATE POLICY "notas_intentos_admin" ON "public"."notas_credito_intentos" FOR SELECT TO "authenticated" USING ("public"."app_es_admin"());
CREATE POLICY "notas_select" ON "public"."notas_credito" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
ALTER TABLE "public"."pagos_deuda_requests" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."pagos_empleados" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pagos_empleados_delete_admin" ON "public"."pagos_empleados" FOR DELETE TO "authenticated" USING ("public"."app_es_admin"());
CREATE POLICY "pagos_empleados_select_empleado" ON "public"."pagos_empleados" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
ALTER TABLE "public"."pagos_gasto" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pagos_gasto_delete_empleado" ON "public"."pagos_gasto" FOR DELETE TO "authenticated" USING ("public"."app_empleado_activo"());
CREATE POLICY "pagos_gasto_select_empleado" ON "public"."pagos_gasto" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
ALTER TABLE "public"."pagos_venta" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "pagos_venta_select" ON "public"."pagos_venta" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
ALTER TABLE "public"."personas_cache" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "procesos_admin" ON "public"."procesos_tributarios" FOR SELECT TO "authenticated" USING ("public"."app_es_admin"());
CREATE POLICY "procesos_detalles_admin" ON "public"."procesos_tributarios_detalles" FOR SELECT TO "authenticated" USING ("public"."app_es_admin"());
CREATE POLICY "procesos_intentos_admin" ON "public"."procesos_tributarios_intentos" FOR SELECT TO "authenticated" USING ("public"."app_es_admin"());
ALTER TABLE "public"."procesos_tributarios" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."procesos_tributarios_detalles" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."procesos_tributarios_intentos" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."productos" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "productos_admin_insert" ON "public"."productos" FOR INSERT TO "authenticated" WITH CHECK ("public"."app_es_admin"());
CREATE POLICY "productos_admin_update" ON "public"."productos" FOR UPDATE TO "authenticated" USING ("public"."app_es_admin"()) WITH CHECK ("public"."app_es_admin"());
CREATE POLICY "productos_select" ON "public"."productos" FOR SELECT TO "authenticated" USING (("public"."app_es_admin"() OR ("public"."app_empleado_activo"() AND COALESCE("activo", true))));
ALTER TABLE "public"."proveedores" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "proveedores_admin_delete" ON "public"."proveedores" FOR DELETE TO "authenticated" USING ("public"."app_es_admin"());
CREATE POLICY "proveedores_admin_insert" ON "public"."proveedores" FOR INSERT TO "authenticated" WITH CHECK ("public"."app_es_admin"());
CREATE POLICY "proveedores_admin_update" ON "public"."proveedores" FOR UPDATE TO "authenticated" USING ("public"."app_es_admin"()) WITH CHECK ("public"."app_es_admin"());
CREATE POLICY "proveedores_select" ON "public"."proveedores" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
CREATE POLICY "reconciliaciones_admin_select" ON "public"."documentos_tributarios_reconciliaciones" FOR SELECT TO "authenticated" USING ("public"."app_es_admin"());
ALTER TABLE "public"."series_comprobantes" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "series_select_empleado" ON "public"."series_comprobantes" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."empleados" "e"
  WHERE (("e"."auth_id" = ( SELECT "auth"."uid"() AS "uid")) AND (COALESCE("e"."activo", false) = true)))));
ALTER TABLE "public"."sesiones_caja" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "sesiones_caja_insert_empleado" ON "public"."sesiones_caja" FOR INSERT TO "authenticated" WITH CHECK ("public"."app_empleado_activo"());
CREATE POLICY "sesiones_caja_select_empleado" ON "public"."sesiones_caja" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
CREATE POLICY "sesiones_caja_update_empleado" ON "public"."sesiones_caja" FOR UPDATE TO "authenticated" USING ("public"."app_empleado_activo"()) WITH CHECK ("public"."app_empleado_activo"());
CREATE POLICY "solicitudes_baja_admin" ON "public"."solicitudes_baja_tributaria" FOR SELECT TO "authenticated" USING ("public"."app_es_admin"());
ALTER TABLE "public"."solicitudes_baja_tributaria" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."stock_alert_tx_context" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."sys_processed_requests" ENABLE ROW LEVEL SECURITY;
ALTER TABLE "public"."transferencias_stock" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "transferencias_stock_select_empleado" ON "public"."transferencias_stock" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
ALTER TABLE "public"."ventas" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ventas_anuladas_admin" ON "public"."ventas_requests_anulados" FOR SELECT TO "authenticated" USING ("public"."app_es_admin"());
ALTER TABLE "public"."ventas_requests_anulados" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "ventas_select" ON "public"."ventas" FOR SELECT TO "authenticated" USING ("public"."app_empleado_activo"());
GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";
REVOKE ALL ON FUNCTION "public"."_aplicar_movimiento_inventario_v2"("p_producto_id" bigint, "p_almacen_id" bigint, "p_delta" integer, "p_tipo_movimiento" "text", "p_motivo" "text", "p_fecha" timestamp with time zone, "p_ingreso_costo" numeric, "p_ingreso_p_unit" numeric, "p_ingreso_p_caja" numeric, "p_ingreso_p_c_comp" numeric, "p_salida_cliente" "text", "p_salida_p_unit" numeric, "p_salida_total" numeric, "p_proveedor_nombre" "text", "p_request_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_aplicar_movimiento_inventario_v2"("p_producto_id" bigint, "p_almacen_id" bigint, "p_delta" integer, "p_tipo_movimiento" "text", "p_motivo" "text", "p_fecha" timestamp with time zone, "p_ingreso_costo" numeric, "p_ingreso_p_unit" numeric, "p_ingreso_p_caja" numeric, "p_ingreso_p_c_comp" numeric, "p_salida_cliente" "text", "p_salida_p_unit" numeric, "p_salida_total" numeric, "p_proveedor_nombre" "text", "p_request_id" "uuid") TO "service_role";
REVOKE ALL ON FUNCTION "public"."_aplicar_stock_nota_credito"("p_nota_credito_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_aplicar_stock_nota_credito"("p_nota_credito_id" "uuid") TO "service_role";
REVOKE ALL ON FUNCTION "public"."_gre_agencia_set_updated_at"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_gre_agencia_set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."_gre_agencia_set_updated_at"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."_gre_empleado_activo"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_gre_empleado_activo"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."_gre_empleado_activo"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."_gre_supervisor"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_gre_supervisor"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."_normalizar_tipo_unidad_documento"("p_tipo_unidad" "text", "p_tipo_venta_normalizado" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_normalizar_tipo_unidad_documento"("p_tipo_unidad" "text", "p_tipo_venta_normalizado" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_normalizar_tipo_unidad_documento"("p_tipo_unidad" "text", "p_tipo_venta_normalizado" "text") TO "service_role";
REVOKE ALL ON FUNCTION "public"."_normalizar_tipo_venta_documento"("p_tipo_venta" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_normalizar_tipo_venta_documento"("p_tipo_venta" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_normalizar_tipo_venta_documento"("p_tipo_venta" "text") TO "service_role";
REVOKE ALL ON FUNCTION "public"."_revertir_stock_nota_credito_por_baja"("p_nota_credito_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_revertir_stock_nota_credito_por_baja"("p_nota_credito_id" "uuid") TO "service_role";
REVOKE ALL ON FUNCTION "public"."_revertir_stock_venta_por_baja"("p_venta_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_revertir_stock_venta_por_baja"("p_venta_id" bigint) TO "service_role";
REVOKE ALL ON FUNCTION "public"."_stock_alert_acumular_tx"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_stock_alert_acumular_tx"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."_validar_desactivacion_almacen_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_validar_desactivacion_almacen_v1"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."_validar_stock_en_almacen_activo_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_validar_stock_en_almacen_activo_v1"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."actualizar_configuracion_negocio_v1"("p_datos" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."actualizar_configuracion_negocio_v1"("p_datos" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."actualizar_configuracion_negocio_v1"("p_datos" "jsonb") TO "service_role";
REVOKE ALL ON FUNCTION "public"."actualizar_cotizaciones_vencidas"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."actualizar_cotizaciones_vencidas"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."actualizar_cotizaciones_vencidas"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."actualizar_producto_seguro_v1"("p_producto_id" bigint, "p_datos" "jsonb", "p_actualizar_apertura" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."actualizar_producto_seguro_v1"("p_producto_id" bigint, "p_datos" "jsonb", "p_actualizar_apertura" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."actualizar_producto_seguro_v1"("p_producto_id" bigint, "p_datos" "jsonb", "p_actualizar_apertura" boolean) TO "service_role";
REVOKE ALL ON FUNCTION "public"."ajustar_stock_y_kardex"("p_producto_id" bigint, "p_almacen_id" bigint, "p_delta" integer, "p_tipo_movimiento" "text", "p_motivo" "text", "p_ingreso_costo" numeric, "p_ingreso_p_unit" numeric, "p_ingreso_p_caja" numeric, "p_ingreso_p_c_comp" numeric, "p_salida_cliente" "text", "p_salida_p_unit" numeric, "p_salida_total" numeric, "p_unidad_label" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."ajustar_stock_y_kardex"("p_producto_id" bigint, "p_almacen_id" bigint, "p_delta" integer, "p_tipo_movimiento" "text", "p_motivo" "text", "p_ingreso_costo" numeric, "p_ingreso_p_unit" numeric, "p_ingreso_p_caja" numeric, "p_ingreso_p_c_comp" numeric, "p_salida_cliente" "text", "p_salida_p_unit" numeric, "p_salida_total" numeric, "p_unidad_label" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ajustar_stock_y_kardex"("p_producto_id" bigint, "p_almacen_id" bigint, "p_delta" integer, "p_tipo_movimiento" "text", "p_motivo" "text", "p_ingreso_costo" numeric, "p_ingreso_p_unit" numeric, "p_ingreso_p_caja" numeric, "p_ingreso_p_c_comp" numeric, "p_salida_cliente" "text", "p_salida_p_unit" numeric, "p_salida_total" numeric, "p_unidad_label" "text") TO "service_role";
REVOKE ALL ON FUNCTION "public"."anular_venta"("p_venta_id" bigint, "p_detalles" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."anular_venta"("p_venta_id" bigint, "p_detalles" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."anular_venta"("p_venta_id" bigint, "p_detalles" "jsonb") TO "authenticated";
REVOKE ALL ON FUNCTION "public"."anular_venta_v2"("p_venta_id" bigint, "p_motivo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."anular_venta_v2"("p_venta_id" bigint, "p_motivo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."anular_venta_v2"("p_venta_id" bigint, "p_motivo" "text") TO "service_role";
REVOKE ALL ON FUNCTION "public"."app_empleado_activo"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."app_empleado_activo"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."app_empleado_activo"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."app_es_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."app_es_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."app_es_admin"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."calcular_piezas_reales_stock"("p_tipo_venta" "text", "p_tipo_unidad" "text", "p_cantidad" integer, "p_pcs" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."calcular_piezas_reales_stock"("p_tipo_venta" "text", "p_tipo_unidad" "text", "p_cantidad" integer, "p_pcs" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."calcular_piezas_reales_stock"("p_tipo_venta" "text", "p_tipo_unidad" "text", "p_cantidad" integer, "p_pcs" integer) TO "service_role";
REVOKE ALL ON FUNCTION "public"."crear_guia_remision_v1"("p_request_id" "uuid", "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crear_guia_remision_v1"("p_request_id" "uuid", "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crear_guia_remision_v1"("p_request_id" "uuid", "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb") TO "service_role";
REVOKE ALL ON FUNCTION "public"."crear_nota_credito_v1"("p_request_id" "uuid", "p_comprobante_id" "uuid", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_detalles" "jsonb", "p_monto_descuento" numeric, "p_reponer_stock" boolean, "p_fecha" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crear_nota_credito_v1"("p_request_id" "uuid", "p_comprobante_id" "uuid", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_detalles" "jsonb", "p_monto_descuento" numeric, "p_reponer_stock" boolean, "p_fecha" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."crear_nota_credito_v1"("p_request_id" "uuid", "p_comprobante_id" "uuid", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_detalles" "jsonb", "p_monto_descuento" numeric, "p_reponer_stock" boolean, "p_fecha" timestamp with time zone) TO "service_role";
REVOKE ALL ON FUNCTION "public"."crear_producto_con_stock"("p_request_id" "uuid", "p_datos_producto" "jsonb", "p_stocks" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."crear_producto_con_stock"("p_request_id" "uuid", "p_datos_producto" "jsonb", "p_stocks" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crear_producto_con_stock"("p_request_id" "uuid", "p_datos_producto" "jsonb", "p_stocks" "jsonb") TO "service_role";
REVOKE ALL ON FUNCTION "public"."desactivar_almacen_seguro_v1"("p_almacen_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."desactivar_almacen_seguro_v1"("p_almacen_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."desactivar_almacen_seguro_v1"("p_almacen_id" bigint) TO "service_role";
REVOKE ALL ON FUNCTION "public"."eliminar_borrador_guia_v1"("p_guia_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."eliminar_borrador_guia_v1"("p_guia_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."eliminar_borrador_guia_v1"("p_guia_id" "uuid") TO "service_role";
REVOKE ALL ON FUNCTION "public"."eliminar_cotizacion_v2"("p_cotizacion_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."eliminar_cotizacion_v2"("p_cotizacion_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."eliminar_cotizacion_v2"("p_cotizacion_id" bigint) TO "service_role";
REVOKE ALL ON FUNCTION "public"."eliminar_gasto_v1"("p_gasto_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."eliminar_gasto_v1"("p_gasto_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."eliminar_gasto_v1"("p_gasto_id" bigint) TO "service_role";
REVOKE ALL ON FUNCTION "public"."eliminar_pago_gasto_v1"("p_pago_id" bigint, "p_gasto_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."eliminar_pago_gasto_v1"("p_pago_id" bigint, "p_gasto_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."eliminar_pago_gasto_v1"("p_pago_id" bigint, "p_gasto_id" bigint) TO "service_role";
REVOKE ALL ON FUNCTION "public"."eliminar_pago_venta_v1"("p_pago_id" bigint, "p_venta_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."eliminar_pago_venta_v1"("p_pago_id" bigint, "p_venta_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."eliminar_pago_venta_v1"("p_pago_id" bigint, "p_venta_id" bigint) TO "service_role";
REVOKE ALL ON FUNCTION "public"."eliminar_producto_seguro_v1"("p_producto_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."eliminar_producto_seguro_v1"("p_producto_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."eliminar_producto_seguro_v1"("p_producto_id" bigint) TO "service_role";
REVOKE ALL ON FUNCTION "public"."evaluar_eliminacion_producto_v1"("p_producto_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."evaluar_eliminacion_producto_v1"("p_producto_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."evaluar_eliminacion_producto_v1"("p_producto_id" bigint) TO "service_role";
REVOKE ALL ON FUNCTION "public"."facturacion_claim_comprobante"("p_comprobante_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text", "p_forzar" boolean, "p_sistema" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."facturacion_claim_comprobante"("p_comprobante_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text", "p_forzar" boolean, "p_sistema" boolean) TO "service_role";
REVOKE ALL ON FUNCTION "public"."facturacion_finalizar_comprobante"("p_comprobante_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."facturacion_finalizar_comprobante"("p_comprobante_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."fn_autoclasificar_tipo_doc_cliente"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_autoclasificar_tipo_doc_cliente"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_autoclasificar_tipo_doc_cliente"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."get_dashboard_summary"("inicio" timestamp with time zone, "fin" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_dashboard_summary"("inicio" timestamp with time zone, "fin" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_dashboard_summary"("inicio" timestamp with time zone, "fin" timestamp with time zone) TO "service_role";
REVOKE ALL ON FUNCTION "public"."get_estado_caja_chica"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_estado_caja_chica"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_estado_caja_chica"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."get_user_role"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_user_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_role"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."gre_claim"("p_guia_id" "uuid", "p_accion" "text", "p_forzar" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."gre_claim"("p_guia_id" "uuid", "p_accion" "text", "p_forzar" boolean) TO "service_role";
REVOKE ALL ON FUNCTION "public"."gre_claim_v2"("p_guia_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text", "p_forzar" boolean, "p_sistema" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."gre_claim_v2"("p_guia_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text", "p_forzar" boolean, "p_sistema" boolean) TO "service_role";
REVOKE ALL ON FUNCTION "public"."gre_finalizar"("p_guia_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."gre_finalizar"("p_guia_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb") TO "service_role";
REVOKE ALL ON FUNCTION "public"."gre_normalizar_detalle_unidad"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."gre_normalizar_detalle_unidad"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."guardar_cotizacion_v2"("p_request_id" "uuid", "p_cliente_id" bigint, "p_total" numeric, "p_fecha" timestamp with time zone, "p_observaciones" "text", "p_validez_dias" integer, "p_detalles" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."guardar_cotizacion_v2"("p_request_id" "uuid", "p_cliente_id" bigint, "p_total" numeric, "p_fecha" timestamp with time zone, "p_observaciones" "text", "p_validez_dias" integer, "p_detalles" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."guardar_cotizacion_v2"("p_request_id" "uuid", "p_cliente_id" bigint, "p_total" numeric, "p_fecha" timestamp with time zone, "p_observaciones" "text", "p_validez_dias" integer, "p_detalles" "jsonb") TO "service_role";
REVOKE ALL ON FUNCTION "public"."guardar_guia_remision_v2"("p_guia_id" "uuid", "p_request_id" "uuid", "p_emitir" boolean, "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."guardar_guia_remision_v2"("p_guia_id" "uuid", "p_request_id" "uuid", "p_emitir" boolean, "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."guardar_guia_remision_v2"("p_guia_id" "uuid", "p_request_id" "uuid", "p_emitir" boolean, "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb") TO "service_role";
REVOKE ALL ON FUNCTION "public"."guardar_guia_remision_v3"("p_guia_id" "uuid", "p_request_id" "uuid", "p_emitir" boolean, "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb", "p_ind_transbordo" boolean, "p_transportista_transbordo_id" bigint, "p_agencia_origen_id" bigint, "p_agencia_destino_id" bigint, "p_destino_entrega_tipo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."guardar_guia_remision_v3"("p_guia_id" "uuid", "p_request_id" "uuid", "p_emitir" boolean, "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb", "p_ind_transbordo" boolean, "p_transportista_transbordo_id" bigint, "p_agencia_origen_id" bigint, "p_agencia_destino_id" bigint, "p_destino_entrega_tipo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."guardar_guia_remision_v3"("p_guia_id" "uuid", "p_request_id" "uuid", "p_emitir" boolean, "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb", "p_ind_transbordo" boolean, "p_transportista_transbordo_id" bigint, "p_agencia_origen_id" bigint, "p_agencia_destino_id" bigint, "p_destino_entrega_tipo" "text") TO "service_role";
REVOKE ALL ON FUNCTION "public"."guardar_guia_remision_v4"("p_guia_id" "uuid", "p_request_id" "uuid", "p_emitir" boolean, "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_cantidad_bultos" integer, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb", "p_ind_transbordo" boolean, "p_transportista_transbordo_id" bigint, "p_agencia_origen_id" bigint, "p_agencia_destino_id" bigint, "p_destino_entrega_tipo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."guardar_guia_remision_v4"("p_guia_id" "uuid", "p_request_id" "uuid", "p_emitir" boolean, "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_cantidad_bultos" integer, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb", "p_ind_transbordo" boolean, "p_transportista_transbordo_id" bigint, "p_agencia_origen_id" bigint, "p_agencia_destino_id" bigint, "p_destino_entrega_tipo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."guardar_guia_remision_v4"("p_guia_id" "uuid", "p_request_id" "uuid", "p_emitir" boolean, "p_tipo_guia" "text", "p_origen_tipo" "text", "p_venta_id" bigint, "p_transferencia_id" bigint, "p_guia_remitente_id" "uuid", "p_documento_relacionado_tipo" "text", "p_documento_relacionado_numero" "text", "p_motivo_codigo" "text", "p_motivo_descripcion" "text", "p_modalidad_transporte" "text", "p_fecha_emision" timestamp with time zone, "p_fecha_traslado" timestamp with time zone, "p_destinatario" "jsonb", "p_remitente" "jsonb", "p_partida" "jsonb", "p_llegada" "jsonb", "p_transportista_id" bigint, "p_conductor_id" bigint, "p_vehiculo_id" bigint, "p_peso_total" numeric, "p_cantidad_bultos" integer, "p_peso_editado" boolean, "p_observacion" "text", "p_detalles" "jsonb", "p_ind_transbordo" boolean, "p_transportista_transbordo_id" bigint, "p_agencia_origen_id" bigint, "p_agencia_destino_id" bigint, "p_destino_entrega_tipo" "text") TO "service_role";
REVOKE ALL ON FUNCTION "public"."handle_new_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."increment_stock"("p_producto_id" bigint, "p_almacen_id" bigint, "p_delta" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."increment_stock"("p_producto_id" bigint, "p_almacen_id" bigint, "p_delta" integer) TO "service_role";
REVOKE ALL ON FUNCTION "public"."listar_documentos_electronicos_v1"("p_fecha_inicio" timestamp with time zone, "p_fecha_fin_exclusiva" timestamp with time zone, "p_limite" integer, "p_offset" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."listar_documentos_electronicos_v1"("p_fecha_inicio" timestamp with time zone, "p_fecha_fin_exclusiva" timestamp with time zone, "p_limite" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."listar_documentos_electronicos_v1"("p_fecha_inicio" timestamp with time zone, "p_fecha_fin_exclusiva" timestamp with time zone, "p_limite" integer, "p_offset" integer) TO "service_role";
REVOKE ALL ON FUNCTION "public"."nota_credito_claim"("p_nota_credito_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text", "p_forzar" boolean, "p_sistema" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."nota_credito_claim"("p_nota_credito_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text", "p_forzar" boolean, "p_sistema" boolean) TO "service_role";
REVOKE ALL ON FUNCTION "public"."nota_credito_finalizar"("p_nota_credito_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."nota_credito_finalizar"("p_nota_credito_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb") TO "service_role";
REVOKE ALL ON FUNCTION "public"."notificar_stock_bajo"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notificar_stock_bajo"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."obtener_disponibilidad_nota_credito"("p_comprobante_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."obtener_disponibilidad_nota_credito"("p_comprobante_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."obtener_disponibilidad_nota_credito"("p_comprobante_id" "uuid") TO "service_role";
REVOKE ALL ON FUNCTION "public"."obtener_tendencia_movimientos"("p_tipo" "text", "p_inicio" timestamp with time zone, "p_fin" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."obtener_tendencia_movimientos"("p_tipo" "text", "p_inicio" timestamp with time zone, "p_fin" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."obtener_tendencia_movimientos"("p_tipo" "text", "p_inicio" timestamp with time zone, "p_fin" timestamp with time zone) TO "service_role";
REVOKE ALL ON FUNCTION "public"."procesar_pago_deuda"("p_es_cliente" boolean, "p_deuda_id" bigint, "p_monto" numeric, "p_metodo" "text", "p_fecha" timestamp without time zone, "p_descontar_de_caja" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."procesar_pago_deuda"("p_es_cliente" boolean, "p_deuda_id" bigint, "p_monto" numeric, "p_metodo" "text", "p_fecha" timestamp without time zone, "p_descontar_de_caja" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."procesar_pago_deuda"("p_es_cliente" boolean, "p_deuda_id" bigint, "p_monto" numeric, "p_metodo" "text", "p_fecha" timestamp without time zone, "p_descontar_de_caja" boolean) TO "service_role";
REVOKE ALL ON FUNCTION "public"."procesar_pago_deuda_v2"("p_request_id" "uuid", "p_es_cliente" boolean, "p_deuda_id" bigint, "p_monto" numeric, "p_metodo" "text", "p_fecha" timestamp with time zone, "p_descontar_de_caja" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."procesar_pago_deuda_v2"("p_request_id" "uuid", "p_es_cliente" boolean, "p_deuda_id" bigint, "p_monto" numeric, "p_metodo" "text", "p_fecha" timestamp with time zone, "p_descontar_de_caja" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."procesar_pago_deuda_v2"("p_request_id" "uuid", "p_es_cliente" boolean, "p_deuda_id" bigint, "p_monto" numeric, "p_metodo" "text", "p_fecha" timestamp with time zone, "p_descontar_de_caja" boolean) TO "service_role";
REVOKE ALL ON FUNCTION "public"."process_sale_v3"("p_request_id" "uuid", "p_cliente_id" bigint, "p_total" numeric, "p_fecha" timestamp with time zone, "p_es_credito" boolean, "p_monto_abono" numeric, "p_detalles" "jsonb", "p_pagos" "jsonb", "p_cotizacion_id" bigint, "p_vendedor_id" bigint, "p_tipo_comprobante" "text", "p_descuento_global_porcentaje" numeric, "p_descuento_global_monto" numeric, "p_motivo_descuento" "text", "p_subtotal_bruto" numeric, "p_descuento_autorizado_por" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."process_sale_v3"("p_request_id" "uuid", "p_cliente_id" bigint, "p_total" numeric, "p_fecha" timestamp with time zone, "p_es_credito" boolean, "p_monto_abono" numeric, "p_detalles" "jsonb", "p_pagos" "jsonb", "p_cotizacion_id" bigint, "p_vendedor_id" bigint, "p_tipo_comprobante" "text", "p_descuento_global_porcentaje" numeric, "p_descuento_global_monto" numeric, "p_motivo_descuento" "text", "p_subtotal_bruto" numeric, "p_descuento_autorizado_por" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_sale_v3"("p_request_id" "uuid", "p_cliente_id" bigint, "p_total" numeric, "p_fecha" timestamp with time zone, "p_es_credito" boolean, "p_monto_abono" numeric, "p_detalles" "jsonb", "p_pagos" "jsonb", "p_cotizacion_id" bigint, "p_vendedor_id" bigint, "p_tipo_comprobante" "text", "p_descuento_global_porcentaje" numeric, "p_descuento_global_monto" numeric, "p_motivo_descuento" "text", "p_subtotal_bruto" numeric, "p_descuento_autorizado_por" bigint) TO "service_role";
REVOKE ALL ON FUNCTION "public"."reactivar_almacen_seguro_v1"("p_almacen_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reactivar_almacen_seguro_v1"("p_almacen_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."reactivar_almacen_seguro_v1"("p_almacen_id" bigint) TO "service_role";
REVOKE ALL ON FUNCTION "public"."recalcular_estado_tributario_venta"("p_venta_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recalcular_estado_tributario_venta"("p_venta_id" bigint) TO "service_role";
REVOKE ALL ON FUNCTION "public"."registrar_gasto"("p_proveedor_id" bigint, "p_categoria" "text", "p_monto_total" numeric, "p_abono_inicial" numeric, "p_descripcion" "text", "p_metodo_pago" "text", "p_fecha" timestamp with time zone, "p_afecta_caja_chica" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_gasto"("p_proveedor_id" bigint, "p_categoria" "text", "p_monto_total" numeric, "p_abono_inicial" numeric, "p_descripcion" "text", "p_metodo_pago" "text", "p_fecha" timestamp with time zone, "p_afecta_caja_chica" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_gasto"("p_proveedor_id" bigint, "p_categoria" "text", "p_monto_total" numeric, "p_abono_inicial" numeric, "p_descripcion" "text", "p_metodo_pago" "text", "p_fecha" timestamp with time zone, "p_afecta_caja_chica" boolean) TO "service_role";
REVOKE ALL ON FUNCTION "public"."registrar_gasto_mixto"("p_proveedor_id" bigint, "p_categoria" "text", "p_monto_total" numeric, "p_descripcion" "text", "p_fecha" timestamp with time zone, "p_pagos_json" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_gasto_mixto"("p_proveedor_id" bigint, "p_categoria" "text", "p_monto_total" numeric, "p_descripcion" "text", "p_fecha" timestamp with time zone, "p_pagos_json" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_gasto_mixto"("p_proveedor_id" bigint, "p_categoria" "text", "p_monto_total" numeric, "p_descripcion" "text", "p_fecha" timestamp with time zone, "p_pagos_json" "jsonb") TO "service_role";
REVOKE ALL ON FUNCTION "public"."registrar_ingreso_mercaderia_v2"("p_request_id" "uuid", "p_producto_id" bigint, "p_fecha" timestamp with time zone, "p_tipo_ingreso" "text", "p_documento" "text", "p_proveedor_id" bigint, "p_observaciones" "text", "p_almacenes" "jsonb", "p_ingreso_costo" numeric, "p_ingreso_p_unit" numeric, "p_ingreso_p_caja" numeric, "p_ingreso_p_c_comp" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_ingreso_mercaderia_v2"("p_request_id" "uuid", "p_producto_id" bigint, "p_fecha" timestamp with time zone, "p_tipo_ingreso" "text", "p_documento" "text", "p_proveedor_id" bigint, "p_observaciones" "text", "p_almacenes" "jsonb", "p_ingreso_costo" numeric, "p_ingreso_p_unit" numeric, "p_ingreso_p_caja" numeric, "p_ingreso_p_c_comp" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_ingreso_mercaderia_v2"("p_request_id" "uuid", "p_producto_id" bigint, "p_fecha" timestamp with time zone, "p_tipo_ingreso" "text", "p_documento" "text", "p_proveedor_id" bigint, "p_observaciones" "text", "p_almacenes" "jsonb", "p_ingreso_costo" numeric, "p_ingreso_p_unit" numeric, "p_ingreso_p_caja" numeric, "p_ingreso_p_c_comp" numeric) TO "service_role";
REVOKE ALL ON FUNCTION "public"."registrar_merma_v2"("p_request_id" "uuid", "p_producto_id" bigint, "p_almacen_id" bigint, "p_cantidad" integer, "p_motivo" "text", "p_fecha" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_merma_v2"("p_request_id" "uuid", "p_producto_id" bigint, "p_almacen_id" bigint, "p_cantidad" integer, "p_motivo" "text", "p_fecha" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_merma_v2"("p_request_id" "uuid", "p_producto_id" bigint, "p_almacen_id" bigint, "p_cantidad" integer, "p_motivo" "text", "p_fecha" timestamp with time zone) TO "service_role";
REVOKE ALL ON FUNCTION "public"."registrar_pago_empleado_mixto"("p_empleado_id" bigint, "p_concepto" "text", "p_fecha" timestamp with time zone, "p_pagos_json" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."registrar_pago_empleado_mixto"("p_empleado_id" bigint, "p_concepto" "text", "p_fecha" timestamp with time zone, "p_pagos_json" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_pago_empleado_mixto"("p_empleado_id" bigint, "p_concepto" "text", "p_fecha" timestamp with time zone, "p_pagos_json" "jsonb") TO "service_role";
REVOKE ALL ON FUNCTION "public"."resolver_resultado_incierto_v1"("p_tipo_documento" "text", "p_documento_id" "uuid", "p_decision" "text", "p_motivo" "text", "p_referencia_externa" "text", "p_usuario_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."resolver_resultado_incierto_v1"("p_tipo_documento" "text", "p_documento_id" "uuid", "p_decision" "text", "p_motivo" "text", "p_referencia_externa" "text", "p_usuario_id" "uuid") TO "service_role";
REVOKE ALL ON FUNCTION "public"."set_facturacion_updated_at"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_facturacion_updated_at"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."set_updated_at_documentos_tributarios"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_updated_at_documentos_tributarios"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at_documentos_tributarios"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."set_vendedor_observaciones_kardex"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_vendedor_observaciones_kardex"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."set_venta_fue_credito"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_venta_fue_credito"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_venta_fue_credito"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."solicitar_baja_tributaria_v1"("p_request_id" "uuid", "p_tipo_origen" "text", "p_origen_id" "uuid", "p_motivo" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solicitar_baja_tributaria_v1"("p_request_id" "uuid", "p_tipo_origen" "text", "p_origen_id" "uuid", "p_motivo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."solicitar_baja_tributaria_v1"("p_request_id" "uuid", "p_tipo_origen" "text", "p_origen_id" "uuid", "p_motivo" "text") TO "service_role";
REVOKE ALL ON FUNCTION "public"."sync_dashboard_to_sheets"("p_desde" timestamp with time zone, "p_hasta" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_dashboard_to_sheets"("p_desde" timestamp with time zone, "p_hasta" timestamp with time zone) TO "service_role";
REVOKE ALL ON FUNCTION "public"."sync_inventario_to_sheets"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_inventario_to_sheets"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."sync_movimientos_to_sheets"("p_desde" timestamp with time zone, "p_hasta" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."sync_movimientos_to_sheets"("p_desde" timestamp with time zone, "p_hasta" timestamp with time zone) TO "service_role";
REVOKE ALL ON FUNCTION "public"."trasladar_stock"("p_producto_id" bigint, "p_origen_id" bigint, "p_destino_id" bigint, "p_cantidad" integer, "p_motivo" "text", "p_unidad_label" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."trasladar_stock"("p_producto_id" bigint, "p_origen_id" bigint, "p_destino_id" bigint, "p_cantidad" integer, "p_motivo" "text", "p_unidad_label" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."trasladar_stock"("p_producto_id" bigint, "p_origen_id" bigint, "p_destino_id" bigint, "p_cantidad" integer, "p_motivo" "text", "p_unidad_label" "text") TO "service_role";
REVOKE ALL ON FUNCTION "public"."trasladar_stock_v2"("p_request_id" "uuid", "p_producto_id" bigint, "p_origen_id" bigint, "p_destino_id" bigint, "p_cantidad" integer, "p_motivo" "text", "p_fecha" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."trasladar_stock_v2"("p_request_id" "uuid", "p_producto_id" bigint, "p_origen_id" bigint, "p_destino_id" bigint, "p_cantidad" integer, "p_motivo" "text", "p_fecha" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."trasladar_stock_v2"("p_request_id" "uuid", "p_producto_id" bigint, "p_origen_id" bigint, "p_destino_id" bigint, "p_cantidad" integer, "p_motivo" "text", "p_fecha" timestamp with time zone) TO "service_role";
REVOKE ALL ON FUNCTION "public"."tributario_claim_proceso"("p_proceso_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text", "p_forzar" boolean, "p_sistema" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tributario_claim_proceso"("p_proceso_id" "uuid", "p_usuario_id" "uuid", "p_accion" "text", "p_forzar" boolean, "p_sistema" boolean) TO "service_role";
REVOKE ALL ON FUNCTION "public"."tributario_finalizar_proceso"("p_proceso_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tributario_finalizar_proceso"("p_proceso_id" "uuid", "p_bloqueo_token" "uuid", "p_estado" "text", "p_resultado" "jsonb") TO "service_role";
REVOKE ALL ON FUNCTION "public"."tributario_preparar_procesos"("p_tipo_proceso" "text", "p_usuario_id" "uuid", "p_sistema" boolean, "p_limite_documentos" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tributario_preparar_procesos"("p_tipo_proceso" "text", "p_usuario_id" "uuid", "p_sistema" boolean, "p_limite_documentos" integer) TO "service_role";
REVOKE ALL ON FUNCTION "public"."tributario_reintentar_stock_bajas"("p_limite" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."tributario_reintentar_stock_bajas"("p_limite" integer) TO "service_role";
REVOKE ALL ON FUNCTION "public"."validar_origen_nota_credito_vigente"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."validar_origen_nota_credito_vigente"() TO "service_role";
REVOKE ALL ON FUNCTION "public"."vincular_usuario_empleado"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."vincular_usuario_empleado"() TO "service_role";
GRANT ALL ON TABLE "public"."almacenes" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."almacenes" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."almacenes_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."almacenes_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."almacenes_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."clientes" TO "service_role";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."clientes" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."clientes_id_seq" TO "service_role";
GRANT SELECT,USAGE ON SEQUENCE "public"."clientes_id_seq" TO "authenticated";
GRANT ALL ON TABLE "public"."comprobantes_electronicos" TO "service_role";
GRANT SELECT ON TABLE "public"."comprobantes_electronicos" TO "authenticated";
GRANT ALL ON TABLE "public"."configuracion_negocio" TO "service_role";
GRANT SELECT ON TABLE "public"."configuracion_negocio" TO "authenticated";
GRANT SELECT,MAINTAIN ON TABLE "public"."constancias_descuento" TO "authenticated";
GRANT ALL ON TABLE "public"."constancias_descuento" TO "service_role";
GRANT ALL ON TABLE "public"."correlativos_procesos_tributarios" TO "service_role";
GRANT ALL ON TABLE "public"."cotizaciones" TO "service_role";
GRANT SELECT ON TABLE "public"."cotizaciones" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cotizaciones_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."cotizaciones_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."cotizaciones_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."detalle_cotizaciones" TO "service_role";
GRANT SELECT ON TABLE "public"."detalle_cotizaciones" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."detalle_cotizaciones_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."detalle_cotizaciones_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."detalle_cotizaciones_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."detalle_ventas" TO "service_role";
GRANT SELECT ON TABLE "public"."detalle_ventas" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."detalle_ventas_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."detalle_ventas_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."detalle_ventas_id_seq" TO "service_role";
GRANT SELECT,MAINTAIN ON TABLE "public"."documentos_tributarios_reconciliaciones" TO "authenticated";
GRANT ALL ON TABLE "public"."documentos_tributarios_reconciliaciones" TO "service_role";
GRANT ALL ON TABLE "public"."empleados" TO "service_role";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."empleados" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."empleados_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."empleados_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."empleados_id_seq" TO "service_role";
GRANT SELECT,MAINTAIN ON TABLE "public"."facturacion_intentos" TO "authenticated";
GRANT ALL ON TABLE "public"."facturacion_intentos" TO "service_role";
GRANT ALL ON TABLE "public"."gastos" TO "service_role";
GRANT SELECT,DELETE,UPDATE ON TABLE "public"."gastos" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."gastos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."gastos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."gastos_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."gre_conductores" TO "service_role";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."gre_conductores" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."gre_conductores_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."gre_conductores_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."gre_conductores_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."gre_transportistas" TO "service_role";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."gre_transportistas" TO "authenticated";
GRANT ALL ON TABLE "public"."gre_transportistas_agencias" TO "authenticated";
GRANT ALL ON TABLE "public"."gre_transportistas_agencias" TO "service_role";
GRANT ALL ON SEQUENCE "public"."gre_transportistas_agencias_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."gre_transportistas_agencias_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."gre_transportistas_agencias_id_seq" TO "service_role";
GRANT ALL ON SEQUENCE "public"."gre_transportistas_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."gre_transportistas_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."gre_transportistas_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."gre_ubigeos" TO "service_role";
GRANT SELECT ON TABLE "public"."gre_ubigeos" TO "authenticated";
GRANT ALL ON TABLE "public"."gre_vehiculos" TO "service_role";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."gre_vehiculos" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."gre_vehiculos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."gre_vehiculos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."gre_vehiculos_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."guias_remision" TO "service_role";
GRANT SELECT ON TABLE "public"."guias_remision" TO "authenticated";
GRANT ALL ON TABLE "public"."guias_remision_detalles" TO "service_role";
GRANT SELECT ON TABLE "public"."guias_remision_detalles" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."guias_remision_detalles_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."guias_remision_detalles_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."guias_remision_detalles_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."guias_remision_intentos" TO "service_role";
GRANT SELECT ON TABLE "public"."guias_remision_intentos" TO "authenticated";
GRANT ALL ON TABLE "public"."inventario_almacen" TO "service_role";
GRANT SELECT ON TABLE "public"."inventario_almacen" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."inventario_almacen_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."inventario_almacen_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."inventario_almacen_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."inventario_movimientos" TO "service_role";
GRANT SELECT ON TABLE "public"."inventario_movimientos" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."inventario_movimientos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."inventario_movimientos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."inventario_movimientos_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."inventario_operaciones_idempotentes" TO "service_role";
GRANT ALL ON TABLE "public"."pagos_empleados" TO "service_role";
GRANT SELECT,DELETE ON TABLE "public"."pagos_empleados" TO "authenticated";
GRANT ALL ON TABLE "public"."pagos_gasto" TO "service_role";
GRANT SELECT,DELETE ON TABLE "public"."pagos_gasto" TO "authenticated";
GRANT ALL ON TABLE "public"."pagos_venta" TO "service_role";
GRANT SELECT ON TABLE "public"."pagos_venta" TO "authenticated";
GRANT ALL ON TABLE "public"."movimientos" TO "service_role";
GRANT SELECT ON TABLE "public"."movimientos" TO "authenticated";
GRANT ALL ON TABLE "public"."notas_credito" TO "service_role";
GRANT SELECT ON TABLE "public"."notas_credito" TO "authenticated";
GRANT ALL ON TABLE "public"."notas_credito_detalles" TO "service_role";
GRANT SELECT ON TABLE "public"."notas_credito_detalles" TO "authenticated";
GRANT ALL ON TABLE "public"."notas_credito_intentos" TO "service_role";
GRANT SELECT ON TABLE "public"."notas_credito_intentos" TO "authenticated";
GRANT ALL ON TABLE "public"."pagos_deuda_requests" TO "service_role";
GRANT ALL ON SEQUENCE "public"."pagos_empleados_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pagos_empleados_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pagos_empleados_id_seq" TO "service_role";
GRANT ALL ON SEQUENCE "public"."pagos_gasto_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pagos_gasto_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pagos_gasto_id_seq" TO "service_role";
GRANT ALL ON SEQUENCE "public"."pagos_venta_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pagos_venta_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pagos_venta_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."personas_cache" TO "service_role";
GRANT ALL ON TABLE "public"."procesos_tributarios" TO "service_role";
GRANT SELECT ON TABLE "public"."procesos_tributarios" TO "authenticated";
GRANT ALL ON TABLE "public"."procesos_tributarios_detalles" TO "service_role";
GRANT SELECT ON TABLE "public"."procesos_tributarios_detalles" TO "authenticated";
GRANT ALL ON TABLE "public"."procesos_tributarios_intentos" TO "service_role";
GRANT SELECT ON TABLE "public"."procesos_tributarios_intentos" TO "authenticated";
GRANT ALL ON TABLE "public"."productos" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."productos" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."productos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."productos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."productos_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."proveedores" TO "service_role";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."proveedores" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."proveedores_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."proveedores_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."proveedores_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."reportes_movimientos_financieros" TO "authenticated";
GRANT ALL ON TABLE "public"."reportes_movimientos_financieros" TO "service_role";
GRANT SELECT,MAINTAIN ON TABLE "public"."series_comprobantes" TO "authenticated";
GRANT ALL ON TABLE "public"."series_comprobantes" TO "service_role";
GRANT ALL ON TABLE "public"."sesiones_caja" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."sesiones_caja" TO "authenticated";
GRANT ALL ON TABLE "public"."solicitudes_baja_tributaria" TO "service_role";
GRANT SELECT ON TABLE "public"."solicitudes_baja_tributaria" TO "authenticated";
GRANT ALL ON TABLE "public"."stock_alert_tx_context" TO "service_role";
GRANT ALL ON TABLE "public"."sys_processed_requests" TO "service_role";
GRANT ALL ON TABLE "public"."transferencias_stock" TO "service_role";
GRANT SELECT ON TABLE "public"."transferencias_stock" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."transferencias_stock_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."ventas" TO "service_role";
GRANT SELECT ON TABLE "public"."ventas" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ventas_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."ventas_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."ventas_id_seq" TO "service_role";
GRANT ALL ON TABLE "public"."ventas_requests_anulados" TO "service_role";
GRANT SELECT ON TABLE "public"."ventas_requests_anulados" TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";
