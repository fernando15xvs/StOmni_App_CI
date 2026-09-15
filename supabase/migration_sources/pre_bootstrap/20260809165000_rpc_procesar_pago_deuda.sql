-- =============================================================================
-- RPC: procesar_pago_deuda
-- Registra un abono sobre una venta a crédito (es_cliente = true) o sobre
-- un gasto pendiente con proveedor (es_cliente = false).
--
-- Actualiza saldo + estado en la tabla correspondiente e inserta el pago.
-- Usa SECURITY DEFINER para evitar tener que otorgar UPDATE directo al rol
-- authenticated sobre las tablas ventas/gastos.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.procesar_pago_deuda(
  p_es_cliente       boolean,
  p_deuda_id         bigint,
  p_monto            numeric,
  p_metodo           text,
  p_fecha            timestamp without time zone,
  p_descontar_de_caja boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
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
    AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'vendedor')
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

    -- Si es efectivo pero NO se descuenta de caja, le cambiamos el nombre
    -- para que la vista de movimientos (Caja Chica) lo ignore.
    IF v_es_efectivo AND NOT COALESCE(p_descontar_de_caja, false) THEN
      p_metodo := 'Efectivo (Externo)';
    END IF;

    -- Insertar pago
    INSERT INTO public.pagos_gasto (gasto_id, metodo, monto, fecha)
    VALUES (p_deuda_id, TRIM(p_metodo), p_monto, COALESCE(p_fecha, (now() AT TIME ZONE 'America/Lima')) AT TIME ZONE 'America/Lima');

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
$function$;

-- Permisos: solo usuarios autenticados pueden ejecutarlo.
-- Las tablas ventas/gastos son modificadas internamente con SECURITY DEFINER.
DROP FUNCTION IF EXISTS public.procesar_pago_deuda(
  boolean, bigint, numeric, text, timestamp with time zone
);
DROP FUNCTION IF EXISTS public.procesar_pago_deuda(
  boolean, bigint, numeric, text, timestamp without time zone
);
DROP FUNCTION IF EXISTS public.procesar_pago_deuda(
  boolean, bigint, numeric, text, timestamp with time zone, boolean
);

REVOKE ALL ON FUNCTION public.procesar_pago_deuda(boolean, bigint, numeric, text, timestamp without time zone, boolean)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.procesar_pago_deuda(boolean, bigint, numeric, text, timestamp without time zone, boolean)
  TO authenticated;
