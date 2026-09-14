-- Fase 5: integridad al desactivar/reactivar almacenes.

CREATE OR REPLACE FUNCTION public._validar_desactivacion_almacen_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE v_filas_con_stock bigint; v_stock_total bigint;
BEGIN
  IF OLD.activo IS NOT DISTINCT FROM NEW.activo OR COALESCE(NEW.activo, false) = true THEN RETURN NEW; END IF;
  SELECT COUNT(*) FILTER (WHERE COALESCE(ia.cantidad, 0) <> 0), COALESCE(SUM(COALESCE(ia.cantidad, 0)), 0)
  INTO v_filas_con_stock, v_stock_total FROM public.inventario_almacen AS ia WHERE ia.almacen_id = OLD.id;
  IF COALESCE(v_filas_con_stock, 0) > 0 THEN RAISE EXCEPTION 'No se puede desactivar el almacen: contiene stock. Stock neto actual: %.', v_stock_total; END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_validar_desactivacion_almacen_v1 ON public.almacenes;
CREATE TRIGGER trg_validar_desactivacion_almacen_v1 BEFORE UPDATE OF activo ON public.almacenes FOR EACH ROW EXECUTE FUNCTION public._validar_desactivacion_almacen_v1();

CREATE OR REPLACE FUNCTION public._validar_stock_en_almacen_activo_v1()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE v_activo boolean;
BEGIN
  IF COALESCE(NEW.cantidad, 0) = 0 THEN RETURN NEW; END IF;
  SELECT a.activo INTO v_activo FROM public.almacenes AS a WHERE a.id = NEW.almacen_id FOR KEY SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Almacen % no existe', NEW.almacen_id; END IF;
  IF COALESCE(v_activo, false) = false THEN RAISE EXCEPTION 'No se puede registrar stock en un almacen inactivo. Reactivalo primero.'; END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_validar_stock_en_almacen_activo_v1 ON public.inventario_almacen;
CREATE TRIGGER trg_validar_stock_en_almacen_activo_v1 BEFORE INSERT OR UPDATE OF almacen_id, cantidad ON public.inventario_almacen FOR EACH ROW EXECUTE FUNCTION public._validar_stock_en_almacen_activo_v1();

CREATE OR REPLACE FUNCTION public.desactivar_almacen_seguro_v1(p_almacen_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE v_almacen public.almacenes%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Usuario no autenticado'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.empleados AS e WHERE e.auth_id = auth.uid() AND COALESCE(e.activo, false) = true AND LOWER(COALESCE(e.rol, '')) = 'admin') THEN RAISE EXCEPTION 'Solo un administrador activo puede desactivar almacenes'; END IF;
  SELECT * INTO v_almacen FROM public.almacenes WHERE id = p_almacen_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Almacen no encontrado'; END IF;
  IF COALESCE(v_almacen.activo, false) = false THEN RETURN jsonb_build_object('success', true, 'idempotent', true, 'almacen_id', p_almacen_id, 'activo', false); END IF;
  UPDATE public.almacenes SET activo = false, updated_at = now() WHERE id = p_almacen_id;
  RETURN jsonb_build_object('success', true, 'idempotent', false, 'almacen_id', p_almacen_id, 'activo', false);
END;
$function$;

CREATE OR REPLACE FUNCTION public.reactivar_almacen_seguro_v1(p_almacen_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE v_almacen public.almacenes%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Usuario no autenticado'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.empleados AS e WHERE e.auth_id = auth.uid() AND COALESCE(e.activo, false) = true AND LOWER(COALESCE(e.rol, '')) = 'admin') THEN RAISE EXCEPTION 'Solo un administrador activo puede reactivar almacenes'; END IF;
  SELECT * INTO v_almacen FROM public.almacenes WHERE id = p_almacen_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Almacen no encontrado'; END IF;
  IF COALESCE(v_almacen.activo, false) = true THEN RETURN jsonb_build_object('success', true, 'idempotent', true, 'almacen_id', p_almacen_id, 'activo', true); END IF;
  UPDATE public.almacenes SET activo = true, updated_at = now() WHERE id = p_almacen_id;
  RETURN jsonb_build_object('success', true, 'idempotent', false, 'almacen_id', p_almacen_id, 'activo', true);
END;
$function$;

REVOKE ALL ON FUNCTION public._validar_desactivacion_almacen_v1() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._validar_stock_en_almacen_activo_v1() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.desactivar_almacen_seguro_v1(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.desactivar_almacen_seguro_v1(bigint) TO authenticated;
REVOKE ALL ON FUNCTION public.reactivar_almacen_seguro_v1(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reactivar_almacen_seguro_v1(bigint) TO authenticated;
DROP POLICY IF EXISTS almacenes_admin_delete ON public.almacenes;
REVOKE DELETE ON TABLE public.almacenes FROM anon, authenticated;
