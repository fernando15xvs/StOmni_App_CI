-- Aditiva: preparar y probar localmente antes de aplicarla a producción.
-- El backend existente es singleton (configuracion_negocio.id=1).
BEGIN;

CREATE TABLE public.business_capabilities (
  business_id bigint PRIMARY KEY REFERENCES public.configuracion_negocio(id),
  credit_sales boolean NOT NULL DEFAULT true,
  electronic_invoicing boolean NOT NULL DEFAULT true,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT business_capabilities_singleton CHECK (business_id = 1)
);

INSERT INTO public.business_capabilities (business_id)
SELECT id FROM public.configuracion_negocio WHERE id = 1;

ALTER TABLE public.business_capabilities ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.business_capabilities FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.business_capabilities TO authenticated;
CREATE POLICY business_capabilities_read ON public.business_capabilities
FOR SELECT TO authenticated USING (public.app_empleado_activo());

CREATE FUNCTION public.get_business_profile_v1()
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
      'inventory_enabled', true, 'multiple_warehouses', true,
      'credit_sales', b.credit_sales, 'electronic_invoicing', b.electronic_invoicing,
      'supplier_management', true, 'purchase_management', false,
      'lot_tracking', false, 'expiry_tracking', false, 'variants', false,
      'services', false, 'serial_number_tracking', false
    )
  ) INTO v_result
  FROM public.configuracion_negocio c
  JOIN public.business_capabilities b ON b.business_id = c.id
  WHERE c.id = 1;
  IF v_result IS NULL THEN RAISE EXCEPTION 'Configura primero el negocio y sus capacidades'; END IF;
  RETURN v_result;
END;
$function$;

CREATE FUNCTION public.update_business_capabilities_v1(p_expected_revision bigint, p_capabilities jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_current public.business_capabilities%ROWTYPE;
  v_fixed jsonb := '{"inventory_enabled":true,"multiple_warehouses":true,"supplier_management":true,"purchase_management":false,"lot_tracking":false,"expiry_tracking":false,"variants":false,"services":false,"serial_number_tracking":false}'::jsonb;
BEGIN
  IF NOT public.app_es_admin() THEN
    RAISE EXCEPTION 'Solo el administrador configura capacidades' USING ERRCODE = '42501';
  END IF;
  IF p_capabilities IS NULL OR jsonb_typeof(p_capabilities) <> 'object'
     OR (p_capabilities - ARRAY['credit_sales', 'electronic_invoicing']) IS DISTINCT FROM v_fixed
     OR jsonb_typeof(p_capabilities->'credit_sales') IS DISTINCT FROM 'boolean'
     OR jsonb_typeof(p_capabilities->'electronic_invoicing') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION 'Capacidades no compatibles; no se activan módulos incompletos' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_current FROM public.business_capabilities WHERE business_id = 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el perfil de capacidades'; END IF;
  IF p_expected_revision IS NULL OR p_expected_revision <> v_current.revision THEN
    RAISE EXCEPTION 'La configuración cambió en otro dispositivo. Recarga antes de guardar.' USING ERRCODE = '40001';
  END IF;
  UPDATE public.business_capabilities SET
    credit_sales = (p_capabilities->>'credit_sales')::boolean,
    electronic_invoicing = (p_capabilities->>'electronic_invoicing')::boolean,
    revision = revision + 1, updated_at = now()
  WHERE business_id = 1;
  RETURN public.get_business_profile_v1();
END;
$function$;

-- Control transaccional: las llamadas desde versiones antiguas también cumplen
-- las capacidades. No se bloquea cobrar deudas ni reintentar documentos previos.
CREATE FUNCTION public._business_enforce_new_sale_capabilities()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_cap public.business_capabilities%ROWTYPE;
BEGIN
  -- Comparte bloqueo con el cambio de configuración: sin carrera entre ambos.
  SELECT * INTO v_cap FROM public.business_capabilities WHERE business_id = 1 FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe la configuración de capacidades'; END IF;
  IF TG_TABLE_NAME = 'ventas' THEN
    IF NOT v_cap.credit_sales AND COALESCE(NEW.saldo, 0) > 0 THEN
      RAISE EXCEPTION 'Las ventas a crédito están deshabilitadas' USING ERRCODE = '23514';
    END IF;
    IF NOT v_cap.electronic_invoicing AND
       lower(COALESCE(NEW.tipo_comprobante_solicitado, '')) IN ('boleta', 'factura') THEN
      RAISE EXCEPTION 'La emisión electrónica está deshabilitada' USING ERRCODE = '23514';
    END IF;
  ELSIF TG_TABLE_NAME = 'comprobantes_electronicos' AND NOT v_cap.electronic_invoicing THEN
    RAISE EXCEPTION 'La emisión electrónica está deshabilitada' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER business_guard_new_sale BEFORE INSERT ON public.ventas
FOR EACH ROW EXECUTE FUNCTION public._business_enforce_new_sale_capabilities();
CREATE TRIGGER business_guard_new_invoice BEFORE INSERT ON public.comprobantes_electronicos
FOR EACH ROW EXECUTE FUNCTION public._business_enforce_new_sale_capabilities();

REVOKE ALL ON FUNCTION public.get_business_profile_v1() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_business_capabilities_v1(bigint, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._business_enforce_new_sale_capabilities() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_business_profile_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_business_capabilities_v1(bigint, jsonb) TO authenticated;

COMMIT;
