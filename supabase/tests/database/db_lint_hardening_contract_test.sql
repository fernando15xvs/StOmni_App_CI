BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(5);

SELECT ok(
  (SELECT provolatile='v'
   FROM pg_proc
   WHERE oid='private.require_current_organization_id()'::regprocedure),
  'require_current_organization_id no se preevalúa fuera del contexto de sesión'
);

SELECT ok(
  (SELECT provolatile='v'
   FROM pg_proc
   WHERE oid='private.require_service_organization_id()'::regprocedure),
  'require_service_organization_id no se preevalúa sin contexto de servicio'
);

SELECT ok(
  to_regprocedure('private.assert_supplier_in_current_organization(bigint)') IS NULL
  AND (SELECT pronargdefaults=1
       FROM pg_proc
       WHERE oid='private.assert_supplier_in_current_organization(bigint,boolean)'::regprocedure),
  'helper proveedor conserva firma extendida con default sin overload ambiguo'
);

SELECT ok(
  position('pg_temp._stomni_bundle_components' IN lower(pg_get_functiondef(
    'public.set_bundle_components_v1(bigint,jsonb)'::regprocedure)))=0
  AND position('with ordinality' IN lower(pg_get_functiondef(
    'public.set_bundle_components_v1(bigint,jsonb)'::regprocedure)))>0,
  'writer de bundles es lintable sin relación temporal runtime'
);

SELECT ok(
  position('sum(v.descuento_global_monto)' IN lower(pg_get_functiondef(
    'public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure)))>0
  AND position('sum(v.descuento)' IN lower(pg_get_functiondef(
    'public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure)))=0
  AND position('feature.analytics' IN lower(pg_get_functiondef(
    'public.get_configurable_dashboard_v1(timestamptz,timestamptz,uuid)'::regprocedure)))>0,
  'dashboard usa descuento autoritativo y conserva gating analytics'
);

SELECT * FROM finish();
ROLLBACK;
