-- Fase 3.4 SaaS: almacenes, existencias, kardex, trazabilidad e idempotencia por organización.
-- Los wrappers RPC tenant-aware se agregan en la migración siguiente.
BEGIN;

ALTER TABLE public.almacenes ADD COLUMN organization_id uuid;
ALTER TABLE public.inventario_almacen ADD COLUMN organization_id uuid;
ALTER TABLE public.inventario_movimientos ADD COLUMN organization_id uuid;
ALTER TABLE public.inventario_operaciones_idempotentes ADD COLUMN organization_id uuid;
ALTER TABLE public.inventory_lots ADD COLUMN organization_id uuid;
ALTER TABLE public.inventory_serials ADD COLUMN organization_id uuid;
ALTER TABLE public.inventory_traceability_consumptions ADD COLUMN organization_id uuid;
ALTER TABLE public.inventory_traceability_receipts ADD COLUMN organization_id uuid;
ALTER TABLE public.stock_alert_tx_context ADD COLUMN organization_id uuid;
ALTER TABLE public.transferencias_stock ADD COLUMN organization_id uuid;
ALTER TABLE public.sys_processed_requests ADD COLUMN organization_id uuid;

COMMENT ON COLUMN public.almacenes.organization_id IS 'Tenant propietario del almacén.';
COMMENT ON COLUMN public.inventario_almacen.organization_id IS 'Tenant propietario de la existencia por producto/almacén.';
COMMENT ON COLUMN public.inventario_movimientos.organization_id IS 'Tenant propietario del movimiento/kardex.';
COMMENT ON COLUMN public.inventario_operaciones_idempotentes.organization_id IS 'Tenant propietario de la clave idempotente de inventario.';
COMMENT ON COLUMN public.inventory_lots.organization_id IS 'Tenant propietario del lote.';
COMMENT ON COLUMN public.inventory_serials.organization_id IS 'Tenant propietario de la serie.';
COMMENT ON COLUMN public.inventory_traceability_consumptions.organization_id IS 'Tenant propietario del consumo trazable.';
COMMENT ON COLUMN public.inventory_traceability_receipts.organization_id IS 'Tenant propietario de la recepción trazable.';
COMMENT ON COLUMN public.stock_alert_tx_context.organization_id IS 'Tenant propietario del contexto transaccional de alerta de stock.';
COMMENT ON COLUMN public.transferencias_stock.organization_id IS 'Tenant propietario del traslado de stock.';
COMMENT ON COLUMN public.sys_processed_requests.organization_id IS 'Tenant propietario de la solicitud idempotente de alta de producto.';

