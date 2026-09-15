-- StOmni - Fase 5
-- Hardening derivado de Security/Performance Advisors y revision directa del dump.

ALTER FUNCTION public.set_facturacion_updated_at() SET search_path TO public, pg_catalog;
ALTER FUNCTION public.set_vendedor_observaciones_kardex() SET search_path TO public, pg_catalog;
ALTER FUNCTION public.vincular_usuario_empleado() SET search_path TO public, pg_catalog;
ALTER FUNCTION public.increment_stock(bigint, bigint, integer) SET search_path TO public, pg_catalog;

REVOKE EXECUTE ON FUNCTION public.set_facturacion_updated_at() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.set_vendedor_observaciones_kardex() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._gre_supervisor() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._gre_supervisor() TO service_role;
REVOKE EXECUTE ON FUNCTION public.increment_stock(bigint, bigint, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.increment_stock(bigint, bigint, integer) TO service_role;

ALTER POLICY series_select_empleado ON public.series_comprobantes
USING (EXISTS (SELECT 1 FROM public.empleados AS e WHERE e.auth_id = (SELECT auth.uid()) AND COALESCE(e.activo, false) = true));

ALTER TABLE public.inventario_almacen DROP CONSTRAINT IF EXISTS inventario_almacen_producto_id_almacen_id_key1;

ALTER TABLE public.clientes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Permitir todo en clientes" ON public.clientes;
DROP POLICY IF EXISTS clientes_empleado_select ON public.clientes;
DROP POLICY IF EXISTS clientes_empleado_insert ON public.clientes;
DROP POLICY IF EXISTS clientes_empleado_update ON public.clientes;
DROP POLICY IF EXISTS clientes_empleado_delete ON public.clientes;
CREATE POLICY clientes_empleado_select ON public.clientes FOR SELECT TO authenticated USING (public.app_empleado_activo());
CREATE POLICY clientes_empleado_insert ON public.clientes FOR INSERT TO authenticated WITH CHECK (public.app_empleado_activo());
CREATE POLICY clientes_empleado_update ON public.clientes FOR UPDATE TO authenticated USING (public.app_empleado_activo()) WITH CHECK (public.app_empleado_activo());
CREATE POLICY clientes_empleado_delete ON public.clientes FOR DELETE TO authenticated USING (public.app_empleado_activo());
REVOKE ALL ON TABLE public.clientes FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.clientes TO authenticated;
REVOKE ALL ON SEQUENCE public.clientes_id_seq FROM anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.clientes_id_seq TO authenticated;

ALTER TABLE public.transferencias_stock ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Permitir todo en transferencias_stock" ON public.transferencias_stock;
DROP POLICY IF EXISTS transferencias_stock_select_empleado ON public.transferencias_stock;
CREATE POLICY transferencias_stock_select_empleado ON public.transferencias_stock FOR SELECT TO authenticated USING (public.app_empleado_activo());
REVOKE ALL ON TABLE public.transferencias_stock FROM anon, authenticated;
GRANT SELECT ON TABLE public.transferencias_stock TO authenticated;
REVOKE ALL ON SEQUENCE public.transferencias_stock_id_seq FROM anon, authenticated;

REVOKE ALL ON TABLE public.inventario_operaciones_idempotentes FROM anon, authenticated;
REVOKE ALL ON TABLE public.sys_processed_requests FROM anon, authenticated;
DROP FUNCTION IF EXISTS public.tributario_finalizar_proceso(bigint);
