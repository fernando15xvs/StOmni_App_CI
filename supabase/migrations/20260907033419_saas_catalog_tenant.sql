-- Fase 3.3 SaaS (fundación): catálogo y tablas auxiliares por organización.
-- Los RPC que mezclan catálogo + inventario se terminan en F3.4.
BEGIN;

ALTER TABLE public.productos ADD COLUMN organization_id uuid;
ALTER TABLE public.product_unit_profiles ADD COLUMN organization_id uuid;
ALTER TABLE public.product_variant_groups ADD COLUMN organization_id uuid;
ALTER TABLE public.product_variant_members ADD COLUMN organization_id uuid;
ALTER TABLE public.service_metadata ADD COLUMN organization_id uuid;
ALTER TABLE public.sale_price_rules ADD COLUMN organization_id uuid;
ALTER TABLE public.product_traceability_configs ADD COLUMN organization_id uuid;

ALTER TABLE public.productos
  ADD CONSTRAINT productos_organization_id_fkey
    FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT productos_organization_id_id_key UNIQUE (organization_id, id);

ALTER TABLE public.product_unit_profiles
  ADD CONSTRAINT product_unit_profiles_organization_id_fkey
    FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;
ALTER TABLE public.product_variant_groups
  ADD CONSTRAINT product_variant_groups_organization_id_fkey
    FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT product_variant_groups_organization_id_id_key UNIQUE (organization_id, id);
ALTER TABLE public.product_variant_members
  ADD CONSTRAINT product_variant_members_organization_id_fkey
    FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;
ALTER TABLE public.service_metadata
  ADD CONSTRAINT service_metadata_organization_id_fkey
    FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;
ALTER TABLE public.sale_price_rules
  ADD CONSTRAINT sale_price_rules_organization_id_fkey
    FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT sale_price_rules_organization_id_id_key UNIQUE (organization_id, id);
ALTER TABLE public.product_traceability_configs
  ADD CONSTRAINT product_traceability_configs_organization_id_fkey
    FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;

COMMENT ON COLUMN public.productos.organization_id IS 'Tenant propietario del producto/servicio.';
COMMENT ON COLUMN public.product_unit_profiles.organization_id IS 'Tenant propietario de la presentación comercial.';
COMMENT ON COLUMN public.product_variant_groups.organization_id IS 'Tenant propietario del grupo de variantes.';
COMMENT ON COLUMN public.product_variant_members.organization_id IS 'Tenant propietario de la membresía de variante.';
COMMENT ON COLUMN public.service_metadata.organization_id IS 'Tenant propietario de la metadata del servicio.';
COMMENT ON COLUMN public.sale_price_rules.organization_id IS 'Tenant propietario de la regla de precio.';
COMMENT ON COLUMN public.product_traceability_configs.organization_id IS 'Tenant propietario de la configuración de trazabilidad.';

DO $backfill$
DECLARE
  v_needs_backfill boolean;
  v_organization_count integer;
  v_organization_id uuid;
