-- Fase 5: idempotencia para cobros/pagos de deudas.
--
-- Esta migracion crea una nueva RPC v2. La RPC legacy se conserva durante el
-- rollout para no romper clientes instalados antes de actualizar Flutter.
-- Una migracion posterior revocara la RPC legacy cuando el smoke del cliente
-- nuevo haya sido aprobado.

CREATE TABLE IF NOT EXISTS public.pagos_deuda_requests (
  request_id uuid PRIMARY KEY,
  auth_user_id uuid NOT NULL,
  empleado_id bigint NOT NULL REFERENCES public.empleados(id),
  es_cliente boolean NOT NULL,
  deuda_id bigint NOT NULL,
  monto numeric(14,2) NOT NULL CHECK (monto > 0),
  metodo text NOT NULL CHECK (length(trim(metodo)) > 0),
  descontar_de_caja boolean NOT NULL DEFAULT false,
  resultado jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);

ALTER TABLE public.pagos_deuda_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.pagos_deuda_requests FROM PUBLIC, anon, authenticated;

ALTER TABLE public.pagos_venta
  ADD COLUMN IF NOT EXISTS request_id uuid;

ALTER TABLE public.pagos_gasto
  ADD COLUMN IF NOT EXISTS request_id uuid;

CREATE UNIQUE INDEX IF NOT EXISTS pagos_venta_request_id_uidx
  ON public.pagos_venta(request_id)
  WHERE request_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS pagos_gasto_request_id_uidx
  ON public.pagos_gasto(request_id)
  WHERE request_id IS NOT NULL;

DO $block$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'pagos_venta_request_id_fkey'
      AND conrelid = 'public.pagos_venta'::regclass
  ) THEN
    ALTER TABLE public.pagos_venta
      ADD CONSTRAINT pagos_venta_request_id_fkey
      FOREIGN KEY (request_id)
      REFERENCES public.pagos_deuda_requests(request_id)
      ON DELETE RESTRICT;
  END IF;
END;
$block$;

DO $block$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'pagos_gasto_request_id_fkey'
      AND conrelid = 'public.pagos_gasto'::regclass
  ) THEN
    ALTER TABLE public.pagos_gasto
      ADD CONSTRAINT pagos_gasto_request_id_fkey
      FOREIGN KEY (request_id)
      REFERENCES public.pagos_deuda_requests(request_id)
      ON DELETE RESTRICT;
  END IF;
END;
$block$;

