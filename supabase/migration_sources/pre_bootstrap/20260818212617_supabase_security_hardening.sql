-- StOmni - hardening aplicado en Supabase el 2026-08-18.
-- Esta migración documenta el estado aplicado en producción.

CREATE OR REPLACE FUNCTION public._gre_supervisor()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.empleados AS e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND e.rol = 'admin'
  );
$function$;

CREATE OR REPLACE FUNCTION public.actualizar_cotizaciones_vencidas()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado: empleado no autenticado o inactivo.';
  END IF;

  UPDATE public.cotizaciones
  SET estado = 'vencida'
  WHERE estado = 'pendiente'
    AND (fecha + (COALESCE(validez_dias, 15) || ' days')::interval) < now();
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_estado_caja_chica()
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_sesion_activa public.sesiones_caja%ROWTYPE;
  v_ingresos_efectivo numeric := 0;
  v_egresos_efectivo numeric := 0;
  v_pagos_personal numeric := 0;
BEGIN
  IF auth.uid() IS NULL OR NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'Acceso denegado: empleado no autenticado o inactivo.';
  END IF;

  SELECT sc.* INTO v_sesion_activa
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
      v_sesion_activa.monto_apertura + v_ingresos_efectivo
      - (v_egresos_efectivo + v_pagos_personal)
  );
END;
$function$;

CREATE UNIQUE INDEX IF NOT EXISTS sesiones_caja_unica_abierta_idx
ON public.sesiones_caja ((1))
WHERE estado = 'ABIERTA';

