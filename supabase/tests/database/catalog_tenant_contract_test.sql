BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(24);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'productos','product_unit_profiles','product_variant_groups',
      'product_variant_members','service_metadata','sale_price_rules',
      'product_traceability_configs'
    ]::text[]) AS t(table_name)
    WHERE NOT EXISTS (
      SELECT 1
      FROM pg_attribute a
      WHERE a.attrelid = format('public.%I', t.table_name)::regclass
        AND a.attname = 'organization_id'
        AND NOT a.attisdropped
        AND a.attnotnull
    )
  ),
  'todas las tablas de catálogo tienen organization_id NOT NULL'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.productos'::regclass
      AND conname='productos_organization_id_fkey'
      AND confrelid='public.organizations'::regclass
  ),
  'productos pertenece a organizations'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.productos'::regclass
      AND conname='productos_organization_id_id_key'
      AND contype='u'
  ),
  'productos expone clave compuesta tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname='public' AND tablename='productos'
      AND indexname='productos_organization_code_key'
      AND indexdef ILIKE '%UNIQUE%'
      AND indexdef ILIKE '%organization_id%'
      AND indexdef ILIKE '%upper(btrim(codigo))%'
  ),
  'codigo/SKU es único por organización'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.productos'::regclass
      AND conname='productos_organization_proveedor_fkey'
      AND confrelid='public.proveedores'::regclass
      AND pg_get_constraintdef(oid,true) ILIKE '%FOREIGN KEY (organization_id, proveedor_id)%'
      AND pg_get_constraintdef(oid,true) ILIKE '%REFERENCES proveedores(organization_id, id)%'
  ),
  'producto solo puede referenciar proveedor del mismo tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.product_unit_profiles'::regclass
      AND conname='product_unit_profiles_organization_product_fkey'
      AND confrelid='public.productos'::regclass
  ),
  'presentaciones quedan ligadas al producto del mismo tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.product_traceability_configs'::regclass
      AND conname='product_traceability_configs_organization_product_fkey'
      AND confrelid='public.productos'::regclass
  ),
  'trazabilidad queda ligada al producto del mismo tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.service_metadata'::regclass
      AND conname='service_metadata_organization_product_fkey'
      AND confrelid='public.productos'::regclass
  ),
  'metadata de servicio queda ligada al producto del mismo tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.sale_price_rules'::regclass
      AND conname='sale_price_rules_organization_product_fkey'
      AND confrelid='public.productos'::regclass
  ),
  'reglas de precio quedan ligadas al producto del mismo tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.product_variant_members'::regclass
      AND conname='product_variant_members_organization_group_fkey'
      AND confrelid='public.product_variant_groups'::regclass
  )
  AND EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.product_variant_members'::regclass
      AND conname='product_variant_members_organization_product_fkey'
      AND confrelid='public.productos'::regclass
  ),
  'miembro de variante no puede cruzar grupo/producto entre tenants'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.product_variant_members'::regclass
      AND conname='product_variant_members_organization_product_key'
      AND contype='u'
  ),
  'un producto solo pertenece a un grupo de variantes dentro de su tenant'
);

