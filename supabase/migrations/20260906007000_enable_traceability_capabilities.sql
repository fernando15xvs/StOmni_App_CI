-- Cutover opt-in: el backend ya soporta lotes, vencimientos y series, pero no
-- se activa ninguna capacidad automáticamente en negocios existentes.
BEGIN;

ALTER TABLE public.business_capabilities
  ADD COLUMN lot_tracking boolean NOT NULL DEFAULT false,
  ADD COLUMN expiry_tracking boolean NOT NULL DEFAULT false,
  ADD COLUMN serial_number_tracking boolean NOT NULL DEFAULT false,
  ADD CONSTRAINT business_capabilities_expiry_requires_lot
    CHECK (NOT expiry_tracking OR lot_tracking);

CREATE OR REPLACE FUNCTION public.get_business_profile_v1()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public
AS $function$
DECLARE v_result jsonb;
BEGIN
  IF NOT public.app_empleado_activo() THEN
    RAISE EXCEPTION 'No autorizado para consultar el negocio' USING ERRCODE='42501';
  END IF;
  SELECT jsonb_build_object(
    'business_id',c.id::text,
    'display_name',COALESCE(NULLIF(c.nombre_comercial,''),c.razon_social,''),
    'revision',b.revision,
    'supports_capability_settings',true,
    'capabilities',jsonb_build_object(
      'inventory_enabled',true,
      'multiple_warehouses',true,
      'credit_sales',b.credit_sales,
      'electronic_invoicing',b.electronic_invoicing,
      'supplier_management',true,
      'purchase_management',b.purchase_management,
      'lot_tracking',b.lot_tracking,
      'expiry_tracking',b.expiry_tracking,
      'variants',b.variants,
      'services',false,
      'serial_number_tracking',b.serial_number_tracking
    )
  ) INTO v_result
  FROM public.configuracion_negocio c
  JOIN public.business_capabilities b ON b.business_id=c.id
  WHERE c.id=1;
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
SET search_path=pg_catalog,public
AS $function$
DECLARE
  v_current public.business_capabilities%ROWTYPE;
  v_fixed jsonb := '{"inventory_enabled":true,"multiple_warehouses":true,"supplier_management":true,"services":false}'::jsonb;
  v_lot boolean;
  v_expiry boolean;
  v_serial boolean;
BEGIN
  IF NOT public.app_tiene_permiso('business.configure') THEN
    RAISE EXCEPTION 'Solo el administrador configura capacidades' USING ERRCODE='42501';
  END IF;
  IF p_capabilities IS NULL OR jsonb_typeof(p_capabilities)<>'object'
     OR (p_capabilities - ARRAY[
       'credit_sales','electronic_invoicing','purchase_management','variants',
       'lot_tracking','expiry_tracking','serial_number_tracking'
     ]) IS DISTINCT FROM v_fixed
     OR jsonb_typeof(p_capabilities->'credit_sales') IS DISTINCT FROM 'boolean'
     OR jsonb_typeof(p_capabilities->'electronic_invoicing') IS DISTINCT FROM 'boolean'
     OR jsonb_typeof(p_capabilities->'purchase_management') IS DISTINCT FROM 'boolean'
     OR jsonb_typeof(p_capabilities->'variants') IS DISTINCT FROM 'boolean'
     OR jsonb_typeof(p_capabilities->'lot_tracking') IS DISTINCT FROM 'boolean'
     OR jsonb_typeof(p_capabilities->'expiry_tracking') IS DISTINCT FROM 'boolean'
     OR jsonb_typeof(p_capabilities->'serial_number_tracking') IS DISTINCT FROM 'boolean' THEN
    RAISE EXCEPTION 'Capacidades no compatibles' USING ERRCODE='22023';
  END IF;

  v_lot:=(p_capabilities->>'lot_tracking')::boolean;
  v_expiry:=(p_capabilities->>'expiry_tracking')::boolean;
  v_serial:=(p_capabilities->>'serial_number_tracking')::boolean;
  IF v_expiry AND NOT v_lot THEN
    RAISE EXCEPTION 'El seguimiento de vencimientos requiere seguimiento por lote'
      USING ERRCODE='23514';
  END IF;

  SELECT * INTO v_current FROM public.business_capabilities
  WHERE business_id=1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No existe el perfil de capacidades'; END IF;
  IF p_expected_revision IS NULL OR p_expected_revision<>v_current.revision THEN
    RAISE EXCEPTION 'La configuración cambió en otro dispositivo. Recarga antes de guardar.'
      USING ERRCODE='40001';
  END IF;

  -- No se permite apagar una capacidad si aún existe stock que depende de ella.
  IF v_current.lot_tracking AND NOT v_lot AND EXISTS(
    SELECT 1 FROM public.inventory_lots WHERE base_quantity>0
  ) THEN
    RAISE EXCEPTION 'No puedes desactivar lotes mientras exista stock por lote'
      USING ERRCODE='23514';
  END IF;
  IF v_current.serial_number_tracking AND NOT v_serial AND EXISTS(
    SELECT 1 FROM public.inventory_serials WHERE status='in_stock'
  ) THEN
    RAISE EXCEPTION 'No puedes desactivar series mientras exista stock seriado'
      USING ERRCODE='23514';
  END IF;

  UPDATE public.business_capabilities SET
    credit_sales=(p_capabilities->>'credit_sales')::boolean,
    electronic_invoicing=(p_capabilities->>'electronic_invoicing')::boolean,
    purchase_management=(p_capabilities->>'purchase_management')::boolean,
    variants=(p_capabilities->>'variants')::boolean,
    lot_tracking=v_lot,
    expiry_tracking=v_expiry,
    serial_number_tracking=v_serial,
    revision=revision+1,
    updated_at=now()
  WHERE business_id=1;
  RETURN public.get_business_profile_v1();
END;
$function$;

REVOKE ALL ON FUNCTION public.get_business_profile_v1() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.update_business_capabilities_v1(bigint,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_business_profile_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_business_capabilities_v1(bigint,jsonb) TO authenticated;

COMMIT;
