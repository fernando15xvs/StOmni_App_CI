-- Fase 3.1 SaaS: configuracion y capacidades por organizacion.
-- Migra el singleton legacy a un tenant real y elimina id=1/business_id=1 del runtime de este dominio.
BEGIN;

DO $backfill$
DECLARE
  v_unscoped_configs integer;
  v_unscoped_capabilities integer;
  v_config_id integer;
  v_organization_id uuid;
  v_display_name text;
  v_legal_name text;
BEGIN
  SELECT count(*)::integer
  INTO v_unscoped_configs
  FROM public.configuracion_negocio
  WHERE organization_id IS NULL;

  IF v_unscoped_configs > 1 THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = 'Ambiguous legacy state: more than one unscoped business configuration';
  END IF;

  IF v_unscoped_configs = 1 THEN
    SELECT
      c.id,
      COALESCE(
        NULLIF(btrim(c.nombre_comercial), ''),
        NULLIF(btrim(c.razon_social), '')
      ),
      NULLIF(btrim(c.razon_social), '')
    INTO v_config_id, v_display_name, v_legal_name
    FROM public.configuracion_negocio AS c
    WHERE c.organization_id IS NULL
    FOR UPDATE;

    IF v_display_name IS NULL THEN
      RAISE EXCEPTION USING
        ERRCODE = '23514',
        MESSAGE = 'Legacy business configuration requires a display or legal name before tenant backfill';
    END IF;

    INSERT INTO public.organizations (
      legal_name,
      display_name,
      country_code,
      currency_code,
      timezone,
      status
    ) VALUES (
      v_legal_name,
      v_display_name,
      'PE',
      'PEN',
      'America/Lima',
      'active'
    )
    RETURNING id INTO v_organization_id;

    UPDATE public.configuracion_negocio
    SET organization_id = v_organization_id
    WHERE id = v_config_id;

    SELECT count(*)::integer
    INTO v_unscoped_capabilities
    FROM public.business_capabilities
    WHERE organization_id IS NULL;

    IF v_unscoped_capabilities > 1 THEN
      RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = 'Ambiguous legacy state: more than one unscoped business capabilities row';
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.business_capabilities
      WHERE organization_id IS NULL
        AND business_id <> v_config_id
    ) THEN
      RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = 'Legacy capabilities do not reference the legacy configuration being migrated';
    END IF;

    UPDATE public.business_capabilities
    SET organization_id = v_organization_id
    WHERE organization_id IS NULL
      AND business_id = v_config_id;

    IF NOT EXISTS (
      SELECT 1
      FROM public.business_capabilities
      WHERE organization_id = v_organization_id
    ) THEN
      INSERT INTO public.business_capabilities (
        business_id,
        organization_id
      ) VALUES (
        v_config_id,
        v_organization_id
      );
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.empleados AS e
      JOIN public.app_users AS au
        ON au.user_id = COALESCE(e.app_user_id, e.auth_id)
      WHERE e.organization_id IS NULL
        AND COALESCE(e.app_user_id, e.auth_id) IS NOT NULL
        AND au.organization_id <> v_organization_id
    ) THEN
      RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = 'A legacy employee identity already belongs to another organization';
    END IF;

    INSERT INTO public.app_users (
      user_id,
      organization_id,
      status,
      base_role
    )
    SELECT DISTINCT
      e.auth_id,
      v_organization_id,
      CASE WHEN COALESCE(e.activo, false) THEN 'active' ELSE 'disabled' END,
      CASE WHEN e.rol = 'admin' THEN 'admin' ELSE 'operador' END
    FROM public.empleados AS e
    WHERE e.organization_id IS NULL
      AND e.auth_id IS NOT NULL
    ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.empleados AS e
    SET
      organization_id = v_organization_id,
      app_user_id = COALESCE(e.app_user_id, e.auth_id)
    WHERE e.organization_id IS NULL;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.configuracion_negocio WHERE organization_id IS NULL
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Unscoped business configuration remains after tenant backfill';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.business_capabilities WHERE organization_id IS NULL
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Unscoped business capabilities remain after tenant backfill';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.empleados WHERE organization_id IS NULL
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Unscoped employees remain after tenant backfill';
  END IF;
END;
$backfill$;

ALTER TABLE public.empleados
  VALIDATE CONSTRAINT empleados_organization_required,
  VALIDATE CONSTRAINT empleados_auth_app_user_consistent,
  ALTER COLUMN organization_id SET NOT NULL;

