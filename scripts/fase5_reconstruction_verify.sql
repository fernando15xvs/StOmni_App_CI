-- Fase 5 - verificacion SOLO LECTURA de una reconstruccion Supabase local.
--
-- Uso recomendado para comparar contra el estado productivo auditado:
--   supabase db reset --local --no-seed --version 20260821191000
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f scripts/fase5_reconstruction_verify.sql
--
-- 20260821191000 incluye el fix de alertas de stock que ya esta activo en
-- produccion aunque no figure en schema_migrations remoto. No ejecutar este
-- script como sustituto del dump/baseline: sirve para verificar el resultado.

\set ON_ERROR_STOP on

SELECT current_database() AS database_name,
       current_setting('server_version') AS server_version;

WITH actual AS (
  SELECT 'public_tables'::text AS check_name, count(*)::bigint AS value
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r'

  UNION ALL
  SELECT 'public_views', count(*)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('v', 'm')

  UNION ALL
  SELECT 'public_functions', count(*)
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'

  UNION ALL
  SELECT 'public_user_triggers', count(*)
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT t.tgisinternal

  UNION ALL
  SELECT 'public_policies', count(*)
  FROM pg_policies
  WHERE schemaname = 'public'

  UNION ALL
  SELECT 'public_indexes', count(*)
  FROM pg_indexes
  WHERE schemaname = 'public'

  UNION ALL
  SELECT 'public_tables_rls_enabled', count(*)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND c.relrowsecurity
), expected(check_name, value) AS (
  VALUES
    ('public_tables'::text, 44::bigint),
    ('public_views', 2),
    ('public_functions', 74),
    ('public_user_triggers', 16),
    ('public_policies', 58),
    ('public_indexes', 145),
    ('public_tables_rls_enabled', 44)
)
SELECT
  e.check_name,
  e.value AS expected,
  a.value AS actual,
  a.value = e.value AS ok
FROM expected e
LEFT JOIN actual a USING (check_name)
ORDER BY e.check_name;

-- Las versiones concretas de las extensiones pueden variar según la imagen
-- local de Supabase. Se verifica presencia/capacidad, no version pinning.
WITH required(extname) AS (
  VALUES
    ('pg_cron'::text),
    ('pg_net'),
    ('pg_stat_statements'),
    ('pgcrypto'),
    ('supabase_vault'),
    ('uuid-ossp')
)
SELECT
  r.extname,
  e.extversion,
  n.nspname AS schema_name,
  e.oid IS NOT NULL AS ok
FROM required r
LEFT JOIN pg_extension e ON e.extname = r.extname
LEFT JOIN pg_namespace n ON n.oid = e.extnamespace
ORDER BY r.extname;

WITH required(policyname) AS (
  VALUES
    ('logos_admin_delete'::text),
    ('logos_admin_insert'),
    ('logos_admin_update'),
    ('logos_public_select'),
    ('productos_imagenes_admin_delete'),
    ('productos_imagenes_admin_insert'),
    ('productos_imagenes_admin_update'),
    ('productos_imagenes_public_select')
)
SELECT
  r.policyname,
  p.roles,
  p.cmd,
  p.qual,
  p.with_check,
  p.policyname IS NOT NULL AS ok
FROM required r
LEFT JOIN pg_policies p
  ON p.schemaname = 'storage'
 AND p.tablename = 'objects'
 AND p.policyname = r.policyname
ORDER BY r.policyname;

-- Fallar de forma explicita si la huella productiva auditada no coincide.
DO $verify$
DECLARE
  v_tables bigint;
  v_views bigint;
  v_functions bigint;
  v_triggers bigint;
  v_policies bigint;
  v_indexes bigint;
  v_rls bigint;
  v_missing_extensions bigint;
  v_missing_storage_policies bigint;
BEGIN
  SELECT count(*) INTO v_tables
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r';

  SELECT count(*) INTO v_views
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind IN ('v', 'm');

  SELECT count(*) INTO v_functions
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public';

  SELECT count(*) INTO v_triggers
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND NOT t.tgisinternal;

  SELECT count(*) INTO v_policies
  FROM pg_policies WHERE schemaname = 'public';

  SELECT count(*) INTO v_indexes
  FROM pg_indexes WHERE schemaname = 'public';

  SELECT count(*) INTO v_rls
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity;

  SELECT count(*) INTO v_missing_extensions
  FROM (VALUES
    ('pg_cron'::text), ('pg_net'), ('pg_stat_statements'),
    ('pgcrypto'), ('supabase_vault'), ('uuid-ossp')
  ) required(extname)
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_extension e WHERE e.extname = required.extname
  );

  SELECT count(*) INTO v_missing_storage_policies
  FROM (VALUES
    ('logos_admin_delete'::text),
    ('logos_admin_insert'),
    ('logos_admin_update'),
    ('logos_public_select'),
    ('productos_imagenes_admin_delete'),
    ('productos_imagenes_admin_insert'),
    ('productos_imagenes_admin_update'),
    ('productos_imagenes_public_select')
  ) required(policyname)
  WHERE NOT EXISTS (
    SELECT 1
    FROM pg_policies p
    WHERE p.schemaname = 'storage'
      AND p.tablename = 'objects'
      AND p.policyname = required.policyname
  );

  IF v_tables <> 44
     OR v_views <> 2
     OR v_functions <> 74
     OR v_triggers <> 16
     OR v_policies <> 58
     OR v_indexes <> 145
     OR v_rls <> 44
     OR v_missing_extensions <> 0
     OR v_missing_storage_policies <> 0 THEN
    RAISE EXCEPTION
      'Fase 5 reconstruction mismatch: tables %, views %, functions %, triggers %, policies %, indexes %, rls %, missing extensions %, missing storage policies %',
      v_tables, v_views, v_functions, v_triggers, v_policies, v_indexes,
      v_rls, v_missing_extensions, v_missing_storage_policies;
  END IF;
END
$verify$;

SELECT 'FASE5_PRODUCTION_FINGERPRINT_OK' AS result;
