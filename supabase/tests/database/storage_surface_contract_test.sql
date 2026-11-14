BEGIN;

CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

SELECT plan(11);

SELECT ok(
  EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'logos' AND public IS TRUE),
  'logos sigue siendo publico por URL, no por SELECT SQL global'
);

SELECT ok(
  EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'imagenes_productos' AND public IS TRUE),
  'imagenes_productos sigue siendo publico por URL'
);

SELECT ok(
  EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'comprobantes-electronicos' AND public IS FALSE),
  'comprobantes-electronicos permanece privado'
);

SELECT is(
  (SELECT count(*)::bigint FROM pg_policies
   WHERE schemaname='storage' AND tablename='objects'
     AND policyname IN ('logos_public_select','productos_imagenes_public_select')),
  0::bigint,
  'ninguna policy legada permite listar metadata publicamente'
);

SELECT is(
  (SELECT count(*)::bigint FROM pg_policies
   WHERE schemaname='storage' AND tablename='objects'
     AND policyname IN ('logos_tenant_select','productos_imagenes_tenant_select')
     AND cmd = 'SELECT'
     AND roles = ARRAY['authenticated']::name[]),
  2::bigint,
  'las dos lecturas Storage exigen rol authenticated'
);

SELECT is(
  (SELECT count(*)::bigint FROM pg_policies
   WHERE schemaname='storage' AND tablename='objects'
     AND policyname IN ('logos_tenant_select','productos_imagenes_tenant_select')
     AND lower(coalesce(qual,'')) LIKE '%tenant.read%'
     AND lower(coalesce(qual,'')) LIKE '%current_organization_id%'
     AND lower(coalesce(qual,'')) LIKE '%split_part%'
     AND (
       (policyname='logos_tenant_select' AND qual LIKE '%logos%')
       OR (policyname='productos_imagenes_tenant_select' AND qual LIKE '%imagenes_productos%')
     )),
  2::bigint,
  'ambos SELECT usan permisos y UUID del tenant en la ruta'
);

SELECT is(
  (SELECT count(*)::bigint FROM pg_policies
   WHERE schemaname='storage' AND tablename='objects'
     AND policyname IN ('logos_admin_insert','logos_admin_update','logos_admin_delete')
     AND cmd IN ('INSERT','UPDATE','DELETE')
     AND roles = ARRAY['authenticated']::name[]
     AND lower(coalesce(qual,'') || ' ' || coalesce(with_check,'')) LIKE '%tenant.admin%'
     AND lower(coalesce(qual,'') || ' ' || coalesce(with_check,'')) LIKE '%current_organization_id%'
     AND lower(coalesce(qual,'') || ' ' || coalesce(with_check,'')) LIKE '%split_part%logos%'),
  3::bigint,
  'mutaciones de logos exigen admin y namespace del tenant'
);

SELECT is(
  (SELECT count(*)::bigint FROM pg_policies
   WHERE schemaname='storage' AND tablename='objects'
     AND policyname IN ('productos_imagenes_admin_insert',
                        'productos_imagenes_admin_update',
                        'productos_imagenes_admin_delete')
     AND cmd IN ('INSERT','UPDATE','DELETE')
     AND roles = ARRAY['authenticated']::name[]
     AND lower(coalesce(qual,'') || ' ' || coalesce(with_check,'')) LIKE '%tenant.admin%'
     AND lower(coalesce(qual,'') || ' ' || coalesce(with_check,'')) LIKE '%current_organization_id%'
     AND lower(coalesce(qual,'') || ' ' || coalesce(with_check,'')) LIKE '%split_part%products%'),
  3::bigint,
  'mutaciones de imagenes exigen admin y namespace del tenant'
);

SELECT ok(
  (SELECT relrowsecurity FROM pg_class WHERE oid='storage.objects'::regclass),
  'storage.objects mantiene RLS activo'
);

SELECT is(
  (SELECT count(*)::bigint FROM pg_policies
   WHERE schemaname='storage' AND tablename='objects'
     AND cmd IN ('SELECT','ALL')
     AND roles = ARRAY['public']::name[]
     AND (lower(coalesce(qual,'')) LIKE '%bucket_id%logos%'
       OR lower(coalesce(qual,'')) LIKE '%bucket_id%imagenes_productos%')),
  0::bigint,
  'ninguna lectura publica por SQL habilita enumeracion de assets'
);

SELECT is(
  (SELECT count(*)::bigint FROM pg_policies
   WHERE schemaname='storage' AND tablename='objects'
     AND cmd IN ('SELECT','ALL')
     AND roles = ARRAY['public']::name[]
     AND lower(coalesce(qual,'')) LIKE '%comprobantes-electronicos%'),
  0::bigint,
  'documentos fiscales no tienen policy publica'
);

SELECT * FROM finish();

ROLLBACK;