ALTER TABLE public.configuracion_negocio
  ALTER COLUMN organization_id SET NOT NULL;

ALTER TABLE public.business_capabilities
  ALTER COLUMN organization_id SET NOT NULL;

-- Configuracion y capabilities se escriben exclusivamente por RPC para preservar
-- allowlists, validaciones fiscales y optimistic locking de revision.
DROP POLICY IF EXISTS configuracion_tenant_update ON public.configuracion_negocio;
DROP POLICY IF EXISTS business_capabilities_tenant_update ON public.business_capabilities;
REVOKE UPDATE ON TABLE public.configuracion_negocio FROM authenticated;
REVOKE UPDATE ON TABLE public.business_capabilities FROM authenticated;

CREATE OR REPLACE FUNCTION public.get_current_business_configuration_v1()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_result jsonb;
BEGIN
  IF NOT private.has_permission('tenant.read') THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Business configuration read permission required';
  END IF;

  SELECT
    to_jsonb(c)
    || jsonb_build_object(
      'country_code', o.country_code,
      'currency_code', o.currency_code,
      'timezone', o.timezone
    )
  INTO v_result
  FROM public.configuracion_negocio AS c
  JOIN public.organizations AS o
    ON o.id = c.organization_id
  WHERE c.organization_id = v_organization_id;

  IF v_result IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0002',
      MESSAGE = 'Business configuration not found for current organization';
  END IF;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.actualizar_configuracion_negocio_v1(p_datos jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_row public.configuracion_negocio%ROWTYPE;
  v_ruc text;
  v_ubigeo text;
  v_razon_social text;
  v_direccion text;
  v_departamento text;
  v_provincia text;
  v_distrito text;
  v_cod_local text;
  v_keys_permitidas constant text[] := ARRAY[
    'razon_social', 'nombre_comercial', 'ruc', 'direccion', 'ubigeo',
    'departamento', 'provincia', 'distrito', 'cod_local', 'telefono', 'logo_url'
  ];
  v_key text;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Tenant administrator permission required';
  END IF;

  IF p_datos IS NULL OR jsonb_typeof(p_datos) <> 'object' THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = 'Invalid business configuration payload';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_datos)
  LOOP
    IF NOT (v_key = ANY (v_keys_permitidas)) THEN
      RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = format('Field not allowed in business profile: %s', v_key);
    END IF;
  END LOOP;

  SELECT *
  INTO v_row
  FROM public.configuracion_negocio
  WHERE organization_id = v_organization_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0002',
      MESSAGE = 'Business configuration not found for current organization';
  END IF;

  v_ruc := btrim(COALESCE(p_datos->>'ruc', v_row.ruc, ''));
  v_ubigeo := btrim(COALESCE(p_datos->>'ubigeo', v_row.ubigeo, ''));
  v_razon_social := btrim(COALESCE(p_datos->>'razon_social', v_row.razon_social, ''));
  v_direccion := btrim(COALESCE(p_datos->>'direccion', v_row.direccion, ''));
  v_departamento := upper(btrim(COALESCE(p_datos->>'departamento', v_row.departamento, '')));
  v_provincia := upper(btrim(COALESCE(p_datos->>'provincia', v_row.provincia, '')));
  v_distrito := upper(btrim(COALESCE(p_datos->>'distrito', v_row.distrito, '')));
  v_cod_local := btrim(COALESCE(p_datos->>'cod_local', v_row.cod_local, '0000'));

  IF v_ruc !~ '^[0-9]{11}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'RUC must contain exactly 11 digits';
  END IF;
  IF v_ubigeo !~ '^[0-9]{6}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Ubigeo must contain exactly 6 digits';
  END IF;
  IF v_razon_social = '' OR v_direccion = '' OR v_departamento = ''
     OR v_provincia = '' OR v_distrito = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Complete fiscal identity and address are required';
  END IF;
  IF v_cod_local !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Local code must contain exactly 4 digits';
  END IF;

  UPDATE public.configuracion_negocio AS c
  SET
    razon_social = CASE WHEN p_datos ? 'razon_social' THEN v_razon_social ELSE c.razon_social END,
    nombre_comercial = CASE WHEN p_datos ? 'nombre_comercial' THEN NULLIF(btrim(p_datos->>'nombre_comercial'), '') ELSE c.nombre_comercial END,
    ruc = CASE WHEN p_datos ? 'ruc' THEN v_ruc ELSE c.ruc END,
    direccion = CASE WHEN p_datos ? 'direccion' THEN v_direccion ELSE c.direccion END,
    ubigeo = CASE WHEN p_datos ? 'ubigeo' THEN v_ubigeo ELSE c.ubigeo END,
    departamento = CASE WHEN p_datos ? 'departamento' THEN v_departamento ELSE c.departamento END,
    provincia = CASE WHEN p_datos ? 'provincia' THEN v_provincia ELSE c.provincia END,
    distrito = CASE WHEN p_datos ? 'distrito' THEN v_distrito ELSE c.distrito END,
    cod_local = CASE WHEN p_datos ? 'cod_local' THEN v_cod_local ELSE c.cod_local END,
    telefono = CASE WHEN p_datos ? 'telefono' THEN NULLIF(btrim(p_datos->>'telefono'), '') ELSE c.telefono END,
    logo_url = CASE WHEN p_datos ? 'logo_url' THEN NULLIF(btrim(p_datos->>'logo_url'), '') ELSE c.logo_url END
  WHERE c.organization_id = v_organization_id;

  RETURN public.get_current_business_configuration_v1();