CREATE OR REPLACE FUNCTION public.registrar_gasto_mixto(
  p_proveedor_id bigint,
  p_categoria text,
  p_monto_total numeric,
  p_descripcion text,
  p_fecha timestamp with time zone,
  p_pagos_json jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
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
      IF v_monto <= 0 THEN RAISE EXCEPTION 'Todos los pagos deben tener un monto mayor a cero.'; END IF;
      IF v_metodo = '' THEN RAISE EXCEPTION 'Todos los pagos deben indicar un método.'; END IF;

      v_total_pagado := v_total_pagado + v_monto;
      v_afecta_caja := COALESCE((v_pago->>'afecta_caja_chica')::boolean, false)
        AND v_metodo LIKE '%EFECTIVO%';
      IF v_afecta_caja THEN v_salida_caja := v_salida_caja + v_monto; END IF;
    END LOOP;
  END IF;

  IF v_total_pagado > p_monto_total + 0.02 THEN
    RAISE EXCEPTION 'Los pagos (S/ %) superan el monto total del gasto (S/ %).',
      round(v_total_pagado, 2), round(p_monto_total, 2);
  END IF;

  IF v_salida_caja > 0 THEN
    SELECT sc.* INTO v_sesion
    FROM public.sesiones_caja AS sc
    WHERE sc.estado = 'ABIERTA'
    ORDER BY sc.fecha_apertura DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'La caja está cerrada. Ábrela antes de descontar dinero en efectivo.';
    END IF;
    IF v_fecha < v_sesion.fecha_apertura THEN
      RAISE EXCEPTION 'La fecha de un pago que afecta Caja Chica no puede ser anterior a la apertura de la caja.';
    END IF;

    SELECT COALESCE(SUM(pv.monto), 0) INTO v_ingresos
    FROM public.pagos_venta AS pv
    WHERE pv.fecha >= v_sesion.fecha_apertura
      AND TRIM(UPPER(pv.metodo)) LIKE '%EFECTIVO%';

    SELECT COALESCE(SUM(pg.monto), 0) INTO v_egresos_gastos
    FROM public.pagos_gasto AS pg
    WHERE pg.fecha >= v_sesion.fecha_apertura
      AND TRIM(UPPER(pg.metodo)) LIKE '%EFECTIVO%'
      AND COALESCE(pg.afecta_caja_chica, false) = true;

    SELECT COALESCE(SUM(pe.monto), 0) INTO v_egresos_personal
    FROM public.pagos_empleados AS pe
    WHERE pe.fecha >= v_sesion.fecha_apertura
      AND TRIM(UPPER(pe.metodo)) LIKE '%EFECTIVO%'
      AND COALESCE(pe.afecta_caja_chica, false) = true;

    v_saldo_disponible := v_sesion.monto_apertura + v_ingresos
      - v_egresos_gastos - v_egresos_personal;

    IF v_salida_caja > v_saldo_disponible + 0.000001 THEN
      RAISE EXCEPTION 'Saldo insuficiente en Caja Chica. Disponible: S/ %, solicitado: S/ %.',
        round(v_saldo_disponible, 2), round(v_salida_caja, 2);
    END IF;
  END IF;

  v_saldo_restante := GREATEST(p_monto_total - v_total_pagado, 0);
  v_estado := CASE WHEN v_saldo_restante <= 0.02 THEN 'pagado' ELSE 'pendiente' END;

  INSERT INTO public.gastos(fecha, proveedor_id, categoria, monto, descripcion, estado, saldo)
  VALUES(v_fecha, p_proveedor_id, p_categoria, p_monto_total, p_descripcion, v_estado, v_saldo_restante)
  RETURNING id INTO v_gasto_id;

  IF p_pagos_json IS NOT NULL THEN
    FOR v_pago IN SELECT value FROM jsonb_array_elements(p_pagos_json)
    LOOP
      v_monto := COALESCE(NULLIF(v_pago->>'monto', '')::numeric, 0);
      v_metodo := TRIM(COALESCE(v_pago->>'metodo', ''));
      v_afecta_caja := COALESCE((v_pago->>'afecta_caja_chica')::boolean, false)
        AND UPPER(v_metodo) LIKE '%EFECTIVO%';
      INSERT INTO public.pagos_gasto(gasto_id, metodo, monto, fecha, afecta_caja_chica)
      VALUES(v_gasto_id, v_metodo, v_monto, v_fecha, v_afecta_caja);
    END LOOP;
  END IF;

  RETURN v_gasto_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_gasto(
  p_proveedor_id bigint,
  p_categoria text,
  p_monto_total numeric,
  p_abono_inicial numeric,
  p_descripcion text,
  p_metodo_pago text,
  p_fecha timestamp with time zone,
  p_afecta_caja_chica boolean DEFAULT false
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_pagos jsonb := '[]'::jsonb;
BEGIN
  IF COALESCE(p_abono_inicial, 0) < 0 THEN
    RAISE EXCEPTION 'El abono inicial no puede ser negativo.';
  END IF;
  IF COALESCE(p_abono_inicial, 0) > 0 THEN
    v_pagos := jsonb_build_array(jsonb_build_object(
      'metodo', p_metodo_pago,
      'monto', p_abono_inicial,
      'afecta_caja_chica', COALESCE(p_afecta_caja_chica, false)
    ));
  END IF;
  RETURN public.registrar_gasto_mixto(
    p_proveedor_id, p_categoria, p_monto_total, p_descripcion,
    p_fecha, v_pagos
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.registrar_pago_empleado_mixto(
  p_empleado_id bigint,
  p_concepto text,
  p_fecha timestamp with time zone,
  p_pagos_json jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
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
  IF p_empleado_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.empleados e WHERE e.id = p_empleado_id) THEN
    RAISE EXCEPTION 'El empleado seleccionado no existe.';
  END IF;
  IF NULLIF(TRIM(COALESCE(p_concepto, '')), '') IS NULL THEN
    RAISE EXCEPTION 'El concepto del pago es obligatorio.';
  END IF;
  IF p_pagos_json IS NULL OR jsonb_typeof(p_pagos_json) <> 'array' OR jsonb_array_length(p_pagos_json) = 0 THEN
    RAISE EXCEPTION 'Debe registrar al menos un pago.';
  END IF;

  FOR v_pago IN SELECT value FROM jsonb_array_elements(p_pagos_json)
  LOOP
    IF jsonb_typeof(v_pago) <> 'object' THEN RAISE EXCEPTION 'Cada pago debe ser un objeto JSON.'; END IF;
    v_monto := COALESCE(NULLIF(v_pago->>'monto', '')::numeric, 0);
    v_metodo := UPPER(TRIM(COALESCE(v_pago->>'metodo', '')));
    IF v_monto <= 0 THEN RAISE EXCEPTION 'Todos los pagos deben tener un monto mayor a cero.'; END IF;
    IF v_metodo = '' THEN RAISE EXCEPTION 'Todos los pagos deben indicar un método.'; END IF;
    v_afecta_caja := COALESCE((v_pago->>'afecta_caja_chica')::boolean, false)
      AND v_metodo LIKE '%EFECTIVO%';
    IF v_afecta_caja THEN v_salida_caja := v_salida_caja + v_monto; END IF;
  END LOOP;

  IF v_salida_caja > 0 THEN
    SELECT sc.* INTO v_sesion
    FROM public.sesiones_caja AS sc
    WHERE sc.estado = 'ABIERTA'
    ORDER BY sc.fecha_apertura DESC
    LIMIT 1
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'La caja está cerrada. Ábrela antes de descontar dinero en efectivo.'; END IF;
    IF v_fecha < v_sesion.fecha_apertura THEN
      RAISE EXCEPTION 'La fecha de un pago que afecta Caja Chica no puede ser anterior a la apertura de la caja.';
    END IF;

    SELECT COALESCE(SUM(pv.monto), 0) INTO v_ingresos
    FROM public.pagos_venta AS pv
    WHERE pv.fecha >= v_sesion.fecha_apertura
      AND TRIM(UPPER(pv.metodo)) LIKE '%EFECTIVO%';
    SELECT COALESCE(SUM(pg.monto), 0) INTO v_egresos_gastos
    FROM public.pagos_gasto AS pg
    WHERE pg.fecha >= v_sesion.fecha_apertura
      AND TRIM(UPPER(pg.metodo)) LIKE '%EFECTIVO%'
      AND COALESCE(pg.afecta_caja_chica, false) = true;
    SELECT COALESCE(SUM(pe.monto), 0) INTO v_egresos_personal
    FROM public.pagos_empleados AS pe
    WHERE pe.fecha >= v_sesion.fecha_apertura
      AND TRIM(UPPER(pe.metodo)) LIKE '%EFECTIVO%'
      AND COALESCE(pe.afecta_caja_chica, false) = true;

    v_saldo_disponible := v_sesion.monto_apertura + v_ingresos - v_egresos_gastos - v_egresos_personal;
    IF v_salida_caja > v_saldo_disponible + 0.000001 THEN
      RAISE EXCEPTION 'Saldo insuficiente en Caja Chica. Disponible: S/ %, solicitado: S/ %.',
        round(v_saldo_disponible, 2), round(v_salida_caja, 2);
    END IF;
  END IF;

  FOR v_pago IN SELECT value FROM jsonb_array_elements(p_pagos_json)
  LOOP
    v_monto := COALESCE(NULLIF(v_pago->>'monto', '')::numeric, 0);
    v_metodo := TRIM(COALESCE(v_pago->>'metodo', ''));
    v_afecta_caja := COALESCE((v_pago->>'afecta_caja_chica')::boolean, false)
      AND UPPER(v_metodo) LIKE '%EFECTIVO%';
    INSERT INTO public.pagos_empleados(empleado_id, monto, concepto, metodo, fecha, afecta_caja_chica)
    VALUES(p_empleado_id, v_monto, TRIM(p_concepto), v_metodo, v_fecha, v_afecta_caja);
  END LOOP;
END;
$function$;

ALTER TABLE public.cotizaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.detalle_cotizaciones ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cotizaciones_select_empleado ON public.cotizaciones;
CREATE POLICY cotizaciones_select_empleado ON public.cotizaciones
FOR SELECT TO authenticated USING (public.app_empleado_activo());

DROP POLICY IF EXISTS detalle_cotizaciones_select_empleado ON public.detalle_cotizaciones;
CREATE POLICY detalle_cotizaciones_select_empleado ON public.detalle_cotizaciones
FOR SELECT TO authenticated USING (public.app_empleado_activo());

DROP POLICY IF EXISTS "Permitir todo en gastos" ON public.gastos;
DROP POLICY IF EXISTS gastos_select_empleado ON public.gastos;
DROP POLICY IF EXISTS gastos_update_empleado ON public.gastos;
DROP POLICY IF EXISTS gastos_delete_empleado ON public.gastos;
CREATE POLICY gastos_select_empleado ON public.gastos FOR SELECT TO authenticated USING (public.app_empleado_activo());
CREATE POLICY gastos_update_empleado ON public.gastos FOR UPDATE TO authenticated USING (public.app_empleado_activo()) WITH CHECK (public.app_empleado_activo());
CREATE POLICY gastos_delete_empleado ON public.gastos FOR DELETE TO authenticated USING (public.app_empleado_activo());

DROP POLICY IF EXISTS "Permitir todo en pagos_gasto" ON public.pagos_gasto;
DROP POLICY IF EXISTS pagos_gasto_select_empleado ON public.pagos_gasto;
DROP POLICY IF EXISTS pagos_gasto_delete_empleado ON public.pagos_gasto;
CREATE POLICY pagos_gasto_select_empleado ON public.pagos_gasto FOR SELECT TO authenticated USING (public.app_empleado_activo());
CREATE POLICY pagos_gasto_delete_empleado ON public.pagos_gasto FOR DELETE TO authenticated USING (public.app_empleado_activo());

DROP POLICY IF EXISTS "Permitir todo en pagos_empleados" ON public.pagos_empleados;
DROP POLICY IF EXISTS pagos_empleados_select_empleado ON public.pagos_empleados;
DROP POLICY IF EXISTS pagos_empleados_delete_admin ON public.pagos_empleados;
CREATE POLICY pagos_empleados_select_empleado ON public.pagos_empleados FOR SELECT TO authenticated USING (public.app_empleado_activo());
CREATE POLICY pagos_empleados_delete_admin ON public.pagos_empleados FOR DELETE TO authenticated USING (public.app_es_admin());

DROP POLICY IF EXISTS "Permitir todo a usuarios" ON public.sesiones_caja;
DROP POLICY IF EXISTS sesiones_caja_select_empleado ON public.sesiones_caja;
DROP POLICY IF EXISTS sesiones_caja_insert_empleado ON public.sesiones_caja;
DROP POLICY IF EXISTS sesiones_caja_update_empleado ON public.sesiones_caja;
CREATE POLICY sesiones_caja_select_empleado ON public.sesiones_caja FOR SELECT TO authenticated USING (public.app_empleado_activo());
CREATE POLICY sesiones_caja_insert_empleado ON public.sesiones_caja FOR INSERT TO authenticated WITH CHECK (public.app_empleado_activo());
CREATE POLICY sesiones_caja_update_empleado ON public.sesiones_caja FOR UPDATE TO authenticated USING (public.app_empleado_activo()) WITH CHECK (public.app_empleado_activo());

REVOKE ALL ON TABLE public.cotizaciones, public.detalle_cotizaciones,
  public.gastos, public.pagos_gasto, public.pagos_empleados,
  public.sesiones_caja FROM anon;

REVOKE ALL ON TABLE public.cotizaciones FROM authenticated;
GRANT SELECT ON TABLE public.cotizaciones TO authenticated;
REVOKE ALL ON TABLE public.detalle_cotizaciones FROM authenticated;
GRANT SELECT ON TABLE public.detalle_cotizaciones TO authenticated;
REVOKE ALL ON TABLE public.gastos FROM authenticated;
GRANT SELECT, UPDATE, DELETE ON TABLE public.gastos TO authenticated;
REVOKE ALL ON TABLE public.pagos_gasto FROM authenticated;
GRANT SELECT, DELETE ON TABLE public.pagos_gasto TO authenticated;
REVOKE ALL ON TABLE public.pagos_empleados FROM authenticated;
GRANT SELECT, DELETE ON TABLE public.pagos_empleados TO authenticated;
REVOKE ALL ON TABLE public.sesiones_caja FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE public.sesiones_caja TO authenticated;

ALTER VIEW public.movimientos SET (security_invoker = true);
REVOKE ALL ON TABLE public.movimientos FROM anon, authenticated;
GRANT SELECT ON TABLE public.movimientos TO authenticated;

CREATE OR REPLACE FUNCTION public.eliminar_borrador_guia_v1(p_guia_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_guia public.guias_remision%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Usuario no autenticado'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.empleados e
    WHERE e.auth_id = auth.uid()
      AND COALESCE(e.activo, false) = true
      AND e.rol IN ('admin', 'operador')
  ) THEN
    RAISE EXCEPTION 'Empleado inactivo o rol no autorizado';
  END IF;

  SELECT * INTO v_guia FROM public.guias_remision WHERE id = p_guia_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Guía no encontrada'; END IF;
  IF v_guia.estado <> 'borrador' THEN RAISE EXCEPTION 'Solo se pueden eliminar guías en estado borrador'; END IF;
  IF v_guia.ticket_sunat IS NOT NULL OR v_guia.enviado_at IS NOT NULL THEN
    RAISE EXCEPTION 'La guía tiene información de envío y no puede eliminarse';
  END IF;

  DELETE FROM public.guias_remision_detalles WHERE guia_id = p_guia_id;
  DELETE FROM public.guias_remision WHERE id = p_guia_id;
  RETURN jsonb_build_object('success', true, 'guia_id', p_guia_id);
END;
$function$;

REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.vincular_usuario_empleado() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.validar_origen_nota_credito_vigente() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.gre_normalizar_detalle_unidad() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public._revertir_stock_venta_por_baja(bigint) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.tributario_finalizar_proceso(bigint) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.sync_dashboard_to_sheets(timestamp with time zone, timestamp with time zone) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.sync_inventario_to_sheets() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.sync_movimientos_to_sheets(timestamp with time zone, timestamp with time zone) FROM authenticated;

GRANT EXECUTE ON FUNCTION public.app_empleado_activo() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.app_es_admin() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_user_role() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_estado_caja_chica() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.actualizar_cotizaciones_vencidas() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.guardar_cotizacion_v2(uuid, bigint, numeric, timestamp with time zone, text, integer, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.eliminar_cotizacion_v2(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.registrar_gasto(bigint, text, numeric, numeric, text, text, timestamp with time zone, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.registrar_gasto_mixto(bigint, text, numeric, text, timestamp with time zone, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.registrar_pago_empleado_mixto(bigint, text, timestamp with time zone, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.eliminar_borrador_guia_v1(uuid) TO authenticated, service_role;
