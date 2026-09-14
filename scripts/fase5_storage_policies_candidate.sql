-- Fase 5 - candidato para versionar las policies Storage de StOmni.
--
-- IMPORTANTE:
-- - Este archivo NO es una migracion y no debe ejecutarse en produccion a ciegas.
-- - Cuando el baseline local sea reconstruible, crear la migracion oficial con:
--     supabase migration new reconcile_storage_policies
--   y copiar/revisar este SQL dentro del archivo generado por la CLI.
-- - En produccion las 8 policies ya existen; los bloques siguientes son
--   idempotentes por nombre y no reemplazan una policy existente.

DO $block$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'logos_admin_delete'
  ) THEN
    CREATE POLICY logos_admin_delete
      ON storage.objects
      FOR DELETE
      TO authenticated
      USING (bucket_id = 'logos' AND public.app_es_admin());
  END IF;
END
$block$;

DO $block$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'logos_admin_insert'
  ) THEN
    CREATE POLICY logos_admin_insert
      ON storage.objects
      FOR INSERT
      TO authenticated
      WITH CHECK (bucket_id = 'logos' AND public.app_es_admin());
  END IF;
END
$block$;

DO $block$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'logos_admin_update'
  ) THEN
    CREATE POLICY logos_admin_update
      ON storage.objects
      FOR UPDATE
      TO authenticated
      USING (bucket_id = 'logos' AND public.app_es_admin())
      WITH CHECK (bucket_id = 'logos' AND public.app_es_admin());
  END IF;
END
$block$;

DO $block$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'logos_public_select'
  ) THEN
    CREATE POLICY logos_public_select
      ON storage.objects
      FOR SELECT
      TO public
      USING (bucket_id = 'logos');
  END IF;
END
$block$;

DO $block$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'productos_imagenes_admin_delete'
  ) THEN
    CREATE POLICY productos_imagenes_admin_delete
      ON storage.objects
      FOR DELETE
      TO authenticated
      USING (bucket_id = 'imagenes_productos' AND public.app_es_admin());
  END IF;
END
$block$;

DO $block$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'productos_imagenes_admin_insert'
  ) THEN
    CREATE POLICY productos_imagenes_admin_insert
      ON storage.objects
      FOR INSERT
      TO authenticated
      WITH CHECK (
        bucket_id = 'imagenes_productos' AND public.app_es_admin()
      );
  END IF;
END
$block$;

DO $block$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'productos_imagenes_admin_update'
  ) THEN
    CREATE POLICY productos_imagenes_admin_update
      ON storage.objects
      FOR UPDATE
      TO authenticated
      USING (bucket_id = 'imagenes_productos' AND public.app_es_admin())
      WITH CHECK (
        bucket_id = 'imagenes_productos' AND public.app_es_admin()
      );
  END IF;
END
$block$;

DO $block$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname = 'productos_imagenes_public_select'
  ) THEN
    CREATE POLICY productos_imagenes_public_select
      ON storage.objects
      FOR SELECT
      TO public
      USING (bucket_id = 'imagenes_productos');
  END IF;
END
$block$;

-- Smoke de lectura: deben aparecer exactamente las 8 policies personalizadas
-- que StOmni necesita. Este SELECT no modifica nada.
SELECT
  policyname,
  roles,
  cmd,
  qual,
  with_check
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
ORDER BY policyname;
