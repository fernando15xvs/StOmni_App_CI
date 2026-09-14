-- Fase 5.1: corregir semántica DELETE y cubrir reactivaciones de branch/warehouse.
BEGIN;

DROP TRIGGER IF EXISTS zz_branches_capability_guard ON public.branches;
CREATE OR REPLACE FUNCTION private.enforce_branch_capability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path=''
AS $$
DECLARE
  v_enabled boolean;
  v_count integer;
BEGIN
  -- Sólo importa cuando la fila nueva quedará activa.
  IF NEW.status<>'active' THEN RETURN NEW; END IF;
  SELECT b.multiple_branches INTO v_enabled
  FROM public.business_capabilities b
  WHERE b.organization_id=NEW.organization_id;
  IF COALESCE(v_enabled,true) THEN RETURN NEW; END IF;

  SELECT count(*)::integer INTO v_count
  FROM public.branches x
  WHERE x.organization_id=NEW.organization_id
    AND x.status='active'
    AND (TG_OP='INSERT' OR x.id<>NEW.id);
  IF v_count>=1 THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Multiple branches capability is disabled';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER zz_branches_capability_guard
BEFORE INSERT OR UPDATE OF status ON public.branches
FOR EACH ROW EXECUTE FUNCTION private.enforce_branch_capability();

DROP TRIGGER IF EXISTS zz_almacenes_capability_guard ON public.almacenes;
CREATE OR REPLACE FUNCTION private.enforce_warehouse_capability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path=''
AS $$
DECLARE
  v_inventory boolean;
  v_multiple boolean;
  v_count integer;
BEGIN
  -- Un almacén inactivo puede permanecer como historial aunque inventario se desactive.
  IF COALESCE(NEW.activo,true) IS FALSE THEN RETURN NEW; END IF;
  SELECT b.inventory_enabled,b.multiple_warehouses
  INTO v_inventory,v_multiple
  FROM public.business_capabilities b
  WHERE b.organization_id=NEW.organization_id;
  IF COALESCE(v_inventory,true) IS FALSE THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Inventory capability is disabled';
  END IF;
  IF COALESCE(v_multiple,true) THEN RETURN NEW; END IF;

  SELECT count(*)::integer INTO v_count
  FROM public.almacenes a
  WHERE a.organization_id=NEW.organization_id
    AND COALESCE(a.activo,true)
    AND (TG_OP='INSERT' OR a.id<>NEW.id);
  IF v_count>=1 THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Multiple warehouses capability is disabled';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER zz_almacenes_capability_guard
BEFORE INSERT OR UPDATE OF activo ON public.almacenes
FOR EACH ROW EXECUTE FUNCTION private.enforce_warehouse_capability();

CREATE OR REPLACE FUNCTION private.enforce_inventory_balance_capability()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path=''
AS $$
BEGIN
  PERFORM private.require_inventory_capability();
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

COMMIT;