-- Deriva organization_id de producto/almacén para operaciones internas. Con un
-- usuario autenticado, el tenant canónico siempre se obtiene de app_users.
CREATE OR REPLACE FUNCTION private.enforce_inventory_organization_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_current_organization_id uuid := private.current_organization_id();
  v_derived_organization_id uuid;
  v_candidate_organization_id uuid;
  v_row jsonb := to_jsonb(NEW);
  v_id bigint;
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.organization_id IS DISTINCT FROM OLD.organization_id THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='organization_id is immutable';
  END IF;

  v_id := NULLIF(COALESCE(v_row->>'producto_id', v_row->>'product_id'), '')::bigint;
  IF v_id IS NOT NULL THEN
    SELECT organization_id INTO v_candidate_organization_id
    FROM public.productos WHERE id=v_id;
    IF v_candidate_organization_id IS NOT NULL THEN
      v_derived_organization_id := v_candidate_organization_id;
    END IF;
  END IF;

  v_id := NULLIF(COALESCE(v_row->>'almacen_id', v_row->>'warehouse_id'), '')::bigint;
  IF v_id IS NOT NULL THEN
    v_candidate_organization_id := NULL;
    SELECT organization_id INTO v_candidate_organization_id
    FROM public.almacenes WHERE id=v_id;
    IF v_candidate_organization_id IS NOT NULL THEN
      IF v_derived_organization_id IS NOT NULL
         AND v_derived_organization_id IS DISTINCT FROM v_candidate_organization_id THEN
        RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant product/warehouse relationship is not allowed';
      END IF;
      v_derived_organization_id := v_candidate_organization_id;
    END IF;
  END IF;

  v_id := NULLIF(v_row->>'almacen_origen_id','')::bigint;
  IF v_id IS NOT NULL THEN
    v_candidate_organization_id := NULL;
    SELECT organization_id INTO v_candidate_organization_id
    FROM public.almacenes WHERE id=v_id;
    IF v_candidate_organization_id IS NOT NULL THEN
      IF v_derived_organization_id IS NOT NULL
         AND v_derived_organization_id IS DISTINCT FROM v_candidate_organization_id THEN
        RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant transfer origin is not allowed';
      END IF;
      v_derived_organization_id := v_candidate_organization_id;
    END IF;
  END IF;

  v_id := NULLIF(v_row->>'almacen_destino_id','')::bigint;
  IF v_id IS NOT NULL THEN
    v_candidate_organization_id := NULL;
    SELECT organization_id INTO v_candidate_organization_id
    FROM public.almacenes WHERE id=v_id;
    IF v_candidate_organization_id IS NOT NULL THEN
      IF v_derived_organization_id IS NOT NULL
         AND v_derived_organization_id IS DISTINCT FROM v_candidate_organization_id THEN
        RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant transfer destination is not allowed';
      END IF;
      v_derived_organization_id := v_candidate_organization_id;
    END IF;
  END IF;

  IF v_current_organization_id IS NOT NULL THEN
    IF v_derived_organization_id IS NOT NULL
       AND v_derived_organization_id IS DISTINCT FROM v_current_organization_id THEN
      RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Cross-tenant inventory write is not allowed';
    END IF;
    IF TG_OP='UPDATE' AND OLD.organization_id IS DISTINCT FROM v_current_organization_id THEN
      RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Cross-tenant inventory update is not allowed';
    END IF;
    IF NEW.organization_id IS NOT NULL
       AND NEW.organization_id IS DISTINCT FROM v_current_organization_id THEN
      RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Client cannot choose another organization_id';
    END IF;
    NEW.organization_id := v_current_organization_id;
    RETURN NEW;
  END IF;

  IF current_user IN ('service_role','postgres') THEN
    IF v_derived_organization_id IS NOT NULL THEN
      IF NEW.organization_id IS NOT NULL
         AND NEW.organization_id IS DISTINCT FROM v_derived_organization_id THEN
        RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Explicit organization_id conflicts with inventory parents';
      END IF;
      NEW.organization_id := v_derived_organization_id;
      RETURN NEW;
    END IF;
    IF NEW.organization_id IS NULL THEN
      RAISE EXCEPTION USING ERRCODE='23502', MESSAGE='Privileged inventory write requires explicit or derivable organization_id';
    END IF;
    RETURN NEW;
  END IF;

  RAISE EXCEPTION USING ERRCODE='42501', MESSAGE='Active organization membership required';
END;
$$;
REVOKE ALL ON FUNCTION private.enforce_inventory_organization_id() FROM PUBLIC, anon, authenticated;

-- Backfill fail-closed. UUID no tiene aggregate min() en PostgreSQL 17; el UUID
-- de fallback se obtiene por ORDER BY sólo después de comprobar que existe un
-- único organization_id distinto.
DO $backfill$
DECLARE
  v_organization_count integer;
  v_fallback_organization_id uuid;