BEGIN
  SELECT
    EXISTS (SELECT 1 FROM public.productos WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.product_unit_profiles WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.product_variant_groups WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.product_variant_members WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.service_metadata WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.sale_price_rules WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.product_traceability_configs WHERE organization_id IS NULL)
  INTO v_needs_backfill;

  IF v_needs_backfill THEN
    SELECT count(DISTINCT organization_id)::integer
    INTO v_organization_count
    FROM public.configuracion_negocio;

    IF v_organization_count <> 1 THEN
      RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = 'Ambiguous legacy state: unscoped catalog requires exactly one business organization';
    END IF;

    SELECT organization_id
    INTO v_organization_id
    FROM public.configuracion_negocio
    ORDER BY id
    LIMIT 1;

    UPDATE public.productos
    SET organization_id = v_organization_id
    WHERE organization_id IS NULL;

    UPDATE public.product_variant_groups
    SET organization_id = v_organization_id
    WHERE organization_id IS NULL;

    UPDATE public.product_unit_profiles AS x
    SET organization_id = p.organization_id
    FROM public.productos AS p
    WHERE x.product_id = p.id
      AND x.organization_id IS NULL;

    UPDATE public.product_traceability_configs AS x
    SET organization_id = p.organization_id
    FROM public.productos AS p
    WHERE x.product_id = p.id
      AND x.organization_id IS NULL;

    UPDATE public.service_metadata AS x
    SET organization_id = p.organization_id
    FROM public.productos AS p
    WHERE x.product_id = p.id
      AND x.organization_id IS NULL;

    UPDATE public.sale_price_rules AS x
    SET organization_id = p.organization_id
    FROM public.productos AS p
    WHERE x.product_id = p.id
      AND x.organization_id IS NULL;

    UPDATE public.product_variant_members AS x
    SET organization_id = g.organization_id
    FROM public.product_variant_groups AS g
    WHERE x.group_id = g.id
      AND x.organization_id IS NULL;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.productos AS p
    JOIN public.proveedores AS s ON s.id = p.proveedor_id
    WHERE p.proveedor_id IS NOT NULL
      AND p.organization_id IS DISTINCT FROM s.organization_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23503',
      MESSAGE = 'Cross-tenant product/provider relationship exists before catalog enforcement';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.product_variant_members AS m
    JOIN public.product_variant_groups AS g ON g.id = m.group_id
    JOIN public.productos AS p ON p.id = m.product_id
    WHERE m.organization_id IS DISTINCT FROM g.organization_id
       OR m.organization_id IS DISTINCT FROM p.organization_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23503',
      MESSAGE = 'Cross-tenant variant membership exists before catalog enforcement';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.productos
    WHERE NULLIF(btrim(codigo), '') IS NOT NULL
    GROUP BY organization_id, upper(btrim(codigo))
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23505',
      MESSAGE = 'Duplicate product code exists inside one organization';
  END IF;

  IF EXISTS (SELECT 1 FROM public.productos WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.product_unit_profiles WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.product_variant_groups WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.product_variant_members WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.service_metadata WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.sale_price_rules WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.product_traceability_configs WHERE organization_id IS NULL) THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = 'Unscoped catalog rows remain after tenant backfill';
  END IF;
END;
$backfill$;

ALTER TABLE public.productos ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.product_unit_profiles ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.product_variant_groups ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.product_variant_members ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.service_metadata ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.sale_price_rules ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.product_traceability_configs ALTER COLUMN organization_id SET NOT NULL;

CREATE INDEX productos_organization_id_idx ON public.productos (organization_id);
CREATE UNIQUE INDEX productos_organization_code_key
  ON public.productos (organization_id, upper(btrim(codigo)))
  WHERE NULLIF(btrim(codigo), '') IS NOT NULL;
CREATE INDEX product_unit_profiles_organization_id_idx ON public.product_unit_profiles (organization_id);
CREATE INDEX product_variant_groups_organization_id_idx ON public.product_variant_groups (organization_id);
CREATE INDEX product_variant_members_organization_id_idx ON public.product_variant_members (organization_id);
CREATE INDEX service_metadata_organization_id_idx ON public.service_metadata (organization_id);
CREATE INDEX sale_price_rules_organization_id_idx ON public.sale_price_rules (organization_id);
CREATE INDEX product_traceability_configs_organization_id_idx ON public.product_traceability_configs (organization_id);

-- Toda relación de catálogo se vuelve tenant-qualified.
ALTER TABLE public.productos DROP CONSTRAINT IF EXISTS productos_proveedor_id_fkey;
ALTER TABLE public.productos
  ADD CONSTRAINT productos_organization_proveedor_fkey
    FOREIGN KEY (organization_id, proveedor_id)
    REFERENCES public.proveedores(organization_id, id)
    ON DELETE SET NULL (proveedor_id);

ALTER TABLE public.product_unit_profiles DROP CONSTRAINT IF EXISTS product_unit_profiles_product_id_fkey;
ALTER TABLE public.product_unit_profiles
  ADD CONSTRAINT product_unit_profiles_organization_product_fkey
    FOREIGN KEY (organization_id, product_id)
    REFERENCES public.productos(organization_id, id)
    ON DELETE CASCADE;