SELECT ok(
  NOT EXISTS (
    SELECT 1
    FROM unnest(ARRAY[
      'productos','product_unit_profiles','product_variant_groups',
      'product_variant_members','service_metadata','sale_price_rules',
      'product_traceability_configs'
    ]::text[]) AS t(table_name)
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_trigger
      WHERE tgrelid = format('public.%I', t.table_name)::regclass
        AND tgname = t.table_name || '_enforce_organization_id'
        AND NOT tgisinternal
    )
  ),
  'todas las tablas de catálogo fijan/inmutabilizan tenant por trigger'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='productos'
      AND policyname='productos_tenant_select'
      AND cmd='SELECT'
      AND lower(qual) LIKE '%row_belongs_to_current_organization(organization_id)%'
  ),
  'productos SELECT está aislado por tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='productos'
      AND policyname='productos_tenant_update'
      AND cmd='UPDATE'
      AND lower(qual) LIKE '%tenant.admin%'
      AND lower(with_check) LIKE '%tenant.admin%'
      AND lower(qual) LIKE '%row_belongs_to_current_organization%'
      AND lower(with_check) LIKE '%row_belongs_to_current_organization%'
  ),
  'productos UPDATE usa USING + WITH CHECK tenant-aware'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='product_unit_profiles'
      AND policyname='product_unit_profiles_tenant_select'
      AND lower(qual) LIKE '%tenant.read%'
      AND lower(qual) LIKE '%row_belongs_to_current_organization%'
  ),
  'presentaciones SELECT están aisladas por tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='product_variant_groups'
      AND policyname='product_variant_groups_tenant_select'
      AND lower(qual) LIKE '%tenant.read%'
      AND lower(qual) LIKE '%row_belongs_to_current_organization%'
  ),
  'grupos de variantes SELECT están aislados por tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='sale_price_rules'
      AND policyname='sale_price_rules_tenant_select'
      AND lower(qual) LIKE '%tenant.read%'
      AND lower(qual) LIKE '%row_belongs_to_current_organization%'
  ),
  'reglas de precio SELECT están aisladas por tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='get_my_tenant_context_v1'
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
      AND NOT has_function_privilege('anon', p.oid, 'EXECUTE')
  ),
  'get_my_tenant_context_v1 solo se expone a authenticated'
);

SELECT ok(
  position('assert_product_in_current_organization' IN pg_get_functiondef(
    'public.save_product_unit_profile_v6(bigint,bigint,jsonb)'::regprocedure
  )) > 0,
  'save_product_unit_profile_v6 valida producto tenant antes de delegar'
);

SELECT ok(
  position('assert_product_in_current_organization' IN pg_get_functiondef(
    'public.save_product_traceability_config_v1(bigint,bigint,text,boolean)'::regprocedure
  )) > 0,
  'save_product_traceability_config_v1 valida producto tenant'
);

SELECT ok(
  position('assert_product_in_current_organization' IN pg_get_functiondef(
    'public.save_sale_price_rule_v1(bigint,text,bigint,text,numeric,numeric,numeric,integer,timestamptz,timestamptz,boolean)'::regprocedure
  )) > 0,
  'save_sale_price_rule_v1 valida producto tenant'
);

SELECT ok(
  position('assert_variant_group_in_current_organization' IN pg_get_functiondef(
    'public.save_product_variant_group_v1(bigint,text,jsonb,jsonb)'::regprocedure
  )) > 0
  AND position('organization_id' IN pg_get_functiondef(
    'public.save_product_variant_group_v1(bigint,text,jsonb,jsonb)'::regprocedure
  )) > 0,
  'save_product_variant_group_v1 valida grupo y productos del tenant'
);

SELECT ok(
  NOT has_function_privilege('authenticated', 'public.save_product_unit_profile_v1(bigint,bigint,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.save_product_unit_profile_v2(bigint,bigint,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.save_product_unit_profile_v3(bigint,bigint,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.save_product_unit_profile_v4(bigint,bigint,jsonb)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public.save_product_unit_profile_v5(bigint,bigint,jsonb)', 'EXECUTE'),
  'versiones antiguas de save_product_unit_profile quedan fuera del Data API'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='productos_imagenes_tenant_insert'
      AND lower(with_check) LIKE '%imagenes_productos%'
      AND lower(with_check) LIKE '%current_organization_id%'
  )
  AND EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
      AND policyname='productos_imagenes_tenant_delete'
      AND lower(qual) LIKE '%imagenes_productos%'
      AND lower(qual) LIKE '%current_organization_id%'
  ),
  'imagenes_productos usa namespace de organization_id en Storage'
);

SELECT * FROM finish();
ROLLBACK;
