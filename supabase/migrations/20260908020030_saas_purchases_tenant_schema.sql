-- Fase 3.6 SaaS (esquema): compras, recepciones, gastos y pagos a proveedor por organización.
BEGIN;

ALTER TABLE public.purchase_orders ADD COLUMN organization_id uuid;
ALTER TABLE public.purchase_order_lines ADD COLUMN organization_id uuid;
ALTER TABLE public.purchase_receipts ADD COLUMN organization_id uuid;
ALTER TABLE public.purchase_receipt_lines ADD COLUMN organization_id uuid;
ALTER TABLE public.gastos ADD COLUMN organization_id uuid;
ALTER TABLE public.pagos_gasto ADD COLUMN organization_id uuid;

COMMENT ON COLUMN public.purchase_orders.organization_id IS 'Tenant propietario de la orden de compra.';
COMMENT ON COLUMN public.purchase_order_lines.organization_id IS 'Tenant propietario de la línea de compra.';
COMMENT ON COLUMN public.purchase_receipts.organization_id IS 'Tenant propietario de la recepción de compra.';
COMMENT ON COLUMN public.purchase_receipt_lines.organization_id IS 'Tenant propietario de la línea de recepción.';
COMMENT ON COLUMN public.gastos.organization_id IS 'Tenant propietario del gasto/cuenta por pagar.';
COMMENT ON COLUMN public.pagos_gasto.organization_id IS 'Tenant propietario del pago de gasto.';

DO $backfill$
DECLARE
  v_needs_fallback boolean;
  v_org_count integer;
  v_fallback_org uuid;