ALTER TABLE public.product_traceability_configs DROP CONSTRAINT IF EXISTS product_traceability_configs_product_id_fkey;
ALTER TABLE public.product_traceability_configs
  ADD CONSTRAINT product_traceability_configs_organization_product_fkey
    FOREIGN KEY (organization_id, product_id)
    REFERENCES public.productos(organization_id, id)
    ON DELETE CASCADE;

ALTER TABLE public.service_metadata DROP CONSTRAINT IF EXISTS service_metadata_product_id_fkey;
ALTER TABLE public.service_metadata
  ADD CONSTRAINT service_metadata_organization_product_fkey
    FOREIGN KEY (organization_id, product_id)
    REFERENCES public.productos(organization_id, id)
    ON DELETE CASCADE;

ALTER TABLE public.sale_price_rules DROP CONSTRAINT IF EXISTS sale_price_rules_product_id_fkey;
ALTER TABLE public.sale_price_rules
  ADD CONSTRAINT sale_price_rules_organization_product_fkey
    FOREIGN KEY (organization_id, product_id)
    REFERENCES public.productos(organization_id, id)
    ON DELETE CASCADE;

ALTER TABLE public.product_variant_members
  DROP CONSTRAINT IF EXISTS product_variant_members_group_id_fkey,
  DROP CONSTRAINT IF EXISTS product_variant_members_product_id_fkey,
  DROP CONSTRAINT IF EXISTS product_variant_members_product_id_key;

ALTER TABLE public.product_variant_members
  ADD CONSTRAINT product_variant_members_organization_group_fkey
    FOREIGN KEY (organization_id, group_id)
    REFERENCES public.product_variant_groups(organization_id, id)
    ON DELETE CASCADE,
  ADD CONSTRAINT product_variant_members_organization_product_fkey
    FOREIGN KEY (organization_id, product_id)
    REFERENCES public.productos(organization_id, id),
  ADD CONSTRAINT product_variant_members_organization_product_key
    UNIQUE (organization_id, product_id);

-- El mismo trigger de F3.2 mantiene organization_id server-side e inmutable.
CREATE TRIGGER productos_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.productos
FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER product_unit_profiles_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.product_unit_profiles
FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER product_variant_groups_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.product_variant_groups
FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER product_variant_members_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.product_variant_members
FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER service_metadata_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.service_metadata
FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER sale_price_rules_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.sale_price_rules
FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER product_traceability_configs_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.product_traceability_configs
FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();

ALTER TABLE public.productos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_unit_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_variant_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_variant_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_metadata ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_price_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_traceability_configs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS productos_admin_insert ON public.productos;
DROP POLICY IF EXISTS productos_admin_update ON public.productos;
DROP POLICY IF EXISTS productos_select ON public.productos;
DROP POLICY IF EXISTS product_unit_profiles_read_active ON public.product_unit_profiles;
DROP POLICY IF EXISTS product_traceability_configs_read ON public.product_traceability_configs;
DROP POLICY IF EXISTS sale_price_rules_read ON public.sale_price_rules;

CREATE POLICY productos_tenant_select ON public.productos
FOR SELECT TO authenticated
USING (
  private.row_belongs_to_current_organization(organization_id)
  AND (
    private.has_permission('tenant.admin')
    OR (private.has_permission('tenant.read') AND COALESCE(activo, true))
  )
);
CREATE POLICY productos_tenant_insert ON public.productos
FOR INSERT TO authenticated
WITH CHECK (
  private.has_permission('tenant.admin')
  AND private.row_belongs_to_current_organization(organization_id)
);
CREATE POLICY productos_tenant_update ON public.productos
FOR UPDATE TO authenticated
USING (
  private.has_permission('tenant.admin')
  AND private.row_belongs_to_current_organization(organization_id)
)
WITH CHECK (
  private.has_permission('tenant.admin')
  AND private.row_belongs_to_current_organization(organization_id)
);

