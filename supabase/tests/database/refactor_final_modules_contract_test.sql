-- Contratos estructurales de los módulos finales del refactor.
-- Ejecutar únicamente contra la base local recreada desde supabase/migrations.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SELECT plan(20);

-- Trazabilidad.
SELECT ok(to_regclass('public.product_traceability_configs') IS NOT NULL,
  'existe configuración de trazabilidad por producto');
SELECT ok(to_regclass('public.inventory_lots') IS NOT NULL,
  'existe inventario por lotes');
SELECT ok(to_regclass('public.inventory_serials') IS NOT NULL,
  'existe inventario por series');
SELECT ok(to_regclass('public.inventory_traceability_consumptions') IS NOT NULL,
  'existe registro idempotente de consumos trazables');
SELECT ok(to_regprocedure('public.get_product_traceability_config_v1(bigint)') IS NOT NULL,
  'existe lectura de configuración trazable');
SELECT ok(to_regprocedure('public.save_product_traceability_config_v1(bigint,bigint,text,boolean)') IS NOT NULL,
  'existe escritura CAS de configuración trazable');
SELECT ok(EXISTS(
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='receive_purchase_order_v2'
  ), 'compras dispone de recepción trazable v2');
SELECT ok(EXISTS(
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname='_resolve_serial_numbers_v1'
  ), 'existe resolución segura de series');

-- Servicios no inventariables.
SELECT ok(EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='productos' AND column_name='es_servicio'
  ), 'productos distingue servicios de mercancía');
SELECT ok(to_regprocedure('public.list_services_v1(boolean)') IS NOT NULL,
  'existe catálogo de servicios');
SELECT ok(to_regprocedure('public.save_service_v1(bigint,text,text,text,numeric,numeric)') IS NOT NULL,
  'existe writer seguro de servicios');
SELECT ok(to_regprocedure('public.deactivate_service_v1(bigint)') IS NOT NULL,
  'existe baja lógica de servicios');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='service_inventory_always_zero' AND NOT tgisinternal),
  'servicios fuerzan inventario a cero');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='service_no_inventory_movements' AND NOT tgisinternal),
  'servicios no generan Kardex');
SELECT ok(EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='service_not_traceable' AND NOT tgisinternal),
  'servicios no admiten lote/serie');

-- Métricas configurables de catálogo cerrado.
SELECT ok(to_regclass('public.business_metric_definitions') IS NOT NULL,
  'existe configuración persistente de métricas');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid='public.business_metric_definitions'::regclass),
  'RLS está habilitada en métricas');
SELECT ok(to_regprocedure('public.list_business_metrics_v1()') IS NOT NULL,
  'existe lectura de métricas');
SELECT ok(to_regprocedure('public.save_business_metrics_v1(jsonb)') IS NOT NULL,
  'existe escritura de métricas');
SELECT ok(NOT has_table_privilege('authenticated','public.business_metric_definitions','UPDATE'),
  'authenticated no puede eludir el writer de métricas');

SELECT * FROM finish();
ROLLBACK;
