-- Fase 3.5 SaaS: defense-in-depth dentro de motores legacy conservados.
-- Los wrappers públicos ya validan tenant; estos parches evitan lecturas auxiliares globales.
BEGIN;

DO $patch_cancel_legacy$
DECLARE
  v_sig regprocedure := 'public.anular_venta_v2_unscaled_legacy(bigint,text)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;

  v_old:=E'WHERE e.auth_id = auth.uid()\n    AND COALESCE(e.activo, false) = true';
  v_new:=E'WHERE e.organization_id = private.require_current_organization_id()\n    AND e.auth_id = auth.uid()\n    AND COALESCE(e.activo, false) = true';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 cancel patch mismatch: actor'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.ventas\n  WHERE id = p_venta_id\n  FOR UPDATE;';
  v_new:=E'FROM public.ventas\n  WHERE organization_id = private.require_current_organization_id()\n    AND id = p_venta_id\n  FOR UPDATE;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 cancel patch mismatch: sale'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.empleados e\n  WHERE e.id = v_venta.vendedor_id;';
  v_new:=E'FROM public.empleados e\n  WHERE e.organization_id = private.require_current_organization_id()\n    AND e.id = v_venta.vendedor_id;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 cancel patch mismatch: seller snapshot'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'WHERE dv.venta_id = p_venta_id\n    ORDER BY dv.producto_id, dv.almacen_id';
  v_new:=E'WHERE dv.organization_id = private.require_current_organization_id()\n      AND dv.venta_id = p_venta_id\n    ORDER BY dv.producto_id, dv.almacen_id';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 cancel patch mismatch: sale details'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.constancias_descuento cd\n  WHERE cd.venta_id = p_venta_id;';
  v_new:=E'FROM public.constancias_descuento cd\n  WHERE cd.organization_id = private.require_current_organization_id()\n    AND cd.venta_id = p_venta_id;';
  IF strpos(v_def,v_old)>0 THEN v_def:=replace(v_def,v_old,v_new); END IF;

  v_old:=E'DELETE FROM public.constancias_descuento WHERE venta_id = p_venta_id;';
  v_new:=E'DELETE FROM public.constancias_descuento WHERE organization_id = private.require_current_organization_id() AND venta_id = p_venta_id;';
  IF strpos(v_def,v_old)>0 THEN v_def:=replace(v_def,v_old,v_new); END IF;

  v_old:=E'DELETE FROM public.pagos_venta WHERE venta_id = p_venta_id;';
  v_new:=E'DELETE FROM public.pagos_venta WHERE organization_id = private.require_current_organization_id() AND venta_id = p_venta_id;';
  IF strpos(v_def,v_old)>0 THEN v_def:=replace(v_def,v_old,v_new); END IF;

  v_old:=E'DELETE FROM public.detalle_ventas WHERE venta_id = p_venta_id;';
  v_new:=E'DELETE FROM public.detalle_ventas WHERE organization_id = private.require_current_organization_id() AND venta_id = p_venta_id;';
  IF strpos(v_def,v_old)>0 THEN v_def:=replace(v_def,v_old,v_new); END IF;

  v_old:=E'DELETE FROM public.ventas WHERE id = p_venta_id;';
  v_new:=E'DELETE FROM public.ventas WHERE organization_id = private.require_current_organization_id() AND id = p_venta_id;';
  IF strpos(v_def,v_old)>0 THEN v_def:=replace(v_def,v_old,v_new); END IF;

  EXECUTE v_def;
END;
$patch_cancel_legacy$;

DO $patch_debt_legacy$
DECLARE
  v_sig regprocedure := 'public._legacy_procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean)'::regprocedure;
  v_def text;
  v_old text;
  v_new text;
BEGIN
  SELECT pg_get_functiondef(v_sig) INTO v_def;

  v_old:=E'WHERE e.auth_id = v_auth_user_id\n    AND COALESCE(e.activo, false) = true';
  v_new:=E'WHERE e.organization_id = private.require_current_organization_id()\n    AND e.auth_id = v_auth_user_id\n    AND COALESCE(e.activo, false) = true';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 debt patch mismatch: actor'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.pagos_deuda_requests\n    WHERE request_id = p_request_id;';
  v_new:=E'FROM public.pagos_deuda_requests\n    WHERE organization_id = private.require_current_organization_id()\n      AND request_id = p_request_id;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 debt patch mismatch: request replay'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  v_old:=E'FROM public.ventas\n    WHERE id = p_deuda_id\n    FOR UPDATE;';
  v_new:=E'FROM public.ventas\n    WHERE organization_id = private.require_current_organization_id()\n      AND id = p_deuda_id\n    FOR UPDATE;';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'F3.5 debt patch mismatch: sale debt'; END IF;
  v_def:=replace(v_def,v_old,v_new);

  EXECUTE v_def;
END;
$patch_debt_legacy$;

REVOKE ALL ON FUNCTION public.anular_venta_v2_unscaled_legacy(bigint,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public._legacy_procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamptz,boolean) FROM PUBLIC,anon,authenticated;

COMMIT;
