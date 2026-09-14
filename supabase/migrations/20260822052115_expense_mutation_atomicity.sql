-- StOmni - Fase 5
-- Backend-first rollout para eliminar pagos/gastos de forma atomica.
-- Esta migracion crea las RPC nuevas; el lockdown de permisos legacy queda para una migracion posterior tras smoke real.

CREATE OR REPLACE FUNCTION public.eliminar_pago_gasto_v1(p_pago_id bigint, p_gasto_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public, pg_catalog
AS $function$
DECLARE
  v_gasto public.gastos%ROWTYPE; v_pago public.pagos_gasto%ROWTYPE; v_total_pagado numeric := 0; v_nuevo_saldo numeric := 0; v_estado text;
BEGIN
  IF auth.uid() IS NULL OR NOT public.app_empleado_activo() THEN RAISE EXCEPTION 'Acceso denegado: empleado no autenticado o inactivo.'; END IF;
  IF p_pago_id IS NULL OR p_gasto_id IS NULL THEN RAISE EXCEPTION 'Pago y gasto son obligatorios.'; END IF;
  SELECT g.* INTO v_gasto FROM public.gastos AS g WHERE g.id = p_gasto_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Gasto no encontrado.'; END IF;
  SELECT pg.* INTO v_pago FROM public.pagos_gasto AS pg WHERE pg.id = p_pago_id AND pg.gasto_id = p_gasto_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Pago no encontrado para el gasto indicado.'; END IF;
  DELETE FROM public.pagos_gasto WHERE id = v_pago.id;
  SELECT COALESCE(SUM(pg.monto), 0) INTO v_total_pagado FROM public.pagos_gasto AS pg WHERE pg.gasto_id = p_gasto_id;
  v_nuevo_saldo := GREATEST(v_gasto.monto - v_total_pagado, 0);
  v_estado := CASE WHEN v_nuevo_saldo <= 0.02 THEN 'pagado' ELSE 'pendiente' END;
  UPDATE public.gastos SET saldo = v_nuevo_saldo, estado = v_estado WHERE id = p_gasto_id;
  RETURN jsonb_build_object('success', true, 'gasto_id', p_gasto_id, 'pago_id', p_pago_id, 'saldo', v_nuevo_saldo, 'estado', v_estado);
END;
$function$;

CREATE OR REPLACE FUNCTION public.eliminar_gasto_v1(p_gasto_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public, pg_catalog
AS $function$
DECLARE v_gasto public.gastos%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.app_empleado_activo() THEN RAISE EXCEPTION 'Acceso denegado: empleado no autenticado o inactivo.'; END IF;
  IF p_gasto_id IS NULL THEN RAISE EXCEPTION 'El gasto es obligatorio.'; END IF;
  SELECT g.* INTO v_gasto FROM public.gastos AS g WHERE g.id = p_gasto_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Gasto no encontrado.'; END IF;
  DELETE FROM public.gastos WHERE id = p_gasto_id;
  RETURN jsonb_build_object('success', true, 'gasto_id', p_gasto_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.eliminar_pago_gasto_v1(bigint, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eliminar_pago_gasto_v1(bigint, bigint) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.eliminar_gasto_v1(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.eliminar_gasto_v1(bigint) TO authenticated, service_role;
COMMENT ON FUNCTION public.eliminar_pago_gasto_v1(bigint, bigint) IS 'Elimina un pago de gasto y recalcula saldo/estado atomicamente. Fase 5.';
COMMENT ON FUNCTION public.eliminar_gasto_v1(bigint) IS 'Elimina gasto y pagos asociados en una sola transaccion. Fase 5.';
