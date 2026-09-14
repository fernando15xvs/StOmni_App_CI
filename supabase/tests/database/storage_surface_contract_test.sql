BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(8);

SELECT ok(
  EXISTS (
    SELECT 1 FROM storage.buckets
    WHERE id = 'logos' AND name = 'logos' AND public = true
  ),
  'bucket logos existe y es publico'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM storage.buckets
    WHERE id = 'imagenes_productos'
      AND name = 'imagenes_productos' AND public = true
  ),
  'bucket imagenes_productos existe y es publico'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM storage.buckets
    WHERE id = 'comprobantes-electronicos'
      AND name = 'comprobantes-electronicos' AND public = false
  ),
  'bucket comprobantes-electronicos existe y es privado'
);

SELECT is(
  (
    SELECT count(*)::bigint
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname IN (
        'logos_admin_delete',
        'logos_admin_insert',
        'logos_admin_update',
        'logos_public_select',
        'productos_imagenes_admin_delete',
        'productos_imagenes_admin_insert',
        'productos_imagenes_admin_update',
        'productos_imagenes_public_select'
      )
  ),
  8::bigint,
  'existen las ocho policies Storage requeridas'
);

SELECT is(
  (
    SELECT count(*)::bigint
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname LIKE 'logos_admin_%'
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE')
      AND roles = ARRAY['authenticated']::name[]
      AND lower(coalesce(qual,'') || ' ' || coalesce(with_check,'')) LIKE '%tenant.admin%'
      AND lower(coalesce(qual,'') || ' ' || coalesce(with_check,'')) LIKE '%current_organization_id%'
      AND lower(coalesce(qual,'') || ' ' || coalesce(with_check,'')) LIKE '%split_part%logos%'
  ),
  3::bigint,
  'logos sólo permite mutaciones admin dentro del prefijo del tenant'
);

SELECT is(
  (
    SELECT count(*)::bigint
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname LIKE 'productos_imagenes_admin_%'
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE')
      AND roles = ARRAY['authenticated']::name[]
      AND lower(coalesce(qual,'') || ' ' || coalesce(with_check,'')) LIKE '%tenant.admin%'
      AND lower(coalesce(qual,'') || ' ' || coalesce(with_check,'')) LIKE '%current_organization_id%'
      AND lower(coalesce(qual,'') || ' ' || coalesce(with_check,'')) LIKE '%split_part%products%'
  ),
  3::bigint,
  'imagenes de productos sólo permiten mutaciones admin dentro del prefijo del tenant'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'logos_public_select'
      AND cmd = 'SELECT'
      AND roles = ARRAY['public']::name[]
  ),
  'logos tiene lectura publica explicita'
);

SELECT ok(
  EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'productos_imagenes_public_select'
      AND cmd = 'SELECT'
      AND roles = ARRAY['public']::name[]
  ),
  'imagenes_productos tiene lectura publica explicita'
);

SELECT * FROM finish();

ROLLBACK;
