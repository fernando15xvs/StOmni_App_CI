-- F9.5/F9.6 reconciliation: repair runtime surfaces that can drift in a
-- linked-schema replay while preserving the final SaaS tenant contract.
BEGIN;

-- -----------------------------------------------------------------------------
-- 1. GRE still reads transferencias_stock directly from Flutter. Restore only
--    tenant-scoped SELECT; all mutations remain RPC-only.
-- -----------------------------------------------------------------------------
ALTER TABLE public.transferencias_stock ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Permitir todo en transferencias_stock" ON public.transferencias_stock;
DROP POLICY IF EXISTS transferencias_stock_select_empleado ON public.transferencias_stock;
DROP POLICY IF EXISTS transferencias_stock_tenant_select ON public.transferencias_stock;
CREATE POLICY transferencias_stock_tenant_select
ON public.transferencias_stock
FOR SELECT TO authenticated
USING (
  private.has_permission('tenant.read')
  AND private.row_belongs_to_current_organization(organization_id)
);
REVOKE ALL ON TABLE public.transferencias_stock FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.transferencias_stock TO authenticated;
REVOKE ALL ON SEQUENCE public.transferencias_stock_id_seq FROM PUBLIC, anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. Service invariants are authoritative server-side protections. Historical
--    remote drift must not leave the functions present but their triggers absent.
-- -----------------------------------------------------------------------------
DO $service_triggers$
BEGIN
  IF to_regprocedure('public._service_normalize_product_v1()') IS NULL
     OR to_regprocedure('public._service_zero_inventory_v1()') IS NULL
     OR to_regprocedure('public._service_skip_kardex_v1()') IS NULL
     OR to_regprocedure('public._service_block_purchase_line_v1()') IS NULL
     OR to_regprocedure('public._service_block_traceability_v1()') IS NULL THEN
    RAISE EXCEPTION 'Service invariant trigger functions are incomplete';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.productos'::regclass
      AND tgname='service_product_invariants' AND NOT tgisinternal
  ) THEN
    CREATE TRIGGER service_product_invariants
    BEFORE INSERT OR UPDATE ON public.productos
    FOR EACH ROW EXECUTE FUNCTION public._service_normalize_product_v1();
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.inventario_almacen'::regclass
      AND tgname='service_inventory_always_zero' AND NOT tgisinternal
  ) THEN
    CREATE TRIGGER service_inventory_always_zero
    BEFORE INSERT OR UPDATE OF cantidad ON public.inventario_almacen
    FOR EACH ROW EXECUTE FUNCTION public._service_zero_inventory_v1();
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.inventario_movimientos'::regclass
      AND tgname='service_no_inventory_movements' AND NOT tgisinternal
  ) THEN
    CREATE TRIGGER service_no_inventory_movements
    BEFORE INSERT ON public.inventario_movimientos
    FOR EACH ROW EXECUTE FUNCTION public._service_skip_kardex_v1();
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.purchase_order_lines'::regclass
      AND tgname='service_not_purchase_inventory' AND NOT tgisinternal
  ) THEN
    CREATE TRIGGER service_not_purchase_inventory
    BEFORE INSERT OR UPDATE OF product_id ON public.purchase_order_lines
    FOR EACH ROW EXECUTE FUNCTION public._service_block_purchase_line_v1();
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid='public.product_traceability_configs'::regclass
      AND tgname='service_not_traceable' AND NOT tgisinternal
  ) THEN
    CREATE TRIGGER service_not_traceable
    BEFORE INSERT OR UPDATE OF mode ON public.product_traceability_configs
    FOR EACH ROW EXECUTE FUNCTION public._service_block_traceability_v1();
  END IF;
END;
$service_triggers$;

-- -----------------------------------------------------------------------------
-- 3. Debt-payment idempotency is tenant-local. pagos_gasto was converted in
--    F3.6, but pagos_venta still retained the historical global request index.
-- -----------------------------------------------------------------------------
DROP INDEX IF EXISTS public.pagos_venta_request_id_uidx;
CREATE UNIQUE INDEX IF NOT EXISTS pagos_venta_organization_request_uidx
  ON public.pagos_venta(organization_id,request_id)
  WHERE request_id IS NOT NULL;

-- -----------------------------------------------------------------------------
-- 4. Storage buckets are public only for reads. Mutations must be performed by
--    a tenant admin and remain inside <organization_id>/logos|products/...
-- -----------------------------------------------------------------------------
INSERT INTO storage.buckets (id,name,public)
VALUES
  ('logos','logos',true),
  ('imagenes_productos','imagenes_productos',true),
  ('comprobantes-electronicos','comprobantes-electronicos',false)
ON CONFLICT (id) DO UPDATE SET
  name=EXCLUDED.name,
  public=EXCLUDED.public;

DROP POLICY IF EXISTS logos_admin_delete ON storage.objects;
DROP POLICY IF EXISTS logos_admin_insert ON storage.objects;
DROP POLICY IF EXISTS logos_admin_update ON storage.objects;
DROP POLICY IF EXISTS logos_public_select ON storage.objects;
DROP POLICY IF EXISTS productos_imagenes_admin_delete ON storage.objects;
DROP POLICY IF EXISTS productos_imagenes_admin_insert ON storage.objects;
DROP POLICY IF EXISTS productos_imagenes_admin_update ON storage.objects;
DROP POLICY IF EXISTS productos_imagenes_public_select ON storage.objects;

CREATE POLICY logos_public_select
ON storage.objects FOR SELECT TO public
USING (bucket_id='logos');

CREATE POLICY logos_admin_insert
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id='logos'
  AND private.has_permission('tenant.admin')
  AND split_part(name,'/',1)=private.current_organization_id()::text
  AND split_part(name,'/',2)='logos'
);
CREATE POLICY logos_admin_update
ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id='logos'
  AND private.has_permission('tenant.admin')
  AND split_part(name,'/',1)=private.current_organization_id()::text
  AND split_part(name,'/',2)='logos'
)
WITH CHECK (
  bucket_id='logos'
  AND private.has_permission('tenant.admin')
  AND split_part(name,'/',1)=private.current_organization_id()::text
  AND split_part(name,'/',2)='logos'
);
CREATE POLICY logos_admin_delete
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id='logos'
  AND private.has_permission('tenant.admin')
  AND split_part(name,'/',1)=private.current_organization_id()::text
  AND split_part(name,'/',2)='logos'
);

CREATE POLICY productos_imagenes_public_select
ON storage.objects FOR SELECT TO public
USING (bucket_id='imagenes_productos');

CREATE POLICY productos_imagenes_admin_insert
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id='imagenes_productos'
  AND private.has_permission('tenant.admin')
  AND split_part(name,'/',1)=private.current_organization_id()::text
  AND split_part(name,'/',2)='products'
);
CREATE POLICY productos_imagenes_admin_update
ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id='imagenes_productos'
  AND private.has_permission('tenant.admin')
  AND split_part(name,'/',1)=private.current_organization_id()::text
  AND split_part(name,'/',2)='products'
)
WITH CHECK (
  bucket_id='imagenes_productos'
  AND private.has_permission('tenant.admin')
  AND split_part(name,'/',1)=private.current_organization_id()::text
  AND split_part(name,'/',2)='products'
);
CREATE POLICY productos_imagenes_admin_delete
ON storage.objects FOR DELETE TO authenticated
USING (
  bucket_id='imagenes_productos'
  AND private.has_permission('tenant.admin')
  AND split_part(name,'/',1)=private.current_organization_id()::text
  AND split_part(name,'/',2)='products'
);

COMMIT;
