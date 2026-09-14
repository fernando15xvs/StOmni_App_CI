-- Contrato estructural de capacidades tenant-aware.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(13);

SELECT ok(to_regprocedure('public.get_business_profile_v1()') IS NOT NULL, 'existe lectura tipada');
SELECT ok(NOT has_function_privilege('anon', 'public.get_business_profile_v1()', 'EXECUTE'),
  'anónimos no leen capacidades');
SELECT ok(NOT has_function_privilege('anon', 'public.update_business_capabilities_v1(bigint,jsonb)', 'EXECUTE'),
  'anónimos no configuran capacidades');
SELECT ok(NOT has_table_privilege('authenticated', 'public.business_capabilities', 'UPDATE'),
  'no se puede omitir la RPC para cambiar revisión');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid = 'public.business_capabilities'::regclass),
  'RLS habilitada');

SELECT ok(
  position('private.require_current_organization_id()' IN lower(pg_get_functiondef(
    'public.get_business_profile_v1()'::regprocedure))) > 0
  AND position('organization_id=v_org' IN replace(lower(pg_get_functiondef(
    'public.get_business_profile_v1()'::regprocedure)), ' ', '')) > 0,
  'lectura de perfil deriva y filtra el tenant autenticado');

SELECT ok(
  position('private.has_permission(''tenant.admin'')' IN lower(pg_get_functiondef(
    'public.update_business_capabilities_v1(bigint,jsonb)'::regprocedure))) > 0,
  'escritura exige administrador del tenant');
SELECT ok(position('p_expected_revision' IN pg_get_functiondef(
  'public.update_business_capabilities_v1(bigint,jsonb)'::regprocedure)) > 0,
  'escritura verifica versión de configuración');
SELECT ok(
  position('organization_id=v_org' IN replace(lower(pg_get_functiondef(
    'public.update_business_capabilities_v1(bigint,jsonb)'::regprocedure)), ' ', '')) > 0
  AND position('business_id=1' IN replace(lower(pg_get_functiondef(
    'public.update_business_capabilities_v1(bigint,jsonb)'::regprocedure)), ' ', '')) = 0,
  'capabilities se bloquean y actualizan por organization_id');

SELECT ok(
  position('private.current_organization_id()' IN lower(pg_get_functiondef(
    'public._business_services_enabled()'::regprocedure))) > 0
  AND position('private.current_organization_id()' IN lower(pg_get_functiondef(
    'public._business_variants_enabled()'::regprocedure))) > 0,
  'helpers de servicios y variantes resuelven capabilities del tenant');

-- Los triggers conservan la regla de negocio pero dejan de consultar business_id fijo.
SELECT ok(
  position('private.require_current_organization_id()' IN lower(pg_get_functiondef(
    'public._business_enforce_new_sale_capabilities()'::regprocedure))) > 0
  AND position('v_cap.credit_sales' IN lower(pg_get_functiondef(
    'public._business_enforce_new_sale_capabilities()'::regprocedure))) > 0
  AND position('new.saldo' IN lower(pg_get_functiondef(
    'public._business_enforce_new_sale_capabilities()'::regprocedure))) > 0
  AND position('23514' IN pg_get_functiondef(
    'public._business_enforce_new_sale_capabilities()'::regprocedure)) > 0,
  'trigger de venta protege crédito usando capabilities del tenant');
SELECT ok(
  position('v_cap.electronic_invoicing' IN lower(pg_get_functiondef(
    'public._business_enforce_new_sale_capabilities()'::regprocedure))) > 0
  AND position('tipo_comprobante_solicitado' IN lower(pg_get_functiondef(
    'public._business_enforce_new_sale_capabilities()'::regprocedure))) > 0
  AND position('boleta' IN lower(pg_get_functiondef(
    'public._business_enforce_new_sale_capabilities()'::regprocedure))) > 0
  AND position('factura' IN lower(pg_get_functiondef(
    'public._business_enforce_new_sale_capabilities()'::regprocedure))) > 0,
  'trigger de venta/documento protege facturación electrónica del tenant');
SELECT ok(EXISTS(
  SELECT 1 FROM pg_trigger
  WHERE tgname='business_guard_new_sale' AND NOT tgisinternal
) AND EXISTS(
  SELECT 1 FROM pg_trigger
  WHERE tgname='business_guard_new_invoice' AND NOT tgisinternal
), 'ventas y comprobantes conservan triggers de capacidades');

SELECT * FROM finish();
ROLLBACK;