BEGIN
  SELECT count(DISTINCT organization_id)::integer
  INTO v_organization_count
  FROM public.configuracion_negocio
  WHERE organization_id IS NOT NULL;

  IF v_organization_count = 1 THEN
    SELECT organization_id
    INTO v_fallback_organization_id
    FROM public.configuracion_negocio
    WHERE organization_id IS NOT NULL
    ORDER BY organization_id::text
    LIMIT 1;
  END IF;

  IF EXISTS (SELECT 1 FROM public.almacenes WHERE organization_id IS NULL) THEN
    IF v_organization_count <> 1 THEN
      RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='Ambiguous legacy state: unscoped warehouses require exactly one organization';
    END IF;
    UPDATE public.almacenes SET organization_id=v_fallback_organization_id WHERE organization_id IS NULL;
  END IF;

  UPDATE public.inventario_almacen x SET organization_id=p.organization_id
  FROM public.productos p WHERE x.organization_id IS NULL AND x.producto_id=p.id;
  UPDATE public.inventario_almacen x SET organization_id=a.organization_id
  FROM public.almacenes a WHERE x.organization_id IS NULL AND x.almacen_id=a.id;

  UPDATE public.inventario_movimientos x SET organization_id=p.organization_id
  FROM public.productos p WHERE x.organization_id IS NULL AND x.producto_id=p.id;
  UPDATE public.inventario_movimientos x SET organization_id=a.organization_id
  FROM public.almacenes a WHERE x.organization_id IS NULL AND x.almacen_id=a.id;

  UPDATE public.inventario_operaciones_idempotentes x SET organization_id=p.organization_id
  FROM public.productos p WHERE x.organization_id IS NULL AND x.producto_id=p.id;
  UPDATE public.inventory_lots x SET organization_id=p.organization_id
  FROM public.productos p WHERE x.organization_id IS NULL AND x.product_id=p.id;
  UPDATE public.inventory_serials x SET organization_id=p.organization_id
  FROM public.productos p WHERE x.organization_id IS NULL AND x.product_id=p.id;
  UPDATE public.inventory_traceability_consumptions x SET organization_id=p.organization_id
  FROM public.productos p WHERE x.organization_id IS NULL AND x.product_id=p.id;
  UPDATE public.inventory_traceability_receipts x SET organization_id=p.organization_id
  FROM public.productos p WHERE x.organization_id IS NULL AND x.product_id=p.id;
  UPDATE public.stock_alert_tx_context x SET organization_id=p.organization_id
  FROM public.productos p WHERE x.organization_id IS NULL AND x.producto_id=p.id;
  UPDATE public.transferencias_stock x SET organization_id=p.organization_id
  FROM public.productos p WHERE x.organization_id IS NULL AND x.producto_id=p.id;
  UPDATE public.transferencias_stock x SET organization_id=a.organization_id
  FROM public.almacenes a WHERE x.organization_id IS NULL AND x.almacen_origen_id=a.id;
  UPDATE public.transferencias_stock x SET organization_id=a.organization_id
  FROM public.almacenes a WHERE x.organization_id IS NULL AND x.almacen_destino_id=a.id;
  UPDATE public.sys_processed_requests x SET organization_id=p.organization_id
  FROM public.productos p WHERE x.organization_id IS NULL AND x.producto_id=p.id;

  -- Sólo estas dos tablas históricas admiten filas sin padre suficiente.
  IF EXISTS (SELECT 1 FROM public.inventario_movimientos WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.sys_processed_requests WHERE organization_id IS NULL) THEN
    IF v_organization_count <> 1 THEN
      RAISE EXCEPTION USING ERRCODE='55000', MESSAGE='Ambiguous legacy state: inventory rows remain without a derivable organization';
    END IF;
    UPDATE public.inventario_movimientos SET organization_id=v_fallback_organization_id WHERE organization_id IS NULL;
    UPDATE public.sys_processed_requests SET organization_id=v_fallback_organization_id WHERE organization_id IS NULL;
  END IF;

  IF EXISTS (SELECT 1 FROM public.inventario_almacen WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.inventario_movimientos WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.inventario_operaciones_idempotentes WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.inventory_lots WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.inventory_serials WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.inventory_traceability_consumptions WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.inventory_traceability_receipts WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.stock_alert_tx_context WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.transferencias_stock WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.sys_processed_requests WHERE organization_id IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Unscoped inventory rows remain after tenant backfill';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.inventario_almacen x
    JOIN public.productos p ON p.id=x.producto_id
    JOIN public.almacenes a ON a.id=x.almacen_id
    WHERE x.organization_id IS DISTINCT FROM p.organization_id
       OR x.organization_id IS DISTINCT FROM a.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant inventory balance exists';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.inventory_lots x
    JOIN public.productos p ON p.id=x.product_id
    JOIN public.almacenes a ON a.id=x.warehouse_id
    WHERE x.organization_id IS DISTINCT FROM p.organization_id
       OR x.organization_id IS DISTINCT FROM a.organization_id
  ) OR EXISTS (
    SELECT 1 FROM public.inventory_serials x
    JOIN public.productos p ON p.id=x.product_id
    JOIN public.almacenes a ON a.id=x.warehouse_id
    WHERE x.organization_id IS DISTINCT FROM p.organization_id
       OR x.organization_id IS DISTINCT FROM a.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant traceability stock exists';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.transferencias_stock x
    LEFT JOIN public.productos p ON p.id=x.producto_id
    LEFT JOIN public.almacenes o ON o.id=x.almacen_origen_id
    LEFT JOIN public.almacenes d ON d.id=x.almacen_destino_id
    WHERE (p.id IS NOT NULL AND x.organization_id IS DISTINCT FROM p.organization_id)
       OR (o.id IS NOT NULL AND x.organization_id IS DISTINCT FROM o.organization_id)
       OR (d.id IS NOT NULL AND x.organization_id IS DISTINCT FROM d.organization_id)
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant stock transfer exists';
  END IF;
END;
$backfill$;

ALTER TABLE public.almacenes ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.inventario_almacen ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.inventario_movimientos ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.inventario_operaciones_idempotentes ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.inventory_lots ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.inventory_serials ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.inventory_traceability_consumptions ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.inventory_traceability_receipts ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.stock_alert_tx_context ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.transferencias_stock ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.sys_processed_requests ALTER COLUMN organization_id SET NOT NULL;

ALTER TABLE public.almacenes
  ADD CONSTRAINT almacenes_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT almacenes_organization_id_id_key UNIQUE (organization_id,id);
ALTER TABLE public.inventario_almacen ADD CONSTRAINT inventario_almacen_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;
ALTER TABLE public.inventario_movimientos
  ADD CONSTRAINT inventario_movimientos_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT inventario_movimientos_organization_id_id_key UNIQUE (organization_id,id);
ALTER TABLE public.inventario_operaciones_idempotentes ADD CONSTRAINT inventario_operaciones_idempotentes_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;
ALTER TABLE public.inventory_lots ADD CONSTRAINT inventory_lots_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;
ALTER TABLE public.inventory_serials ADD CONSTRAINT inventory_serials_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;
ALTER TABLE public.inventory_traceability_consumptions ADD CONSTRAINT inventory_traceability_consumptions_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;
ALTER TABLE public.inventory_traceability_receipts ADD CONSTRAINT inventory_traceability_receipts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;
ALTER TABLE public.stock_alert_tx_context ADD CONSTRAINT stock_alert_tx_context_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;
ALTER TABLE public.transferencias_stock ADD CONSTRAINT transferencias_stock_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;
ALTER TABLE public.sys_processed_requests ADD CONSTRAINT sys_processed_requests_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT;

CREATE INDEX almacenes_organization_id_idx ON public.almacenes(organization_id);
CREATE INDEX inventario_almacen_organization_id_idx ON public.inventario_almacen(organization_id);
CREATE INDEX inventario_movimientos_organization_id_idx ON public.inventario_movimientos(organization_id);
CREATE INDEX inventario_operaciones_idempotentes_organization_id_idx ON public.inventario_operaciones_idempotentes(organization_id);
CREATE INDEX inventory_lots_organization_id_idx ON public.inventory_lots(organization_id);
CREATE INDEX inventory_serials_organization_id_idx ON public.inventory_serials(organization_id);
CREATE INDEX inventory_traceability_consumptions_organization_id_idx ON public.inventory_traceability_consumptions(organization_id);
CREATE INDEX inventory_traceability_receipts_organization_id_idx ON public.inventory_traceability_receipts(organization_id);
CREATE INDEX stock_alert_tx_context_organization_id_idx ON public.stock_alert_tx_context(organization_id);
CREATE INDEX transferencias_stock_organization_id_idx ON public.transferencias_stock(organization_id);
CREATE INDEX sys_processed_requests_organization_id_idx ON public.sys_processed_requests(organization_id);

-- Relaciones tenant-qualified. Los IDs/request_id siguen globales durante este
-- rollout para no romper ON CONFLICT ni contratos de idempotencia existentes.
ALTER TABLE public.inventario_almacen
  DROP CONSTRAINT IF EXISTS inventario_almacen_producto_id_fkey,
  DROP CONSTRAINT IF EXISTS inventario_almacen_almacen_id_fkey;
ALTER TABLE public.inventario_almacen
  ADD CONSTRAINT inventario_almacen_organization_product_fkey FOREIGN KEY (organization_id,producto_id) REFERENCES public.productos(organization_id,id) ON DELETE CASCADE,
  ADD CONSTRAINT inventario_almacen_organization_warehouse_fkey FOREIGN KEY (organization_id,almacen_id) REFERENCES public.almacenes(organization_id,id) ON DELETE CASCADE;

ALTER TABLE public.inventario_movimientos
  DROP CONSTRAINT IF EXISTS inventario_movimientos_producto_id_fkey,
  DROP CONSTRAINT IF EXISTS inventario_movimientos_almacen_id_fkey;
ALTER TABLE public.inventario_movimientos
  ADD CONSTRAINT inventario_movimientos_organization_product_fkey FOREIGN KEY (organization_id,producto_id) REFERENCES public.productos(organization_id,id) ON DELETE SET NULL (producto_id),
  ADD CONSTRAINT inventario_movimientos_organization_warehouse_fkey FOREIGN KEY (organization_id,almacen_id) REFERENCES public.almacenes(organization_id,id) ON DELETE SET NULL (almacen_id);

ALTER TABLE public.inventario_operaciones_idempotentes DROP CONSTRAINT IF EXISTS inventario_operaciones_idempotentes_producto_id_fkey;
ALTER TABLE public.inventario_operaciones_idempotentes
  ADD CONSTRAINT inventario_operaciones_idempotentes_organization_product_fkey FOREIGN KEY (organization_id,producto_id) REFERENCES public.productos(organization_id,id) ON DELETE CASCADE;

ALTER TABLE public.inventory_lots DROP CONSTRAINT IF EXISTS inventory_lots_product_id_fkey, DROP CONSTRAINT IF EXISTS inventory_lots_warehouse_id_fkey;
ALTER TABLE public.inventory_lots
  ADD CONSTRAINT inventory_lots_organization_product_fkey FOREIGN KEY (organization_id,product_id) REFERENCES public.productos(organization_id,id),
  ADD CONSTRAINT inventory_lots_organization_warehouse_fkey FOREIGN KEY (organization_id,warehouse_id) REFERENCES public.almacenes(organization_id,id);

ALTER TABLE public.inventory_serials DROP CONSTRAINT IF EXISTS inventory_serials_product_id_fkey, DROP CONSTRAINT IF EXISTS inventory_serials_warehouse_id_fkey;
ALTER TABLE public.inventory_serials
  ADD CONSTRAINT inventory_serials_organization_product_fkey FOREIGN KEY (organization_id,product_id) REFERENCES public.productos(organization_id,id),
  ADD CONSTRAINT inventory_serials_organization_warehouse_fkey FOREIGN KEY (organization_id,warehouse_id) REFERENCES public.almacenes(organization_id,id);

ALTER TABLE public.inventory_traceability_consumptions DROP CONSTRAINT IF EXISTS inventory_traceability_consumptions_product_id_fkey, DROP CONSTRAINT IF EXISTS inventory_traceability_consumptions_warehouse_id_fkey;
ALTER TABLE public.inventory_traceability_consumptions
  ADD CONSTRAINT inventory_traceability_consumptions_organization_product_fkey FOREIGN KEY (organization_id,product_id) REFERENCES public.productos(organization_id,id),
  ADD CONSTRAINT inventory_traceability_consumptions_organization_warehouse_fkey FOREIGN KEY (organization_id,warehouse_id) REFERENCES public.almacenes(organization_id,id);

ALTER TABLE public.inventory_traceability_receipts DROP CONSTRAINT IF EXISTS inventory_traceability_receipts_product_id_fkey, DROP CONSTRAINT IF EXISTS inventory_traceability_receipts_warehouse_id_fkey;
ALTER TABLE public.inventory_traceability_receipts
  ADD CONSTRAINT inventory_traceability_receipts_organization_product_fkey FOREIGN KEY (organization_id,product_id) REFERENCES public.productos(organization_id,id),
  ADD CONSTRAINT inventory_traceability_receipts_organization_warehouse_fkey FOREIGN KEY (organization_id,warehouse_id) REFERENCES public.almacenes(organization_id,id);

ALTER TABLE public.stock_alert_tx_context DROP CONSTRAINT IF EXISTS stock_alert_tx_context_producto_id_fkey;
ALTER TABLE public.stock_alert_tx_context ADD CONSTRAINT stock_alert_tx_context_organization_product_fkey FOREIGN KEY (organization_id,producto_id) REFERENCES public.productos(organization_id,id) ON DELETE CASCADE;

ALTER TABLE public.transferencias_stock
  DROP CONSTRAINT IF EXISTS transferencias_stock_producto_id_fkey,
  DROP CONSTRAINT IF EXISTS transferencias_stock_almacen_origen_id_fkey,
  DROP CONSTRAINT IF EXISTS transferencias_stock_almacen_destino_id_fkey;
ALTER TABLE public.transferencias_stock
  ADD CONSTRAINT transferencias_stock_organization_product_fkey FOREIGN KEY (organization_id,producto_id) REFERENCES public.productos(organization_id,id) ON DELETE CASCADE,
  ADD CONSTRAINT transferencias_stock_organization_origin_fkey FOREIGN KEY (organization_id,almacen_origen_id) REFERENCES public.almacenes(organization_id,id),
  ADD CONSTRAINT transferencias_stock_organization_destination_fkey FOREIGN KEY (organization_id,almacen_destino_id) REFERENCES public.almacenes(organization_id,id),
  ADD CONSTRAINT transferencias_stock_organization_exit_movement_fkey FOREIGN KEY (organization_id,movimiento_salida_id) REFERENCES public.inventario_movimientos(organization_id,id) ON DELETE SET NULL (movimiento_salida_id),
  ADD CONSTRAINT transferencias_stock_organization_entry_movement_fkey FOREIGN KEY (organization_id,movimiento_entrada_id) REFERENCES public.inventario_movimientos(organization_id,id) ON DELETE SET NULL (movimiento_entrada_id);

ALTER TABLE public.sys_processed_requests
  ADD CONSTRAINT sys_processed_requests_organization_product_fkey FOREIGN KEY (organization_id,producto_id) REFERENCES public.productos(organization_id,id) ON DELETE SET NULL (producto_id);

CREATE TRIGGER almacenes_enforce_organization_id BEFORE INSERT OR UPDATE ON public.almacenes FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER inventario_almacen_enforce_organization_id BEFORE INSERT OR UPDATE ON public.inventario_almacen FOR EACH ROW EXECUTE FUNCTION private.enforce_inventory_organization_id();
CREATE TRIGGER inventario_movimientos_enforce_organization_id BEFORE INSERT OR UPDATE ON public.inventario_movimientos FOR EACH ROW EXECUTE FUNCTION private.enforce_inventory_organization_id();
CREATE TRIGGER inventario_operaciones_idempotentes_enforce_organization_id BEFORE INSERT OR UPDATE ON public.inventario_operaciones_idempotentes FOR EACH ROW EXECUTE FUNCTION private.enforce_inventory_organization_id();
CREATE TRIGGER inventory_lots_enforce_organization_id BEFORE INSERT OR UPDATE ON public.inventory_lots FOR EACH ROW EXECUTE FUNCTION private.enforce_inventory_organization_id();
CREATE TRIGGER inventory_serials_enforce_organization_id BEFORE INSERT OR UPDATE ON public.inventory_serials FOR EACH ROW EXECUTE FUNCTION private.enforce_inventory_organization_id();
CREATE TRIGGER inventory_traceability_consumptions_enforce_organization_id BEFORE INSERT OR UPDATE ON public.inventory_traceability_consumptions FOR EACH ROW EXECUTE FUNCTION private.enforce_inventory_organization_id();
CREATE TRIGGER inventory_traceability_receipts_enforce_organization_id BEFORE INSERT OR UPDATE ON public.inventory_traceability_receipts FOR EACH ROW EXECUTE FUNCTION private.enforce_inventory_organization_id();
CREATE TRIGGER stock_alert_tx_context_enforce_organization_id BEFORE INSERT OR UPDATE ON public.stock_alert_tx_context FOR EACH ROW EXECUTE FUNCTION private.enforce_inventory_organization_id();
CREATE TRIGGER transferencias_stock_enforce_organization_id BEFORE INSERT OR UPDATE ON public.transferencias_stock FOR EACH ROW EXECUTE FUNCTION private.enforce_inventory_organization_id();
CREATE TRIGGER sys_processed_requests_enforce_organization_id BEFORE INSERT OR UPDATE ON public.sys_processed_requests FOR EACH ROW EXECUTE FUNCTION private.enforce_inventory_organization_id();

ALTER TABLE public.almacenes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventario_almacen ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventario_movimientos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventario_operaciones_idempotentes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_lots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_serials ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_traceability_consumptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_traceability_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_alert_tx_context ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transferencias_stock ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sys_processed_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS almacenes_admin_insert ON public.almacenes;
DROP POLICY IF EXISTS almacenes_admin_update ON public.almacenes;
DROP POLICY IF EXISTS almacenes_select ON public.almacenes;
DROP POLICY IF EXISTS inventario_almacen_select ON public.inventario_almacen;
DROP POLICY IF EXISTS inventario_movimientos_admin_select ON public.inventario_movimientos;
DROP POLICY IF EXISTS inventory_lots_read ON public.inventory_lots;
DROP POLICY IF EXISTS inventory_serials_read ON public.inventory_serials;

CREATE POLICY almacenes_tenant_select ON public.almacenes FOR SELECT TO authenticated
USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY almacenes_tenant_insert ON public.almacenes FOR INSERT TO authenticated
WITH CHECK (private.has_permission('tenant.admin') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY almacenes_tenant_update ON public.almacenes FOR UPDATE TO authenticated
USING (private.has_permission('tenant.admin') AND private.row_belongs_to_current_organization(organization_id))
WITH CHECK (private.has_permission('tenant.admin') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY inventario_almacen_tenant_select ON public.inventario_almacen FOR SELECT TO authenticated
USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY inventario_movimientos_tenant_select ON public.inventario_movimientos FOR SELECT TO authenticated
USING (private.has_permission('tenant.admin') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY inventory_lots_tenant_select ON public.inventory_lots FOR SELECT TO authenticated
USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));
CREATE POLICY inventory_serials_tenant_select ON public.inventory_serials FOR SELECT TO authenticated
USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));

REVOKE ALL ON TABLE public.almacenes FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.inventario_almacen FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.inventario_movimientos FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.inventario_operaciones_idempotentes FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.inventory_lots FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.inventory_serials FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.inventory_traceability_consumptions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.inventory_traceability_receipts FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.stock_alert_tx_context FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.transferencias_stock FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.sys_processed_requests FROM PUBLIC, anon, authenticated;

GRANT SELECT, INSERT, UPDATE ON TABLE public.almacenes TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.almacenes_id_seq TO authenticated;
GRANT SELECT ON TABLE public.inventario_almacen TO authenticated;
GRANT SELECT ON TABLE public.inventario_movimientos TO authenticated;
GRANT SELECT ON TABLE public.inventory_lots TO authenticated;
GRANT SELECT ON TABLE public.inventory_serials TO authenticated;

COMMIT;
