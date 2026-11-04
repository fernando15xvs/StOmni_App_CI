-- 2D-E: restore SaaS tenant isolation to the product natural-key indexes.
-- Legacy globally unique indexes were preventing different organizations from
-- registering identical product names/codes and customer DNI/RUC. Global surrogate product ID remains
-- a primary key; catalog business identifiers must be unique PER organization.
DO $guard$
BEGIN
 IF NOT EXISTS (
   SELECT 1 FROM pg_constraint c
   WHERE c.conrelid='public.productos'::regclass
     AND c.conname='productos_organization_id_not_null'
 ) AND EXISTS(
   SELECT 1 FROM information_schema.columns
   WHERE table_schema='public' AND table_name='productos'
     AND column_name='organization_id' AND is_nullable='YES'
 ) THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Product organization_id must be NOT NULL before changing unique indexes';
 END IF;
 IF NOT EXISTS(
   SELECT 1 FROM pg_indexes
   WHERE schemaname='public' AND tablename='productos'
     AND indexname='productos_organization_code_key'
     AND indexdef LIKE '%UNIQUE INDEX%'
 ) THEN
   RAISE EXCEPTION USING ERRCODE='23514',
     MESSAGE='Tenant scoped unique product code index is required before removing global code index';
 END IF;
END $guard$;

DROP INDEX IF EXISTS public.idx_producto_unico;
CREATE UNIQUE INDEX idx_producto_unico
  ON public.productos USING btree (
    organization_id, lower(btrim(nombre)),
    coalesce(proveedor_id,(0)::bigint), tipo_venta
  );

-- Existing productos_organization_code_key already enforces normalized
-- codigo uniqueness within an organization; remove duplicate GLOBAL gate.
DROP INDEX IF EXISTS public.productos_codigo_unique;

-- A customer document (DNI/RUC) also identifies a person across businesses:
-- each tenant may legitimately have the same customer. Preserve per-tenant
-- uniqueness and remove only the superseded legacy global index.
DO $customer_guard$
BEGIN
 IF NOT EXISTS (
  SELECT 1 FROM pg_indexes
  WHERE schemaname='public' AND tablename='clientes'
    AND indexname='clientes_organization_document_key'
    AND indexdef LIKE '%UNIQUE INDEX%'
 ) THEN
  RAISE EXCEPTION USING ERRCODE='23514',
    MESSAGE='Tenant scoped customer document uniqueness must exist';
 END IF;
END $customer_guard$;
DROP INDEX IF EXISTS public.clientes_dni_ruc_unique;