END;
$$;

CREATE OR REPLACE FUNCTION public.get_business_profile_v1()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_result jsonb;
BEGIN
  IF NOT private.has_permission('tenant.read') THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Business profile read permission required';
  END IF;

  SELECT jsonb_build_object(
    'organization_id', v_organization_id,
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
      'lot_tracking', b.lot_tracking,
      'expiry_tracking', b.expiry_tracking,
      'variants', b.variants,
      'services', b.services,
      'serial_number_tracking', b.serial_number_tracking
    )
  )
  INTO v_result
  FROM public.configuracion_negocio AS c
  JOIN public.business_capabilities AS b
    ON b.organization_id = c.organization_id
   AND b.business_id = c.id
  WHERE c.organization_id = v_organization_id;

  IF v_result IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0002',
      MESSAGE = 'Business profile not configured for current organization';
  END IF;

  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_business_capabilities_v1(
  p_expected_revision bigint,
  p_capabilities jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_current public.business_capabilities%ROWTYPE;
  v_lot boolean;
  v_expiry boolean;
  v_serial boolean;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'Tenant administrator permission required';
  END IF;

  IF p_capabilities IS NULL OR jsonb_typeof(p_capabilities) <> 'object'
     OR (p_capabilities - ARRAY[
       'credit_sales', 'electronic_invoicing', 'purchase_management', 'variants',
       'lot_tracking', 'expiry_tracking', 'serial_number_tracking', 'services'
     ]) IS DISTINCT FROM '{"inventory_enabled":true,"multiple_warehouses":true,"supplier_management":true}'::jsonb
     OR EXISTS (
       SELECT 1
       FROM jsonb_each(p_capabilities) AS e
       WHERE e.key IN (
         'credit_sales', 'electronic_invoicing', 'purchase_management', 'variants',
         'lot_tracking', 'expiry_tracking', 'serial_number_tracking', 'services'
       )
         AND jsonb_typeof(e.value) <> 'boolean'
     ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Unsupported capabilities payload';
  END IF;

  v_lot := (p_capabilities->>'lot_tracking')::boolean;
  v_expiry := (p_capabilities->>'expiry_tracking')::boolean;
  v_serial := (p_capabilities->>'serial_number_tracking')::boolean;

  IF v_expiry AND NOT v_lot THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Expiry tracking requires lot tracking';
  END IF;

  SELECT *
  INTO v_current
  FROM public.business_capabilities
  WHERE organization_id = v_organization_id
  FOR UPDATE;

  IF NOT FOUND OR p_expected_revision IS NULL OR p_expected_revision <> v_current.revision THEN
    RAISE EXCEPTION USING
      ERRCODE = '40001',
      MESSAGE = 'Business configuration changed; reload before saving';
  END IF;

  -- Estos inventarios reciben organization_id en Fase 3.4. Hasta entonces se
  -- conserva el guard histórico global para impedir pérdida de trazabilidad.
  IF v_current.lot_tracking AND NOT v_lot
     AND EXISTS (SELECT 1 FROM public.inventory_lots WHERE base_quantity > 0) THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Cannot disable lots while lot stock exists';
  END IF;

  IF v_current.serial_number_tracking AND NOT v_serial
     AND EXISTS (SELECT 1 FROM public.inventory_serials WHERE status = 'in_stock') THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Cannot disable serials while serialized stock exists';
  END IF;

  UPDATE public.business_capabilities
  SET
    credit_sales = (p_capabilities->>'credit_sales')::boolean,
    electronic_invoicing = (p_capabilities->>'electronic_invoicing')::boolean,
    purchase_management = (p_capabilities->>'purchase_management')::boolean,
    variants = (p_capabilities->>'variants')::boolean,
    lot_tracking = v_lot,
    expiry_tracking = v_expiry,
    serial_number_tracking = v_serial,
    services = (p_capabilities->>'services')::boolean,
    revision = revision + 1,
    updated_at = clock_timestamp()
  WHERE organization_id = v_organization_id;

  RETURN public.get_business_profile_v1();
END;
$$;

CREATE OR REPLACE FUNCTION public._business_services_enabled()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE((
    SELECT b.services
    FROM public.business_capabilities AS b
    WHERE b.organization_id = private.current_organization_id()
  ), false)
$$;

CREATE OR REPLACE FUNCTION public._business_variants_enabled()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE((
    SELECT b.variants
    FROM public.business_capabilities AS b
    WHERE b.organization_id = private.current_organization_id()
  ), false)
$$;

CREATE OR REPLACE FUNCTION public._business_enforce_purchase_capability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_enabled boolean;
BEGIN
  SELECT b.purchase_management
  INTO v_enabled
  FROM public.business_capabilities AS b
  WHERE b.organization_id = v_organization_id
  FOR SHARE;

  IF COALESCE(v_enabled, false) IS NOT TRUE THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Purchase management is disabled';
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public._business_enforce_new_sale_capabilities()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_cap public.business_capabilities%ROWTYPE;
BEGIN
  SELECT *
  INTO v_cap
  FROM public.business_capabilities
  WHERE organization_id = v_organization_id
  FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = 'Business capabilities not found';
  END IF;

  IF TG_TABLE_NAME = 'ventas' THEN
    IF NOT v_cap.credit_sales AND COALESCE(NEW.saldo, 0) > 0 THEN
      RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Credit sales are disabled';
    END IF;
    IF NOT v_cap.electronic_invoicing
       AND lower(COALESCE(NEW.tipo_comprobante_solicitado, '')) IN ('boleta', 'factura') THEN
      RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Electronic invoicing is disabled';
    END IF;
  ELSIF TG_TABLE_NAME = 'comprobantes_electronicos'
        AND NOT v_cap.electronic_invoicing THEN
    RAISE EXCEPTION USING ERRCODE = '23514', MESSAGE = 'Electronic invoicing is disabled';
  END IF;

  RETURN NEW;
END;
$$;

-- Logos de empresa: escritura limitada al prefijo UUID del tenant autenticado.
DROP POLICY IF EXISTS logos_admin_delete ON storage.objects;
DROP POLICY IF EXISTS logos_admin_insert ON storage.objects;
DROP POLICY IF EXISTS logos_admin_update ON storage.objects;

CREATE POLICY logos_tenant_admin_delete
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'logos'
  AND private.has_permission('tenant.admin')
  AND split_part(name, '/', 1) = private.current_organization_id()::text
);

CREATE POLICY logos_tenant_admin_insert
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'logos'
  AND private.has_permission('tenant.admin')
  AND split_part(name, '/', 1) = private.current_organization_id()::text
);

CREATE POLICY logos_tenant_admin_update
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'logos'
  AND private.has_permission('tenant.admin')
  AND split_part(name, '/', 1) = private.current_organization_id()::text
)
WITH CHECK (
  bucket_id = 'logos'
  AND private.has_permission('tenant.admin')
  AND split_part(name, '/', 1) = private.current_organization_id()::text
);

REVOKE ALL ON FUNCTION public.get_current_business_configuration_v1()
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.actualizar_configuracion_negocio_v1(jsonb)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_business_profile_v1()
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.update_business_capabilities_v1(bigint, jsonb)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.get_current_business_configuration_v1()
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.actualizar_configuracion_negocio_v1(jsonb)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_business_profile_v1()
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_business_capabilities_v1(bigint, jsonb)
  TO authenticated;

REVOKE ALL ON FUNCTION public._business_services_enabled()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._business_variants_enabled()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._business_enforce_purchase_capability()
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._business_enforce_new_sale_capabilities()
  FROM PUBLIC, anon, authenticated;

COMMIT;