CREATE POLICY product_unit_profiles_tenant_select ON public.product_unit_profiles
FOR SELECT TO authenticated
USING (
  private.has_permission('tenant.read')
  AND private.row_belongs_to_current_organization(organization_id)
);
CREATE POLICY product_traceability_configs_tenant_select ON public.product_traceability_configs
FOR SELECT TO authenticated
USING (
  private.has_permission('tenant.read')
  AND private.row_belongs_to_current_organization(organization_id)
);
CREATE POLICY sale_price_rules_tenant_select ON public.sale_price_rules
FOR SELECT TO authenticated
USING (
  private.has_permission('tenant.read')
  AND private.row_belongs_to_current_organization(organization_id)
);
CREATE POLICY product_variant_groups_tenant_select ON public.product_variant_groups
FOR SELECT TO authenticated
USING (
  private.has_permission('tenant.read')
  AND private.row_belongs_to_current_organization(organization_id)
);
CREATE POLICY product_variant_members_tenant_select ON public.product_variant_members
FOR SELECT TO authenticated
USING (
  private.has_permission('tenant.read')
  AND private.row_belongs_to_current_organization(organization_id)
);
CREATE POLICY service_metadata_tenant_select ON public.service_metadata
FOR SELECT TO authenticated
USING (
  private.has_permission('tenant.read')
  AND private.row_belongs_to_current_organization(organization_id)
);

REVOKE ALL ON TABLE public.productos FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.product_unit_profiles FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.product_variant_groups FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.product_variant_members FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.service_metadata FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.sale_price_rules FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.product_traceability_configs FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE ON TABLE public.productos TO authenticated;
GRANT SELECT ON TABLE public.product_unit_profiles TO authenticated;
GRANT SELECT ON TABLE public.product_traceability_configs TO authenticated;
GRANT SELECT ON TABLE public.sale_price_rules TO authenticated;

-- Contexto no autoritativo para construir namespaces de cliente. Las policies/RPC
-- siguen validando el UUID real; conocer el UUID propio no concede acceso.
CREATE OR REPLACE FUNCTION public.get_my_tenant_context_v1()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'organization_id', private.require_current_organization_id(),
    'base_role', private.current_base_role()
  )
$$;
REVOKE ALL ON FUNCTION public.get_my_tenant_context_v1() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_tenant_context_v1() TO authenticated;

-- Assertions privadas para wrappers SECURITY DEFINER.
CREATE OR REPLACE FUNCTION private.assert_product_in_current_organization(p_product_id bigint)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_organization_id uuid := private.require_current_organization_id();
BEGIN
  IF p_product_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.productos
    WHERE organization_id = v_organization_id AND id = p_product_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Product not available in current organization';
  END IF;
END;
$$;
CREATE OR REPLACE FUNCTION private.assert_variant_group_in_current_organization(p_group_id bigint)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_organization_id uuid := private.require_current_organization_id();
BEGIN
  IF p_group_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.product_variant_groups
    WHERE organization_id = v_organization_id AND id = p_group_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Variant group not available in current organization';
  END IF;
END;
$$;
CREATE OR REPLACE FUNCTION private.assert_price_rule_in_current_organization(p_rule_id bigint)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_organization_id uuid := private.require_current_organization_id();
BEGIN
  IF p_rule_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.sale_price_rules
    WHERE organization_id = v_organization_id AND id = p_rule_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Price rule not available in current organization';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION private.assert_product_in_current_organization(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.assert_variant_group_in_current_organization(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.assert_price_rule_in_current_organization(bigint) FROM PUBLIC, anon, authenticated;

