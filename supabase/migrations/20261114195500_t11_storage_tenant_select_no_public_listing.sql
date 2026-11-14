-- T11: public asset URLs must not make storage.objects metadata enumerable.
-- The SaaS runtime reconciliation intentionally kept buckets public, but
-- reintroduced public SELECT policies that also authorized Storage LIST.
-- Public object URLs use the public bucket flag; authenticated LIST/GET must
-- still enforce membership and the object path's organization UUID.
BEGIN;

DROP POLICY IF EXISTS logos_public_select ON storage.objects;
DROP POLICY IF EXISTS productos_imagenes_public_select ON storage.objects;

DROP POLICY IF EXISTS logos_tenant_select ON storage.objects;
CREATE POLICY logos_tenant_select
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'logos'
  AND private.has_permission('tenant.read')
  AND split_part(name, '/', 1) = private.current_organization_id()::text
  AND split_part(name, '/', 2) = 'logos'
);

DROP POLICY IF EXISTS productos_imagenes_tenant_select ON storage.objects;
CREATE POLICY productos_imagenes_tenant_select
ON storage.objects FOR SELECT TO authenticated
USING (
  bucket_id = 'imagenes_productos'
  AND private.has_permission('tenant.read')
  AND split_part(name, '/', 1) = private.current_organization_id()::text
  AND split_part(name, '/', 2) = 'products'
);

-- These two buckets intentionally remain public for direct asset URLs.
-- DELETE/UPDATE/INSERT continue using the existing tenant-admin policies.
DO $check$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM storage.buckets
    WHERE id = 'logos' AND public IS TRUE
  ) OR NOT EXISTS (
    SELECT 1 FROM storage.buckets
    WHERE id = 'imagenes_productos' AND public IS TRUE
  ) THEN
    RAISE EXCEPTION 'T11: public asset bucket contract changed unexpectedly';
  END IF;
END;
$check$;

COMMIT;
