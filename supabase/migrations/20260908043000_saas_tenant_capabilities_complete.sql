-- Fase 5.1 SaaS: capacidades completas por empresa y enforcement backend.
BEGIN;

ALTER TABLE public.business_capabilities
  ADD COLUMN inventory_enabled boolean NOT NULL DEFAULT true,
  ADD COLUMN multiple_branches boolean NOT NULL DEFAULT true,
  ADD COLUMN multiple_warehouses boolean NOT NULL DEFAULT true;

ALTER TABLE public.business_capabilities
  ADD CONSTRAINT business_capabilities_inventory_dependencies CHECK (
    inventory_enabled
    OR (
      NOT purchase_management
      AND NOT lot_tracking
      AND NOT expiry_tracking
      AND NOT serial_number_tracking
      AND NOT multiple_warehouses
    )
  ),
  ADD CONSTRAINT business_capabilities_expiry_requires_lots_v2 CHECK (
    NOT expiry_tracking OR lot_tracking
  );

CREATE OR REPLACE FUNCTION private.current_business_capability(p_capability text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=private.current_organization_id();
  v_result boolean;
BEGIN
  IF v_org IS NULL THEN RETURN false; END IF;
  SELECT CASE p_capability
    WHEN 'inventory_enabled' THEN b.inventory_enabled
    WHEN 'multiple_branches' THEN b.multiple_branches
    WHEN 'multiple_warehouses' THEN b.multiple_warehouses
    WHEN 'credit_sales' THEN b.credit_sales
    WHEN 'electronic_invoicing' THEN b.electronic_invoicing
    WHEN 'purchase_management' THEN b.purchase_management
    WHEN 'variants' THEN b.variants
    WHEN 'services' THEN b.services
    WHEN 'lot_tracking' THEN b.lot_tracking
    WHEN 'expiry_tracking' THEN b.expiry_tracking
    WHEN 'serial_number_tracking' THEN b.serial_number_tracking
    ELSE false
  END INTO v_result
  FROM public.business_capabilities b
  WHERE b.organization_id=v_org;
  RETURN COALESCE(v_result,false);
END;
$$;
REVOKE ALL ON FUNCTION private.current_business_capability(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.current_business_capability(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_business_profile_v1()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_result jsonb;
BEGIN
  IF NOT private.has_permission('tenant.read') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Business profile read permission required';
  END IF;
  SELECT jsonb_build_object(
    'organization_id',v_org,
    'business_id',c.id::text,
    'display_name',COALESCE(NULLIF(c.nombre_comercial,''),c.razon_social,''),
    'revision',b.revision,
    'supports_capability_settings',true,
    'capabilities',jsonb_build_object(
      'inventory_enabled',b.inventory_enabled,
      'multiple_branches',b.multiple_branches,
      'multiple_warehouses',b.multiple_warehouses,
      'credit_sales',b.credit_sales,
      'electronic_invoicing',b.electronic_invoicing,
      'supplier_management',true,
      'purchase_management',b.purchase_management,
      'lot_tracking',b.lot_tracking,
      'expiry_tracking',b.expiry_tracking,
      'variants',b.variants,
      'services',b.services,
      'serial_number_tracking',b.serial_number_tracking
    )
  ) INTO v_result
  FROM public.configuracion_negocio c
  JOIN public.business_capabilities b
    ON b.organization_id=c.organization_id AND b.business_id=c.id
  WHERE c.organization_id=v_org;
  IF v_result IS NULL THEN
    RAISE EXCEPTION USING ERRCODE='P0002', MESSAGE='Business profile not configured for current organization';
  END IF;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_business_capabilities_v1(
  p_expected_revision bigint,p_capabilities jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=''
AS $$
DECLARE
  v_org uuid:=private.require_current_organization_id();
  v_current public.business_capabilities%ROWTYPE;
  v_inventory boolean;
  v_multi_branches boolean;
  v_multi_warehouses boolean;
  v_credit boolean;
  v_electronic boolean;
  v_purchase boolean;
  v_variants boolean;
  v_services boolean;
  v_lot boolean;
  v_expiry boolean;
  v_serial boolean;
  v_allowed constant text[]:=ARRAY[
    'inventory_enabled','multiple_branches','multiple_warehouses',
    'credit_sales','electronic_invoicing','supplier_management','purchase_management',
    'lot_tracking','expiry_tracking','variants','services','serial_number_tracking'
  ];
  v_key text;
BEGIN
  IF NOT private.has_permission('tenant.admin') THEN
    RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Tenant administrator permission required';
  END IF;
  IF p_capabilities IS NULL OR jsonb_typeof(p_capabilities)<>'object' THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Unsupported capabilities payload';
  END IF;
  FOR v_key IN SELECT jsonb_object_keys(p_capabilities) LOOP
    IF NOT (v_key=ANY(v_allowed)) THEN
      RAISE EXCEPTION 'Unknown capability: %',v_key USING ERRCODE='22023';
    END IF;
    IF v_key<>'supplier_management' AND jsonb_typeof(p_capabilities->v_key)<>'boolean' THEN
      RAISE EXCEPTION 'Capability % must be boolean',v_key USING ERRCODE='22023';
    END IF;
  END LOOP;
  IF p_capabilities ? 'supplier_management'
     AND (jsonb_typeof(p_capabilities->'supplier_management')<>'boolean'
          OR (p_capabilities->>'supplier_management')::boolean IS NOT TRUE) THEN
    RAISE EXCEPTION USING ERRCODE='22023', MESSAGE='Supplier management is mandatory in the current domain contract';
  END IF;

  SELECT * INTO v_current
  FROM public.business_capabilities
  WHERE organization_id=v_org
  FOR UPDATE;
  IF NOT FOUND OR p_expected_revision IS NULL OR p_expected_revision<>v_current.revision THEN
    RAISE EXCEPTION USING ERRCODE='40001', MESSAGE='Business configuration changed; reload before saving';
  END IF;

  v_inventory:=COALESCE((p_capabilities->>'inventory_enabled')::boolean,v_current.inventory_enabled);
  v_multi_branches:=COALESCE((p_capabilities->>'multiple_branches')::boolean,v_current.multiple_branches);
  v_multi_warehouses:=COALESCE((p_capabilities->>'multiple_warehouses')::boolean,v_current.multiple_warehouses);
  v_credit:=COALESCE((p_capabilities->>'credit_sales')::boolean,v_current.credit_sales);
  v_electronic:=COALESCE((p_capabilities->>'electronic_invoicing')::boolean,v_current.electronic_invoicing);
  v_purchase:=COALESCE((p_capabilities->>'purchase_management')::boolean,v_current.purchase_management);
  v_variants:=COALESCE((p_capabilities->>'variants')::boolean,v_current.variants);
  v_services:=COALESCE((p_capabilities->>'services')::boolean,v_current.services);
  v_lot:=COALESCE((p_capabilities->>'lot_tracking')::boolean,v_current.lot_tracking);
  v_expiry:=COALESCE((p_capabilities->>'expiry_tracking')::boolean,v_current.expiry_tracking);
  v_serial:=COALESCE((p_capabilities->>'serial_number_tracking')::boolean,v_current.serial_number_tracking);

  IF v_expiry AND NOT v_lot THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Expiry tracking requires lot tracking';
  END IF;
  IF NOT v_inventory AND (v_purchase OR v_lot OR v_expiry OR v_serial OR v_multi_warehouses) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Inventory-dependent capabilities must be disabled before inventory';
  END IF;

  IF v_current.multiple_branches AND NOT v_multi_branches AND (
    SELECT count(*) FROM public.branches b WHERE b.organization_id=v_org AND b.status='active'
  )>1 THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Cannot disable multiple branches while multiple active branches exist';
  END IF;

  IF v_current.multiple_warehouses AND NOT v_multi_warehouses AND (
    SELECT count(*) FROM public.almacenes a WHERE a.organization_id=v_org AND COALESCE(a.activo,true)
  )>1 THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Cannot disable multiple warehouses while multiple active warehouses exist';
  END IF;

  IF v_current.inventory_enabled AND NOT v_inventory AND (
    EXISTS(SELECT 1 FROM public.inventario_almacen ia WHERE ia.organization_id=v_org AND COALESCE(ia.cantidad,0)<>0)
    OR EXISTS(SELECT 1 FROM public.inventory_lots l WHERE l.organization_id=v_org AND l.base_quantity>0)
    OR EXISTS(SELECT 1 FROM public.inventory_serials s WHERE s.organization_id=v_org AND s.status='in_stock')
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Cannot disable inventory while stock exists';
  END IF;

  IF v_current.lot_tracking AND NOT v_lot
     AND EXISTS(SELECT 1 FROM public.inventory_lots l WHERE l.organization_id=v_org AND l.base_quantity>0) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Cannot disable lots while lot stock exists';
  END IF;
  IF v_current.serial_number_tracking AND NOT v_serial
     AND EXISTS(SELECT 1 FROM public.inventory_serials s WHERE s.organization_id=v_org AND s.status='in_stock') THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Cannot disable serials while serialized stock exists';
  END IF;

  UPDATE public.business_capabilities SET
    inventory_enabled=v_inventory,
    multiple_branches=v_multi_branches,
    multiple_warehouses=v_multi_warehouses,
    credit_sales=v_credit,
    electronic_invoicing=v_electronic,
    purchase_management=v_purchase,
    variants=v_variants,
    services=v_services,
    lot_tracking=v_lot,
    expiry_tracking=v_expiry,
    serial_number_tracking=v_serial,
    revision=revision+1,
    updated_at=clock_timestamp()
  WHERE organization_id=v_org;

  RETURN public.get_business_profile_v1();
END;
$$;

-- Backend enforcement para altas nuevas. Los tenants existentes se preservan
-- por defaults true y los cambios se validan antes de actualizar capabilities.
CREATE OR REPLACE FUNCTION private.enforce_branch_capability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path=''
AS $$
DECLARE v_enabled boolean; v_count integer;
BEGIN
  SELECT b.multiple_branches INTO v_enabled
  FROM public.business_capabilities b WHERE b.organization_id=NEW.organization_id;
  SELECT count(*)::integer INTO v_count
  FROM public.branches x WHERE x.organization_id=NEW.organization_id AND x.status='active';
  IF COALESCE(v_enabled,true) IS FALSE AND v_count>=1 THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Multiple branches capability is disabled';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.enforce_branch_capability() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zz_branches_capability_guard
BEFORE INSERT ON public.branches
FOR EACH ROW EXECUTE FUNCTION private.enforce_branch_capability();

CREATE OR REPLACE FUNCTION private.enforce_warehouse_capability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path=''
AS $$
DECLARE v_inventory boolean; v_multiple boolean; v_count integer;
BEGIN
  SELECT b.inventory_enabled,b.multiple_warehouses INTO v_inventory,v_multiple
  FROM public.business_capabilities b WHERE b.organization_id=NEW.organization_id;
  IF COALESCE(v_inventory,true) IS FALSE THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Inventory capability is disabled';
  END IF;
  SELECT count(*)::integer INTO v_count
  FROM public.almacenes a WHERE a.organization_id=NEW.organization_id AND COALESCE(a.activo,true);
  IF COALESCE(v_multiple,true) IS FALSE AND v_count>=1 THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Multiple warehouses capability is disabled';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.enforce_warehouse_capability() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zz_almacenes_capability_guard
BEFORE INSERT ON public.almacenes
FOR EACH ROW EXECUTE FUNCTION private.enforce_warehouse_capability();

-- Inventory writes are blocked centrally even if an old client still renders UI.
CREATE OR REPLACE FUNCTION private.require_inventory_capability()
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path=''
AS $$
BEGIN
  IF private.current_business_capability('inventory_enabled') IS NOT TRUE THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Inventory capability is disabled';
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION private.require_inventory_capability() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.require_inventory_capability() TO authenticated;

-- Trigger sobre saldos como defensa en profundidad para cualquier mutación que
-- no pase por los RPC de inventario actuales.
CREATE OR REPLACE FUNCTION private.enforce_inventory_balance_capability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path=''
AS $$
BEGIN
  PERFORM private.require_inventory_capability();
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION private.enforce_inventory_balance_capability() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zz_inventario_almacen_capability_guard
BEFORE INSERT OR UPDATE OR DELETE ON public.inventario_almacen
FOR EACH ROW EXECUTE FUNCTION private.enforce_inventory_balance_capability();

REVOKE ALL ON FUNCTION public.get_business_profile_v1() FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.update_business_capabilities_v1(bigint,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_business_profile_v1() TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_business_capabilities_v1(bigint,jsonb) TO authenticated;

COMMIT;
