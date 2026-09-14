-- F2.3 hardening transversal: el dashboard legacy agregaba tablas globalmente.
-- Caja/movimientos queda fuera hasta F4.3; ingresos/egresos operativos se derivan
-- de pagos de ventas/gastos ya tenant-aware para no mezclar organizaciones.
BEGIN;

CREATE OR REPLACE FUNCTION public.get_dashboard_summary(
  inicio timestamptz,
  fin timestamptz
)
RETURNS json
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_org uuid := private.require_current_organization_id();
  v_ingresos_hoy numeric := 0;
  v_egresos_hoy numeric := 0;
  v_total_productos bigint := 0;
  v_low_stock integer := 0;
  v_out_of_stock integer := 0;
  v_por_cobrar numeric := 0;
  v_por_pagar numeric := 0;
BEGIN
  IF NOT private.has_permission('tenant.read') THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Tenant read permission required';
  END IF;

  IF inicio IS NULL OR fin IS NULL OR fin <= inicio THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Invalid dashboard date range';
  END IF;

  SELECT COALESCE(SUM(pv.monto), 0)
  INTO v_ingresos_hoy
  FROM public.pagos_venta pv
  WHERE pv.organization_id = v_org
    AND pv.fecha >= inicio
    AND pv.fecha < fin;

  SELECT COALESCE(SUM(pg.monto), 0)
  INTO v_egresos_hoy
  FROM public.pagos_gasto pg
  WHERE pg.organization_id = v_org
    AND pg.fecha >= inicio
    AND pg.fecha < fin;

  SELECT count(*)
  INTO v_total_productos
  FROM public.productos p
  WHERE p.organization_id = v_org
    AND COALESCE(p.activo, true) = true;

  SELECT count(*)::integer
  INTO v_low_stock
  FROM (
    SELECT p.id
    FROM public.productos p
    JOIN public.inventario_almacen ia
      ON ia.organization_id = p.organization_id
     AND ia.producto_id = p.id
    WHERE p.organization_id = v_org
      AND COALESCE(p.activo, true) = true
    GROUP BY p.id, p.stock_minimo
    HAVING SUM(COALESCE(ia.cantidad, 0)) <= COALESCE(p.stock_minimo, 0)
       AND SUM(COALESCE(ia.cantidad, 0)) > 0
  ) scoped_low_stock;

  SELECT count(*)::integer
  INTO v_out_of_stock
  FROM (
    SELECT p.id
    FROM public.productos p
    LEFT JOIN public.inventario_almacen ia
      ON ia.organization_id = p.organization_id
     AND ia.producto_id = p.id
    WHERE p.organization_id = v_org
      AND COALESCE(p.activo, true) = true
    GROUP BY p.id
    HAVING COALESCE(SUM(ia.cantidad), 0) <= 0
  ) scoped_out_of_stock;

  SELECT COALESCE(SUM(v.saldo), 0)
  INTO v_por_cobrar
  FROM public.ventas v
  WHERE v.organization_id = v_org
    AND v.estado = 'pendiente'
    AND v.cliente_id IS NOT NULL;

  SELECT COALESCE(SUM(g.saldo), 0)
  INTO v_por_pagar
  FROM public.gastos g
  WHERE g.organization_id = v_org
    AND g.estado = 'pendiente'
    AND g.proveedor_id IS NOT NULL;

  RETURN json_build_object(
    'ingresos_hoy', v_ingresos_hoy,
    'egresos_hoy', v_egresos_hoy,
    -- Compatibilidad con consumidores Flutter existentes.
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

REVOKE ALL ON FUNCTION public.get_dashboard_summary(timestamptz,timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_dashboard_summary(timestamptz,timestamptz)
  TO authenticated;

COMMENT ON FUNCTION public.get_dashboard_summary(timestamptz,timestamptz) IS
  'Resumen operativo del tenant actual. No consulta movimientos/caja global; Caja se integra al recibir organization_id en F4.3.';

COMMIT;