BEGIN
  -- Cabeceras de compra: proveedor y almacén deben coincidir en tenant.
  UPDATE public.purchase_orders AS o
  SET organization_id = s.organization_id
  FROM public.proveedores AS s, public.almacenes AS a
  WHERE o.organization_id IS NULL
    AND s.id = o.supplier_id
    AND a.id = o.warehouse_id
    AND s.organization_id = a.organization_id;

  -- Líneas: heredan la orden y deben coincidir con el producto.
  UPDATE public.purchase_order_lines AS l
  SET organization_id = o.organization_id
  FROM public.purchase_orders AS o, public.productos AS p
  WHERE l.organization_id IS NULL
    AND o.id = l.purchase_order_id
    AND p.id = l.product_id
    AND o.organization_id = p.organization_id;

  -- Recepciones y sus líneas heredan ownership desde la orden.
  UPDATE public.purchase_receipts AS r
  SET organization_id = o.organization_id
  FROM public.purchase_orders AS o
  WHERE r.organization_id IS NULL
    AND o.id = r.purchase_order_id;

  UPDATE public.purchase_receipt_lines AS l
  SET organization_id = r.organization_id
  FROM public.purchase_receipts AS r, public.purchase_order_lines AS ol
  WHERE l.organization_id IS NULL
    AND r.id = l.purchase_receipt_id
    AND ol.id = l.purchase_order_line_id
    AND r.organization_id = ol.organization_id;

  -- Gasto: derivar desde proveedor cuando exista; pagos siempre desde el gasto.
  UPDATE public.gastos AS g
  SET organization_id = p.organization_id
  FROM public.proveedores AS p
  WHERE g.organization_id IS NULL
    AND g.proveedor_id = p.id;

  UPDATE public.pagos_gasto AS pg
  SET organization_id = g.organization_id
  FROM public.gastos AS g
  WHERE pg.organization_id IS NULL
    AND pg.gasto_id = g.id;

  SELECT
    EXISTS (SELECT 1 FROM public.purchase_orders WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.purchase_order_lines WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.purchase_receipts WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.purchase_receipt_lines WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.gastos WHERE organization_id IS NULL)
    OR EXISTS (SELECT 1 FROM public.pagos_gasto WHERE organization_id IS NULL)
  INTO v_needs_fallback;

  IF v_needs_fallback THEN
    SELECT count(DISTINCT organization_id)::integer
    INTO v_org_count
    FROM public.configuracion_negocio;

    IF v_org_count <> 1 THEN
      RAISE EXCEPTION USING
        ERRCODE='55000',
        MESSAGE='Ambiguous legacy state: unscoped purchase/expense data requires exactly one business organization';
    END IF;

    SELECT organization_id INTO v_fallback_org
    FROM public.configuracion_negocio
    ORDER BY organization_id::text
    LIMIT 1;

    UPDATE public.purchase_orders SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.purchase_order_lines SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.purchase_receipts SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.purchase_receipt_lines SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.gastos SET organization_id=v_fallback_org WHERE organization_id IS NULL;
    UPDATE public.pagos_gasto SET organization_id=v_fallback_org WHERE organization_id IS NULL;
  END IF;

  -- Rechazar cualquier relación histórica que ya cruce tenants.
  IF EXISTS (
    SELECT 1
    FROM public.purchase_orders o
    JOIN public.proveedores s ON s.id=o.supplier_id
    JOIN public.almacenes a ON a.id=o.warehouse_id
    WHERE o.organization_id IS DISTINCT FROM s.organization_id
       OR o.organization_id IS DISTINCT FROM a.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant purchase order header exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.purchase_order_lines l
    JOIN public.purchase_orders o ON o.id=l.purchase_order_id
    JOIN public.productos p ON p.id=l.product_id
    WHERE l.organization_id IS DISTINCT FROM o.organization_id
       OR l.organization_id IS DISTINCT FROM p.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant purchase order line exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.purchase_receipts r
    JOIN public.purchase_orders o ON o.id=r.purchase_order_id
    WHERE r.organization_id IS DISTINCT FROM o.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant purchase receipt exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.purchase_receipt_lines l
    JOIN public.purchase_receipts r ON r.id=l.purchase_receipt_id
    JOIN public.purchase_order_lines ol ON ol.id=l.purchase_order_line_id
    WHERE l.organization_id IS DISTINCT FROM r.organization_id
       OR l.organization_id IS DISTINCT FROM ol.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant purchase receipt line exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.gastos g
    JOIN public.proveedores p ON p.id=g.proveedor_id
    WHERE g.proveedor_id IS NOT NULL
      AND g.organization_id IS DISTINCT FROM p.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant expense/supplier relationship exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.pagos_gasto pg
    JOIN public.gastos g ON g.id=pg.gasto_id
    WHERE pg.organization_id IS DISTINCT FROM g.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant expense payment exists';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.pagos_gasto pg
    JOIN public.pagos_deuda_requests r ON r.request_id=pg.request_id
    WHERE pg.request_id IS NOT NULL
      AND pg.organization_id IS DISTINCT FROM r.organization_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='Cross-tenant supplier debt request/payment relationship exists';
  END IF;

  IF EXISTS (SELECT 1 FROM public.purchase_orders WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.purchase_order_lines WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.purchase_receipts WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.purchase_receipt_lines WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.gastos WHERE organization_id IS NULL)
     OR EXISTS (SELECT 1 FROM public.pagos_gasto WHERE organization_id IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='Unscoped purchase/expense rows remain after tenant backfill';
  END IF;
END;
$backfill$;

ALTER TABLE public.purchase_orders ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.purchase_order_lines ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.purchase_receipts ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.purchase_receipt_lines ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.gastos ALTER COLUMN organization_id SET NOT NULL;
ALTER TABLE public.pagos_gasto ALTER COLUMN organization_id SET NOT NULL;

-- Ownership y claves compuestas para FKs tenant-qualified.
ALTER TABLE public.purchase_orders
  ADD CONSTRAINT purchase_orders_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT purchase_orders_organization_id_id_key UNIQUE (organization_id,id);
ALTER TABLE public.purchase_order_lines
  ADD CONSTRAINT purchase_order_lines_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT purchase_order_lines_organization_id_id_key UNIQUE (organization_id,id);
ALTER TABLE public.purchase_receipts
  ADD CONSTRAINT purchase_receipts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT purchase_receipts_organization_id_id_key UNIQUE (organization_id,id);
ALTER TABLE public.purchase_receipt_lines
  ADD CONSTRAINT purchase_receipt_lines_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT purchase_receipt_lines_organization_id_id_key UNIQUE (organization_id,id);
ALTER TABLE public.gastos
  ADD CONSTRAINT gastos_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT gastos_organization_id_id_key UNIQUE (organization_id,id);
ALTER TABLE public.pagos_gasto
  ADD CONSTRAINT pagos_gasto_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES public.organizations(id) ON DELETE RESTRICT,
  ADD CONSTRAINT pagos_gasto_organization_id_id_key UNIQUE (organization_id,id);

-- Idempotencia por tenant, sin compartir namespace comercial entre empresas.
ALTER TABLE public.purchase_orders DROP CONSTRAINT IF EXISTS purchase_orders_request_id_key;
ALTER TABLE public.purchase_orders
  ADD CONSTRAINT purchase_orders_organization_request_key UNIQUE (organization_id,request_id);

ALTER TABLE public.purchase_receipts DROP CONSTRAINT IF EXISTS purchase_receipts_request_id_key;
ALTER TABLE public.purchase_receipts
  ADD CONSTRAINT purchase_receipts_organization_request_key UNIQUE (organization_id,request_id);

DROP INDEX IF EXISTS public.pagos_gasto_request_id_uidx;
CREATE UNIQUE INDEX pagos_gasto_organization_request_uidx
  ON public.pagos_gasto(organization_id,request_id)
  WHERE request_id IS NOT NULL;

-- FKs compuestas: un ID válido de otro tenant deja de ser una referencia válida.
ALTER TABLE public.purchase_orders
  DROP CONSTRAINT IF EXISTS purchase_orders_supplier_id_fkey,
  DROP CONSTRAINT IF EXISTS purchase_orders_warehouse_id_fkey;
ALTER TABLE public.purchase_orders
  ADD CONSTRAINT purchase_orders_supplier_id_fkey
    FOREIGN KEY (organization_id,supplier_id) REFERENCES public.proveedores(organization_id,id),
  ADD CONSTRAINT purchase_orders_warehouse_id_fkey
    FOREIGN KEY (organization_id,warehouse_id) REFERENCES public.almacenes(organization_id,id);

ALTER TABLE public.purchase_order_lines
  DROP CONSTRAINT IF EXISTS purchase_order_lines_purchase_order_id_fkey,
  DROP CONSTRAINT IF EXISTS purchase_order_lines_product_id_fkey,
  DROP CONSTRAINT IF EXISTS purchase_order_lines_purchase_order_id_product_id_key;
ALTER TABLE public.purchase_order_lines
  ADD CONSTRAINT purchase_order_lines_purchase_order_id_fkey
    FOREIGN KEY (organization_id,purchase_order_id) REFERENCES public.purchase_orders(organization_id,id) ON DELETE CASCADE,
  ADD CONSTRAINT purchase_order_lines_product_id_fkey
    FOREIGN KEY (organization_id,product_id) REFERENCES public.productos(organization_id,id),
  ADD CONSTRAINT purchase_order_lines_organization_order_product_key
    UNIQUE (organization_id,purchase_order_id,product_id);

ALTER TABLE public.purchase_receipts
  DROP CONSTRAINT IF EXISTS purchase_receipts_purchase_order_id_fkey;
ALTER TABLE public.purchase_receipts
  ADD CONSTRAINT purchase_receipts_purchase_order_id_fkey
    FOREIGN KEY (organization_id,purchase_order_id) REFERENCES public.purchase_orders(organization_id,id);

ALTER TABLE public.purchase_receipt_lines
  DROP CONSTRAINT IF EXISTS purchase_receipt_lines_purchase_receipt_id_fkey,
  DROP CONSTRAINT IF EXISTS purchase_receipt_lines_purchase_order_line_id_fkey,
  DROP CONSTRAINT IF EXISTS purchase_receipt_lines_purchase_receipt_id_purchase_order_l_key;
ALTER TABLE public.purchase_receipt_lines
  ADD CONSTRAINT purchase_receipt_lines_purchase_receipt_id_fkey
    FOREIGN KEY (organization_id,purchase_receipt_id) REFERENCES public.purchase_receipts(organization_id,id) ON DELETE CASCADE,
  ADD CONSTRAINT purchase_receipt_lines_purchase_order_line_id_fkey
    FOREIGN KEY (organization_id,purchase_order_line_id) REFERENCES public.purchase_order_lines(organization_id,id),
  ADD CONSTRAINT purchase_receipt_lines_organization_receipt_order_line_key
    UNIQUE (organization_id,purchase_receipt_id,purchase_order_line_id);

ALTER TABLE public.gastos DROP CONSTRAINT IF EXISTS gastos_proveedor_id_fkey;
ALTER TABLE public.gastos
  ADD CONSTRAINT gastos_proveedor_id_fkey
    FOREIGN KEY (organization_id,proveedor_id) REFERENCES public.proveedores(organization_id,id) ON DELETE SET NULL (proveedor_id);

ALTER TABLE public.pagos_gasto
  DROP CONSTRAINT IF EXISTS pagos_gasto_gasto_id_fkey,
  DROP CONSTRAINT IF EXISTS pagos_gasto_request_id_fkey;
ALTER TABLE public.pagos_gasto
  ADD CONSTRAINT pagos_gasto_gasto_id_fkey
    FOREIGN KEY (organization_id,gasto_id) REFERENCES public.gastos(organization_id,id) ON DELETE CASCADE,
  ADD CONSTRAINT pagos_gasto_request_id_fkey
    FOREIGN KEY (organization_id,request_id) REFERENCES public.pagos_deuda_requests(organization_id,request_id) ON DELETE RESTRICT;

CREATE INDEX purchase_orders_organization_id_idx ON public.purchase_orders(organization_id);
CREATE INDEX purchase_order_lines_organization_id_idx ON public.purchase_order_lines(organization_id);
CREATE INDEX purchase_receipts_organization_id_idx ON public.purchase_receipts(organization_id);
CREATE INDEX purchase_receipt_lines_organization_id_idx ON public.purchase_receipt_lines(organization_id);
CREATE INDEX gastos_organization_id_idx ON public.gastos(organization_id);
CREATE INDEX pagos_gasto_organization_id_idx ON public.pagos_gasto(organization_id);

-- Organization_id se deriva server-side y es inmutable.
CREATE TRIGGER purchase_orders_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.purchase_orders
FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER purchase_order_lines_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.purchase_order_lines
FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER purchase_receipts_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.purchase_receipts
FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER purchase_receipt_lines_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.purchase_receipt_lines
FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER gastos_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.gastos
FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();
CREATE TRIGGER pagos_gasto_enforce_organization_id
BEFORE INSERT OR UPDATE ON public.pagos_gasto
FOR EACH ROW EXECUTE FUNCTION private.enforce_row_organization_id();

ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_order_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_receipt_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.gastos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pagos_gasto ENABLE ROW LEVEL SECURITY;

-- Compras operan exclusivamente por RPC; no exponer mutación/lectura directa.
REVOKE ALL ON TABLE public.purchase_orders FROM PUBLIC,anon,authenticated;
REVOKE ALL ON TABLE public.purchase_order_lines FROM PUBLIC,anon,authenticated;
REVOKE ALL ON TABLE public.purchase_receipts FROM PUBLIC,anon,authenticated;
REVOKE ALL ON TABLE public.purchase_receipt_lines FROM PUBLIC,anon,authenticated;

-- Gastos se leen directamente desde Flutter, pero toda mutación queda en RPC.
DROP POLICY IF EXISTS gastos_delete_empleado ON public.gastos;
DROP POLICY IF EXISTS gastos_select_empleado ON public.gastos;
DROP POLICY IF EXISTS gastos_update_empleado ON public.gastos;
DROP POLICY IF EXISTS pagos_gasto_delete_empleado ON public.pagos_gasto;
DROP POLICY IF EXISTS pagos_gasto_select_empleado ON public.pagos_gasto;

CREATE POLICY gastos_tenant_select ON public.gastos
FOR SELECT TO authenticated
USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));

CREATE POLICY pagos_gasto_tenant_select ON public.pagos_gasto
FOR SELECT TO authenticated
USING (private.has_permission('tenant.read') AND private.row_belongs_to_current_organization(organization_id));

REVOKE ALL ON TABLE public.gastos FROM PUBLIC,anon,authenticated;
REVOKE ALL ON TABLE public.pagos_gasto FROM PUBLIC,anon,authenticated;
GRANT SELECT ON TABLE public.gastos TO authenticated;
GRANT SELECT ON TABLE public.pagos_gasto TO authenticated;

COMMIT;