CREATE OR REPLACE FUNCTION public.procesar_pago_deuda_v2(
  p_request_id uuid,
  p_es_cliente boolean,
  p_deuda_id bigint,
  p_monto numeric,
  p_metodo text,
  p_fecha timestamptz,
  p_descontar_de_caja boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
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
  IF v_auth_user_id IS NULL THEN RAISE EXCEPTION 'Usuario no autenticado'; END IF;
  IF p_request_id IS NULL THEN RAISE EXCEPTION 'request_id es obligatorio'; END IF;
  IF p_es_cliente IS NULL THEN RAISE EXCEPTION 'El tipo de deuda es obligatorio'; END IF;
  IF p_deuda_id IS NULL THEN RAISE EXCEPTION 'La deuda es obligatoria'; END IF;

  SELECT e.id INTO v_empleado_id
  FROM public.empleados AS e
  WHERE e.auth_id = v_auth_user_id
    AND COALESCE(e.activo, false) = true
    AND LOWER(COALESCE(e.rol, '')) IN ('admin', 'operador')
  LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'Empleado inactivo o rol no autorizado para registrar pagos'; END IF;

  v_monto := ROUND(COALESCE(p_monto, 0), 2);
  IF v_monto <= 0 THEN RAISE EXCEPTION 'El monto del pago debe ser mayor a cero'; END IF;
  v_metodo := TRIM(COALESCE(p_metodo, ''));
  IF v_metodo = '' THEN RAISE EXCEPTION 'El metodo de pago es obligatorio'; END IF;
  v_metodo_norm := LOWER(v_metodo);
  v_fecha := COALESCE(p_fecha, now());
  v_es_efectivo := v_metodo_norm = 'efectivo';
  v_descontar_de_caja := COALESCE(p_descontar_de_caja, false) AND NOT p_es_cliente AND v_es_efectivo;

  INSERT INTO public.pagos_deuda_requests (request_id, auth_user_id, empleado_id, es_cliente, deuda_id, monto, metodo, descontar_de_caja)
  VALUES (p_request_id, v_auth_user_id, v_empleado_id, p_es_cliente, p_deuda_id, v_monto, v_metodo_norm, v_descontar_de_caja)
  ON CONFLICT (request_id) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT * INTO v_request FROM public.pagos_deuda_requests WHERE request_id = p_request_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'No se pudo recuperar la solicitud idempotente'; END IF;
    IF v_request.auth_user_id IS DISTINCT FROM v_auth_user_id
       OR v_request.es_cliente IS DISTINCT FROM p_es_cliente
       OR v_request.deuda_id IS DISTINCT FROM p_deuda_id
       OR v_request.monto IS DISTINCT FROM v_monto
       OR v_request.metodo IS DISTINCT FROM v_metodo_norm
       OR v_request.descontar_de_caja IS DISTINCT FROM v_descontar_de_caja THEN
      RAISE EXCEPTION 'request_id reutilizado con datos de pago diferentes';
    END IF;
    IF v_request.resultado IS NULL THEN RAISE EXCEPTION 'La solicitud de pago no tiene un resultado confirmado'; END IF;
    RETURN v_request.resultado || jsonb_build_object('idempotent', true);
  END IF;

  IF v_es_efectivo AND p_es_cliente THEN
    SELECT sc.* INTO v_sesion FROM public.sesiones_caja AS sc WHERE sc.estado = 'ABIERTA' ORDER BY sc.fecha_apertura DESC LIMIT 1;
    IF NOT FOUND THEN RAISE EXCEPTION 'La caja esta cerrada. Abrela antes de registrar este cobro en efectivo.'; END IF;
    IF v_fecha < v_sesion.fecha_apertura THEN RAISE EXCEPTION 'La fecha del cobro en efectivo no puede ser anterior a la apertura de la caja.'; END IF;
  END IF;

  IF v_descontar_de_caja THEN
    SELECT sc.* INTO v_sesion FROM public.sesiones_caja AS sc WHERE sc.estado = 'ABIERTA' ORDER BY sc.fecha_apertura DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'La caja esta cerrada. Abrela antes de descontar dinero en efectivo.'; END IF;
    IF v_fecha < v_sesion.fecha_apertura THEN RAISE EXCEPTION 'La fecha del pago que afecta Caja Chica no puede ser anterior a la apertura de la caja.'; END IF;
    SELECT COALESCE(SUM(pv.monto), 0) INTO v_ingresos_efectivo FROM public.pagos_venta AS pv WHERE pv.fecha >= v_sesion.fecha_apertura AND TRIM(UPPER(pv.metodo)) LIKE '%EFECTIVO%';
    SELECT COALESCE(SUM(pg.monto), 0) INTO v_egresos_gastos FROM public.pagos_gasto AS pg WHERE pg.fecha >= v_sesion.fecha_apertura AND TRIM(UPPER(pg.metodo)) LIKE '%EFECTIVO%' AND COALESCE(pg.afecta_caja_chica, false) = true;
    SELECT COALESCE(SUM(pe.monto), 0) INTO v_egresos_personal FROM public.pagos_empleados AS pe WHERE pe.fecha >= v_sesion.fecha_apertura AND TRIM(UPPER(pe.metodo)) LIKE '%EFECTIVO%' AND COALESCE(pe.afecta_caja_chica, false) = true;
    v_saldo_disponible := v_sesion.monto_apertura + v_ingresos_efectivo - v_egresos_gastos - v_egresos_personal;
    IF v_monto > v_saldo_disponible + 0.000001 THEN RAISE EXCEPTION 'Saldo insuficiente en Caja Chica. Disponible: S/ %, solicitado: S/ %.', round(v_saldo_disponible, 2), round(v_monto, 2); END IF;
  END IF;

  IF p_es_cliente THEN
    SELECT * INTO v_venta FROM public.ventas WHERE id = p_deuda_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'La venta % no existe', p_deuda_id; END IF;
    IF LOWER(COALESCE(v_venta.estado, '')) <> 'pendiente' THEN RAISE EXCEPTION 'La venta % ya esta pagada o no permite abonos', p_deuda_id; END IF;
    v_saldo_venta := ROUND(COALESCE(v_venta.saldo, 0), 2);
    IF v_monto > v_saldo_venta + 0.01 THEN RAISE EXCEPTION 'El abono (%) supera el saldo pendiente (%)', v_monto, v_saldo_venta; END IF;
    INSERT INTO public.pagos_venta (venta_id, metodo, monto, fecha, request_id) VALUES (p_deuda_id, v_metodo, v_monto, v_fecha, p_request_id) RETURNING id INTO v_pago_id;
    SELECT GREATEST(ROUND(COALESCE(v_venta.total, 0) - COALESCE(SUM(pv.monto), 0), 2), 0) INTO v_saldo_venta FROM public.pagos_venta AS pv WHERE pv.venta_id = p_deuda_id;
    UPDATE public.ventas SET saldo = v_saldo_venta, estado = CASE WHEN v_saldo_venta <= 0.01 THEN 'pagado' ELSE 'pendiente' END WHERE id = p_deuda_id;
    v_resultado := jsonb_build_object('success', true, 'idempotent', false, 'request_id', p_request_id, 'tipo', 'cobro_cliente', 'deuda_id', p_deuda_id, 'pago_id', v_pago_id, 'monto', v_monto, 'saldo', v_saldo_venta);
  ELSE
    SELECT ROUND(COALESCE(g.saldo, 0), 2) INTO v_gasto_saldo FROM public.gastos AS g WHERE g.id = p_deuda_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'El gasto % no existe', p_deuda_id; END IF;
    IF v_monto > v_gasto_saldo + 0.01 THEN RAISE EXCEPTION 'El pago (%) supera el saldo pendiente del gasto (%)', v_monto, v_gasto_saldo; END IF;
    INSERT INTO public.pagos_gasto (gasto_id, metodo, monto, fecha, afecta_caja_chica, request_id) VALUES (p_deuda_id, v_metodo, v_monto, v_fecha, v_descontar_de_caja, p_request_id) RETURNING id INTO v_pago_id;
    v_nuevo_saldo := GREATEST(ROUND(v_gasto_saldo - v_monto, 2), 0);
    UPDATE public.gastos SET saldo = v_nuevo_saldo, estado = CASE WHEN v_nuevo_saldo <= 0.01 THEN 'pagado' ELSE 'pendiente' END WHERE id = p_deuda_id;
    v_resultado := jsonb_build_object('success', true, 'idempotent', false, 'request_id', p_request_id, 'tipo', 'pago_proveedor', 'deuda_id', p_deuda_id, 'pago_id', v_pago_id, 'monto', v_monto, 'saldo', v_nuevo_saldo);
  END IF;

  UPDATE public.pagos_deuda_requests SET resultado = v_resultado, completed_at = now() WHERE request_id = p_request_id;
  RETURN v_resultado;
END;
$function$;

REVOKE ALL ON FUNCTION public.procesar_pago_deuda_v2(uuid, boolean, bigint, numeric, text, timestamptz, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.procesar_pago_deuda_v2(uuid, boolean, bigint, numeric, text, timestamptz, boolean) TO authenticated;