-- Lecturas de catálogo que antes recorrían todas las empresas.
CREATE OR REPLACE FUNCTION public.get_product_unit_profiles_v1(p_product_ids bigint[])
RETURNS SETOF jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE v_organization_id uuid := private.require_current_organization_id();
BEGIN
  IF NOT private.has_permission('tenant.read') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Catalog read permission required';
  END IF;
  IF p_product_ids IS NULL OR cardinality(p_product_ids) > 1000
     OR EXISTS (SELECT 1 FROM unnest(p_product_ids) id WHERE id IS NULL OR id <= 0) THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Invalid product list';
  END IF;
  RETURN QUERY
    SELECT jsonb_build_object(
      'product_id', profile.product_id,
      'revision', profile.revision,
      'profile', profile.profile
    )
    FROM public.product_unit_profiles AS profile
    WHERE profile.organization_id = v_organization_id
      AND profile.product_id = ANY(p_product_ids)
    ORDER BY profile.product_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_product_traceability_config_v1(p_product_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_config public.product_traceability_configs%ROWTYPE;
BEGIN
  IF NOT private.has_permission('tenant.read') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Catalog read permission required';
  END IF;
  PERFORM private.assert_product_in_current_organization(p_product_id);
  SELECT * INTO v_config
  FROM public.product_traceability_configs
  WHERE organization_id = v_organization_id AND product_id = p_product_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('product_id',p_product_id,'mode','none','expiry_required',false,'revision',0);
  END IF;
  RETURN jsonb_build_object(
    'product_id',v_config.product_id,'mode',v_config.mode,
    'expiry_required',v_config.expiry_required,'revision',v_config.revision
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.list_product_variant_groups_v1()
RETURNS SETOF jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
  v_id bigint;
BEGIN
  IF NOT public.app_tiene_permiso('products.update') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Not authorized to read variants';
  END IF;
  IF NOT public._business_variants_enabled() THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Variants are disabled';
  END IF;
  FOR v_id IN
    SELECT id FROM public.product_variant_groups
    WHERE organization_id = v_organization_id
    ORDER BY name,id
  LOOP
    RETURN NEXT public._product_variant_group_json(v_id);
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_sale_price_rules_v1()
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
  IF NOT public.app_tiene_permiso('products.change_price') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Not authorized to manage prices';
  END IF;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'name',r.name,'product_id',r.product_id,'product_name',p.nombre,
    'presentation_code',r.presentation_code,'min_quantity',r.min_quantity,
    'fixed_price',r.fixed_price,'discount_percent',r.discount_percent,
    'priority',r.priority,'starts_at',r.starts_at,'ends_at',r.ends_at,'active',r.active
  ) ORDER BY r.priority DESC,r.id DESC),'[]'::jsonb)
  INTO v_result
  FROM public.sale_price_rules AS r
  JOIN public.productos AS p
    ON p.organization_id = r.organization_id AND p.id = r.product_id
  WHERE r.organization_id = v_organization_id;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.list_services_v1(p_include_inactive boolean DEFAULT false)
RETURNS SETOF jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT public._service_json_v1(p.id)
  FROM public.productos AS p
  WHERE p.organization_id = private.require_current_organization_id()
    AND private.has_permission('tenant.read')
    AND public._business_services_enabled()
    AND p.es_servicio
    AND (COALESCE(p_include_inactive,false) OR COALESCE(p.activo,true))
  ORDER BY p.nombre,p.id
$$;

-- Wrappers: validan tenant antes de delegar en lógica histórica probada.
ALTER FUNCTION public.save_product_unit_profile_v6(bigint,bigint,jsonb)
  RENAME TO _legacy_save_product_unit_profile_v6;
REVOKE ALL ON FUNCTION public._legacy_save_product_unit_profile_v6(bigint,bigint,jsonb)
  FROM PUBLIC, anon, authenticated;
