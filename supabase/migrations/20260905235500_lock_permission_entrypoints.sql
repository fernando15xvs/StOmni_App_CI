BEGIN;

CREATE OR REPLACE FUNCTION public._enforce_sale_employee_permissions()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
BEGIN
  -- Service-role jobs remain available for controlled administrative recovery.
  IF coalesce(auth.role(), '') = 'service_role' THEN
    RETURN NEW;
  END IF;
  IF NOT public.app_tiene_permiso('sales.create') THEN
    RAISE EXCEPTION 'No tienes permiso para registrar ventas' USING ERRCODE = '42501';
  END IF;
  IF coalesce(NEW.descuento_global_monto, 0) > 0
     AND NOT public.app_tiene_permiso('sales.discount') THEN
    RAISE EXCEPTION 'No tienes permiso para aplicar descuentos' USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS employee_permission_guard_sale ON public.ventas;
CREATE TRIGGER employee_permission_guard_sale
BEFORE INSERT ON public.ventas
FOR EACH ROW EXECUTE FUNCTION public._enforce_sale_employee_permissions();

-- Después de esta migración los clientes deben usar los wrappers autorizados.
REVOKE EXECUTE ON FUNCTION public.registrar_merma_scaled_v1(uuid,bigint,bigint,numeric,text,timestamptz) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.trasladar_stock_scaled_v1(uuid,bigint,bigint,bigint,numeric,text,timestamptz) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.registrar_ingreso_mercaderia_scaled_v1(uuid,bigint,timestamptz,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.ajustar_stock_scaled_v1(bigint,bigint,numeric,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric) FROM authenticated;

REVOKE ALL ON FUNCTION public._enforce_sale_employee_permissions() FROM PUBLIC, anon, authenticated;

COMMIT;
