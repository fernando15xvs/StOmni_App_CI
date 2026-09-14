-- Reconstruct the Storage surface required by StOmni on a fresh Supabase project.
-- Existing buckets/policies are preserved; this migration only fills missing pieces.
BEGIN;

INSERT INTO storage.buckets (id, name, public)
VALUES
  ('logos', 'logos', true),
  ('imagenes_productos', 'imagenes_productos', true),
  ('comprobantes-electronicos', 'comprobantes-electronicos', false)
ON CONFLICT (id) DO NOTHING;

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
      WITH CHECK (bucket_id = 'imagenes_productos' AND public.app_es_admin());
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
      WITH CHECK (bucket_id = 'imagenes_productos' AND public.app_es_admin());
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

COMMIT;
