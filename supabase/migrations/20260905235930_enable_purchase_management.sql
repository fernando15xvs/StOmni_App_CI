-- Habilita Compras sólo después de existir dominio, RPC seguro y clientes móvil/desktop.
BEGIN;

ALTER TABLE public.business_capabilities
  ADD COLUMN purchase_management boolean NOT NULL DEFAULT true;

UPDATE public.business_capabilities
SET purchase_management = true,
    revision = revision + 1,
    updated_at = now()
WHERE business_id = 1;

CREATE OR REPLACE FUNCTION public.get_business_profile_v1()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'No autorizado para consultar el negocio' USING ERRCODE = '42501';
  END IF;
  SELECT jsonb_build_object(
    'business_id', c.id::text,
    'display_name', COALESCE(NULLIF(c.nombre_comercial, ''), c.razon_social, ''),
    'revision', b.revision,
    'supports_capability_settings', true,
    'capabilities', jsonb_build_object(
      'inventory_enabled', true,
      'multiple_warehouses', true,
      'credit_sales', b.credit_sales,
      'electronic_invoicing', b.electronic_invoicing,
      'supplier_management', true,
      'purchase_management', b.purchase_management,
      'lot_tracking', false,
      'expiry_tracking', false,
      'variants', false,
      'services', false,
      'serial_number_tracking', false
    )
  ) INTO v_result
  FROM public.configuracion_negocio c
  JOIN public.business_capabilities b ON b.business_id = c.id
  WHERE c.id = 1;
  IF v_result IS NULL THEN
    RAISE EXCEPTION 'Configura primero el negocio y sus capacidades';
  END IF;
  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_business_capabilities_v1(
  p_expected_revision bigint,
  p_capabilities jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_current public.business_capabilities%ROWTYPE;
  v_fixed jsonb := '{"inventory_enabled":true,"multiple_warehouses":true,"supplier_management":true,"lot_tracking":false,"expiry_tracking":false,"variants":false,"services":false,"serial_number_tracking":false}'::jsonb;
BEGIN
  IF NOT public.app_tiene_permiso('business.configure') THEN
    RAISE EXCEPTION 'Solo el administrador configura capacidades' USING ERRCODE = '42501';
  END IF;
  IF p_capabilities IS NULL OR jsonb_typeof(p_capabilities) <> 'object'
     OR (p_capabilities - ARRAY['credit_sales','electronic_invoicing','purchase_management']) IS DISTINCT FROM v_fixed
     OR jsonb_typeof(p_capabilities->'credit_sales') IS DISTINCT FROM 'boolean'
     OR jsonb_typeof(p_capabilities->'electronic_invoicing') IS DISTINCT FROM 'boolean'
     OR jsonb_typeof(p_capabilities->'purchase_management') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION 'Capacidades no compatibles; no se activan módulos incompletos' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_current
  FROM public.business_capabilities
  WHERE business_id = 1
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el perfil de capacidades'; END IF;
  IF p_expected_revision IS NULL OR p_expected_revision <> v_current.revision THEN
    RAISE EXCEPTION 'La configuración cambió en otro dispositivo. Recarga antes de guardar.' USING ERRCODE = '40001';
  END IF;

  UPDATE public.business_capabilities SET
    credit_sales = (p_capabilities->>'credit_sales')::boolean,
    electronic_invoicing = (p_capabilities->>'electronic_invoicing')::boolean,
    purchase_management = (p_capabilities->>'purchase_management')::boolean,
    revision = revision + 1,
    updated_at = now()
  WHERE business_id = 1;
  RETURN public.get_business_profile_v1();
END;
$function$;

-- Defensa server-side frente a clientes antiguos/modificados: al apagar Compras
-- no se crean órdenes nuevas. Las recepciones existentes siguen disponibles
-- para no dejar compromisos de proveedor a medio cerrar.
CREATE OR REPLACE FUNCTION public._business_enforce_purchase_capability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE v_enabled boolean;
BEGIN
  SELECT purchase_management INTO v_enabled
  FROM public.business_capabilities
  WHERE business_id = 1
  FOR SHARE;
  IF coalesce(v_enabled, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'La gestión de compras está deshabilitada' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER business_guard_purchase_order
BEFORE INSERT ON public.purchase_orders
FOR EACH ROW EXECUTE FUNCTION public._business_enforce_purchase_capability();

REVOKE ALL ON FUNCTION public._business_enforce_purchase_capability()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_business_profile_v1() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_business_capabilities_v1(bigint,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_business_profile_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_business_capabilities_v1(bigint,jsonb) TO authenticated;

COMMIT;
