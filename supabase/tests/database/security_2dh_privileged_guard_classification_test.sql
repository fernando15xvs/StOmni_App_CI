-- 2D-H: guard taxonomy for 101 original plus 1 reviewed membership-list RPC.
-- This is static gate evidence; it does not replace behavioral tenant tests.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path=public,extensions,pg_catalog;
SELECT plan(11);
CREATE TEMP VIEW _2dh_rpc_classes AS
WITH rpc AS (
 SELECT p.oid,p.oid::regprocedure::text signature,p.proconfig,
   pg_get_functiondef(p.oid) body
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.prosecdef AND has_function_privilege('authenticated',p.oid,'EXECUTE')
)
SELECT signature,proconfig,body,
 CASE
   WHEN body ~* 'private\.require_current_organization_id' THEN 'STRICT_ORG'
   WHEN body ~* 'private\.has_permission|public\.app_tiene_permiso|private\.assert_' THEN 'PERMISSION_OR_ASSERT'
   WHEN body ~* 'private\.current_organization_id|public\.app_empleado_activo|auth.uid' THEN 'CONTEXT_AUTH'
   WHEN body ~* 'public\._legacy|public\.trasladar_stock_v2|private\.' THEN 'DELEGATED'
   ELSE 'PUBLIC_OR_UNGUARDED'
 END AS guard_class
FROM rpc;
SELECT is((SELECT count(*)::int FROM _2dh_rpc_classes),102,'Privileged API inventory remains explicit at 102');
SELECT is((SELECT count(*)::int FROM _2dh_rpc_classes WHERE guard_class='STRICT_ORG'),75,'75 RPCs directly require privileged active-tenant context');
SELECT is((SELECT count(*)::int FROM _2dh_rpc_classes WHERE guard_class='PERMISSION_OR_ASSERT'),20,'20 RPCs use explicit permission or ownership assertions');
SELECT is((SELECT count(*)::int FROM _2dh_rpc_classes WHERE guard_class='CONTEXT_AUTH'),5,'Five deliberately scoped identity and bootstrap endpoints');
SELECT is((SELECT count(*)::int FROM _2dh_rpc_classes WHERE guard_class='DELEGATED'),1,'Single legacy transfer delegates to guarded v2 writer');
SELECT is_empty($q$SELECT signature FROM _2dh_rpc_classes
 WHERE guard_class='PUBLIC_OR_UNGUARDED'
 AND signature <> 'list_subscription_plans_v1()'$q$,
 'No unreviewed privileged routine without tenant or delegated guard');
SELECT ok(
 pg_get_functiondef('public.list_subscription_plans_v1()'::regprocedure)
   ILIKE '%p.is_public%'
 AND pg_get_functiondef('public.list_subscription_plans_v1()'::regprocedure)
   ILIKE '%p.status=%',
 'Public catalog exposes only publicly enabled subscription plans');
SELECT is_empty($q$SELECT signature FROM _2dh_rpc_classes
 WHERE proconfig IS NULL OR NOT EXISTS(
 SELECT 1 FROM unnest(proconfig) x WHERE x LIKE 'search_path=%'
 )$q$, 'All exposed privileged SQL sets a search_path');
SELECT ok(
 NOT has_schema_privilege('anon','public','CREATE')
 AND NOT has_schema_privilege('authenticated','public','CREATE'),
 'Client roles cannot inject objects into public search path');
SELECT ok(
 pg_get_functiondef('public.trasladar_stock_v2(uuid,bigint,bigint,bigint,integer,text,timestamp with time zone)'::regprocedure)
 ILIKE '%private.require_current_organization_id%'
 AND NOT has_function_privilege('anon','public.trasladar_stock(bigint,bigint,bigint,integer,text,text)','EXECUTE'),
 'Legacy stock transfer delegates to guarded v2');
SELECT ok(
 pg_get_functiondef('private.require_current_organization_id()'::regprocedure)
 ILIKE '%private.has_permission%'
 AND pg_get_functiondef('private.has_permission(text)'::regprocedure)
 ILIKE '%COALESCE%',
 'Central tenant context and permissions both fail closed');
SELECT * FROM finish();
ROLLBACK;