CREATE FUNCTION public.save_product_unit_profile_v6(
  p_product_id bigint,p_expected_revision bigint,p_profile jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.assert_product_in_current_organization(p_product_id);
  PERFORM public._validate_product_unit_fiscal_codes_v1(p_profile);
  RETURN public._legacy_save_product_unit_profile_v6(p_product_id,p_expected_revision,p_profile);
END;
$$;

ALTER FUNCTION public.save_product_traceability_config_v1(bigint,bigint,text,boolean)
  RENAME TO _legacy_save_product_traceability_config_v1;
REVOKE ALL ON FUNCTION public._legacy_save_product_traceability_config_v1(bigint,bigint,text,boolean)
  FROM PUBLIC, anon, authenticated;
CREATE FUNCTION public.save_product_traceability_config_v1(
  p_product_id bigint,p_expected_revision bigint,p_mode text,p_expiry_required boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.assert_product_in_current_organization(p_product_id);
  RETURN public._legacy_save_product_traceability_config_v1(
    p_product_id,p_expected_revision,p_mode,p_expiry_required
  );
END;
$$;

ALTER FUNCTION public.save_sale_price_rule_v1(bigint,text,bigint,text,numeric,numeric,numeric,integer,timestamptz,timestamptz,boolean)
  RENAME TO _legacy_save_sale_price_rule_v1;
REVOKE ALL ON FUNCTION public._legacy_save_sale_price_rule_v1(bigint,text,bigint,text,numeric,numeric,numeric,integer,timestamptz,timestamptz,boolean)
  FROM PUBLIC, anon, authenticated;
CREATE FUNCTION public.save_sale_price_rule_v1(
  p_id bigint,p_name text,p_product_id bigint,p_presentation_code text,
  p_min_quantity numeric,p_fixed_price numeric,p_discount_percent numeric,
  p_priority integer,p_starts_at timestamptz,p_ends_at timestamptz,p_active boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.assert_product_in_current_organization(p_product_id);
  IF p_id IS NOT NULL THEN
    PERFORM private.assert_price_rule_in_current_organization(p_id);
  END IF;
  RETURN public._legacy_save_sale_price_rule_v1(
    p_id,p_name,p_product_id,p_presentation_code,p_min_quantity,p_fixed_price,
    p_discount_percent,p_priority,p_starts_at,p_ends_at,p_active
  );
END;
$$;

ALTER FUNCTION public.delete_sale_price_rule_v1(bigint)
  RENAME TO _legacy_delete_sale_price_rule_v1;
REVOKE ALL ON FUNCTION public._legacy_delete_sale_price_rule_v1(bigint)
  FROM PUBLIC, anon, authenticated;
CREATE FUNCTION public.delete_sale_price_rule_v1(p_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.assert_price_rule_in_current_organization(p_id);
  PERFORM public._legacy_delete_sale_price_rule_v1(p_id);
END;
$$;

ALTER FUNCTION public.save_product_variant_group_v1(bigint,text,jsonb,jsonb)
  RENAME TO _legacy_save_product_variant_group_v1;
REVOKE ALL ON FUNCTION public._legacy_save_product_variant_group_v1(bigint,text,jsonb,jsonb)
  FROM PUBLIC, anon, authenticated;
CREATE FUNCTION public.save_product_variant_group_v1(
  p_group_id bigint,p_name text,p_attribute_names jsonb,p_members jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_organization_id uuid := private.require_current_organization_id();
BEGIN
  IF p_group_id IS NOT NULL THEN
    PERFORM private.assert_variant_group_in_current_organization(p_group_id);
  END IF;

  IF p_members IS NOT NULL AND jsonb_typeof(p_members) = 'array' AND EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_members) AS member
    LEFT JOIN public.productos AS p
      ON p.id = CASE
        WHEN COALESCE(member->>'product_id','') ~ '^[0-9]+$'
          THEN (member->>'product_id')::bigint
        ELSE NULL
      END
     AND p.organization_id = v_organization_id
    WHERE p.id IS NULL
  ) THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Variant member is outside current organization or invalid';
  END IF;

  RETURN public._legacy_save_product_variant_group_v1(
    p_group_id,p_name,p_attribute_names,p_members
  );
END;
$$;

ALTER FUNCTION public.delete_product_variant_group_v1(bigint)
  RENAME TO _legacy_delete_product_variant_group_v1;
REVOKE ALL ON FUNCTION public._legacy_delete_product_variant_group_v1(bigint)
  FROM PUBLIC, anon, authenticated;
CREATE FUNCTION public.delete_product_variant_group_v1(p_group_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.assert_variant_group_in_current_organization(p_group_id);
  PERFORM public._legacy_delete_product_variant_group_v1(p_group_id);
END;
$$;

ALTER FUNCTION public.deactivate_service_v1(bigint)
  RENAME TO _legacy_deactivate_service_v1;
REVOKE ALL ON FUNCTION public._legacy_deactivate_service_v1(bigint)
  FROM PUBLIC, anon, authenticated;
CREATE FUNCTION public.deactivate_service_v1(p_service_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.assert_product_in_current_organization(p_service_id);
  PERFORM public._legacy_deactivate_service_v1(p_service_id);
END;
$$;

-- Sólo las versiones finales quedan como superficie cliente.
REVOKE ALL ON FUNCTION public.save_product_unit_profile_v1(bigint,bigint,jsonb) FROM authenticated;
REVOKE ALL ON FUNCTION public.save_product_unit_profile_v2(bigint,bigint,jsonb) FROM authenticated;
REVOKE ALL ON FUNCTION public.save_product_unit_profile_v3(bigint,bigint,jsonb) FROM authenticated;
REVOKE ALL ON FUNCTION public.save_product_unit_profile_v4(bigint,bigint,jsonb) FROM authenticated;
REVOKE ALL ON FUNCTION public.save_product_unit_profile_v5(bigint,bigint,jsonb) FROM authenticated;

REVOKE ALL ON FUNCTION public.get_product_unit_profiles_v1(bigint[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_product_traceability_config_v1(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_product_variant_groups_v1() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_sale_price_rules_v1() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.list_services_v1(boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.save_product_unit_profile_v6(bigint,bigint,jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.save_product_traceability_config_v1(bigint,bigint,text,boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.save_sale_price_rule_v1(bigint,text,bigint,text,numeric,numeric,numeric,integer,timestamptz,timestamptz,boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delete_sale_price_rule_v1(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.save_product_variant_group_v1(bigint,text,jsonb,jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.delete_product_variant_group_v1(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.deactivate_service_v1(bigint) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.get_product_unit_profiles_v1(bigint[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_product_traceability_config_v1(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_product_variant_groups_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_sale_price_rules_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_services_v1(boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_product_unit_profile_v6(bigint,bigint,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_product_traceability_config_v1(bigint,bigint,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_sale_price_rule_v1(bigint,text,bigint,text,numeric,numeric,numeric,integer,timestamptz,timestamptz,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_sale_price_rule_v1(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_product_variant_group_v1(bigint,text,jsonb,jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_product_variant_group_v1(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deactivate_service_v1(bigint) TO authenticated;

-- Storage de imágenes: assets públicos por URL, pero listing/escritura namespaceados.
DROP POLICY IF EXISTS productos_imagenes_admin_delete ON storage.objects;
DROP POLICY IF EXISTS productos_imagenes_admin_insert ON storage.objects;
DROP POLICY IF EXISTS productos_imagenes_admin_update ON storage.objects;
DROP POLICY IF EXISTS productos_imagenes_public_select ON storage.objects;

CREATE POLICY productos_imagenes_tenant_select
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'imagenes_productos'
  AND private.has_permission('tenant.read')
  AND split_part(name, '/', 1) = private.current_organization_id()::text
);
CREATE POLICY productos_imagenes_tenant_insert
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'imagenes_productos'
  AND private.has_permission('tenant.admin')
  AND split_part(name, '/', 1) = private.current_organization_id()::text
);
CREATE POLICY productos_imagenes_tenant_update
ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'imagenes_productos'
  AND private.has_permission('tenant.admin')
  AND split_part(name, '/', 1) = private.current_organization_id()::text
)
WITH CHECK (
  bucket_id = 'imagenes_productos'
  AND private.has_permission('tenant.admin')
  AND split_part(name, '/', 1) = private.current_organization_id()::text
);
CREATE POLICY productos_imagenes_tenant_delete
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id = 'imagenes_productos'
  AND private.has_permission('tenant.admin')
  AND split_part(name, '/', 1) = private.current_organization_id()::text
);

COMMIT;
