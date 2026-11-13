-- 2D-H: privilege ceilings captured on DEV after migration 20261105030000.
-- Removing access is allowed. Adding a signature requires an isolation review
-- and a deliberate update here. Existing entries still need behavioral tests.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions, pg_catalog;
SELECT plan(2);

CREATE TEMP VIEW privileged_api AS
SELECT p.oid::regprocedure::text AS signature,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS anonymous_access,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS signed_in_access
FROM pg_catalog.pg_proc AS p
WHERE p.pronamespace = 'public'::regnamespace AND p.prosecdef;

SELECT is_empty(
  $$SELECT signature FROM privileged_api WHERE anonymous_access$$,
  'Anonymous role has no executable public SECURITY DEFINER routine'
);

SELECT is_empty(
  $$SELECT signature FROM privileged_api WHERE signed_in_access
    EXCEPT
    SELECT unnest(ARRAY[
      '_gre_empleado_activo()',
      'acknowledge_operational_alert_v1(uuid)',
      'actualizar_configuracion_negocio_v1(jsonb)',
      'actualizar_cotizaciones_vencidas()',
      'actualizar_producto_seguro_v1(bigint,jsonb,boolean)',
      'ajustar_stock_scaled_v2(bigint,bigint,numeric,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric)',
      'anular_venta_v2(bigint,text)',
      'app_tiene_permiso(text)',
      'cancel_purchase_order_v1(bigint,text)',
      'complete_my_onboarding_step_v1(bigint,text)',
      'crear_nota_credito_with_units_v3(uuid,uuid,text,text,jsonb,numeric,boolean,timestamp with time zone)',
      'crear_producto_con_stock(uuid,jsonb,jsonb)',
      'create_branch_v1(text,text,text)',
      'create_cash_register_v1(uuid,text,text)',
      'create_my_organization_v1(text,text,text,text,text)',
      'create_operational_task_v1(text,text,timestamp with time zone,text)',
      'create_purchase_order_v1(uuid,bigint,bigint,timestamp with time zone,timestamp with time zone,text,jsonb)',
      'create_role_v1(text,text,text[])',
      'deactivate_service_v1(bigint)',
      'delete_product_variant_group_v1(bigint)',
      'delete_sale_price_rule_v1(bigint)',
      'eliminar_borrador_guia_v1(uuid)',
      'eliminar_cotizacion_v2(bigint)',
      'eliminar_gasto_v1(bigint)',
      'eliminar_pago_empleado_v1(bigint)',
      'eliminar_pago_gasto_v1(bigint,bigint)',
      'eliminar_pago_venta_v1(bigint,bigint)',
      'eliminar_producto_seguro_v1(bigint)',
      'evaluar_eliminacion_producto_v1(bigint)',
      'get_bundle_components_v1(bigint)',
      'get_business_assistant_context_v1(text,integer,uuid,integer)',
      'get_business_assistant_settings_v1()',
      'get_business_profile_v1()',
      'get_configurable_dashboard_v1(timestamp with time zone,timestamp with time zone,uuid)',
      'get_current_business_configuration_v1()',
      'get_dashboard_summary(timestamp with time zone,timestamp with time zone)',
      'get_employee_permission_settings_v1(bigint)',
      'get_estado_caja_chica()',
      'get_my_billing_summary_v1()',
      'get_my_effective_permissions_v1()',
      'get_my_entitlements_v1()',
      'get_my_onboarding_progress_v1()',
      'get_my_subscription_v1()',
      'get_observability_metrics_v1(integer)',
      'get_operational_alert_settings_v1()',
      'get_organization_signup_state_v1()',
      'get_product_traceability_config_v1(bigint)',
      'get_product_unit_profiles_v1(bigint[])',
      'get_user_role()',
      'guardar_cotizacion_v2(uuid,bigint,numeric,timestamp with time zone,text,integer,jsonb)',
      'guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamp with time zone,text,integer,jsonb)',
      'guardar_guia_remision_v4(uuid,uuid,boolean,text,text,bigint,bigint,uuid,text,text,text,text,text,timestamp with time zone,timestamp with time zone,jsonb,jsonb,jsonb,jsonb,bigint,bigint,bigint,numeric,integer,boolean,text,jsonb,boolean,bigint,bigint,bigint,text)',
      'list_audit_logs_v1(integer,bigint,text,text)',
      'list_my_organization_memberships_v1()',
      'list_business_metrics_v1()',
      'list_custom_field_definitions_v1(text,boolean)',
      'list_operational_alerts_v1(text,integer)',
      'list_product_variant_groups_v1()',
      'list_purchase_orders_v1(text,integer)',
      'list_recent_observability_errors_v1(integer)',
      'list_sale_price_rules_v1()',
      'list_services_v1(boolean)',
      'list_subscription_plans_v1()',
      'listar_documentos_electronicos_v1(timestamp with time zone,timestamp with time zone,integer,integer)',
      'obtener_disponibilidad_nota_credito_v2(uuid)',
      'obtener_tendencia_movimientos(text,timestamp with time zone,timestamp with time zone)',
      'procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)',
      'process_sale_credit_v5(uuid,bigint,numeric,timestamp with time zone,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint,jsonb)',
      'process_sale_v4(uuid,bigint,numeric,timestamp with time zone,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)',
      'process_sale_with_units_v4(uuid,bigint,numeric,timestamp with time zone,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)',
      'receive_purchase_order_v2(uuid,bigint,timestamp with time zone,text,text,jsonb)',
      'refresh_operational_alerts_v1()',
      'register_traceable_merchandise_receipt_v1(uuid,bigint,bigint,numeric,timestamp with time zone,text,text,bigint,text,numeric,numeric,numeric,numeric,jsonb)',
      'registrar_gasto_mixto(bigint,text,numeric,text,timestamp with time zone,jsonb)',
      'registrar_ingreso_mercaderia_scaled_v2(uuid,bigint,timestamp with time zone,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric)',
      'registrar_merma_scaled_v4(uuid,bigint,bigint,numeric,text,timestamp with time zone,jsonb)',
      'registrar_pago_empleado_mixto(bigint,text,timestamp with time zone,jsonb)',
      'resolve_operational_alert_v1(uuid)',
      'resolve_sale_price_v1(bigint,text,numeric,timestamp with time zone)',
      'save_business_metrics_v1(jsonb)',
      'save_product_traceability_config_v1(bigint,bigint,text,boolean)',
      'save_product_unit_profile_v6(bigint,bigint,jsonb)',
      'save_product_variant_group_v1(bigint,text,jsonb,jsonb)',
      'save_sale_price_rule_v1(bigint,text,bigint,text,numeric,numeric,numeric,integer,timestamp with time zone,timestamp with time zone,boolean)',
      'save_service_v1(bigint,text,text,text,numeric,numeric)',
      'set_bundle_components_v1(bigint,jsonb)',
      'set_catalog_item_type_v1(bigint,text)',
      'set_default_cash_register_v1(uuid)',
      'set_employee_roles_v1(bigint,uuid[])',
      'set_entity_custom_fields_v1(text,bigint,jsonb)',
      'set_main_branch_v1(uuid)',
      'set_role_permissions_v1(uuid,text[])',
      'solicitar_baja_tributaria_v1(uuid,text,uuid,text)',
      'trasladar_stock_scaled_v4(uuid,bigint,bigint,bigint,numeric,text,timestamp with time zone,jsonb)',
      'trasladar_stock(bigint,bigint,bigint,integer,text,text)',
      'update_branch_v1(uuid,text,text,text)',
      'update_business_assistant_settings_v1(bigint,boolean,integer,integer)',
      'update_business_capabilities_v1(bigint,jsonb)',
      'update_cash_register_v1(uuid,text,text)',
      'update_employee_permission_overrides_v1(bigint,jsonb)',
      'update_operational_alert_settings_v1(bigint,jsonb)',
      'upsert_custom_field_definition_v1(uuid,text,text,text,text,boolean,text[],jsonb,jsonb,integer,text)'
    ]::text[])$$,
  'Authenticated role has no unreviewed expansion of the 2D-G privilege surface'
);

SELECT * FROM finish();
ROLLBACK;
