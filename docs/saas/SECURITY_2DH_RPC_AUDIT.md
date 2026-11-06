# Auditoría RPC 2D-H

Inventario obtenido de Supabase DEV `iqooedpkihmzkmynsisl` el 5 de noviembre de 2026 (America/Lima). Se seleccionaron las funciones `SECURITY DEFINER` de `public` con ejecución concedida a `authenticated`. Total observado, 101 firmas.

La columna de evidencia identifica pruebas de ejecución autenticada entre empresas con permisos distintos. Los contratos financieros y estáticos existentes complementan esa evidencia. Cada fila pendiente requiere revisar el cuerpo, sus auxiliares y pruebas de comportamiento antes de cerrar la auditoría.

## Hallazgo de cajas

`update_cash_register_v1` consultaba las sesiones abiertas por identificador de caja antes de comprobar la empresa. Un administrador de A recibía `23514` si una caja de B tenía sesión abierta y `P0002` para una caja inexistente. La diferencia revelaba el estado de una caja ajena.

La corrección selecciona y bloquea primero la caja de la empresa actual. La consulta de sesiones incluye explícitamente `organization_id`. El conjunto nuevo reproduce un fallo de 23 en la versión anterior y pasa 23/23 con la corrección temporal dentro de una transacción revertida. El despliegue persistente se completó el 6 de noviembre de 2026 (America/Lima), después del [CI 42145855852](https://github.com/fernando15xvs/StOmni_App_CI/actions/runs/42145855852) con 7/7 trabajos aprobados. Candidato privado `7ca6ee50b00e94ef4f1abb44058044d1f08f1b59` y espejo `6f4bf584ce4afbd5afc707dc49129340ff22724b`. DEV registra la versión canónica `20261106014224`. Después de aplicar la migración pasaron 23/23 pruebas nuevas y 42/42 comprobaciones existentes de sucursales, cajas y superficie privilegiada. El cuerpo instalado coincide con el candidato.

En la inspección común del inventario, las 101 funciones fijan `search_path`. Los roles `authenticated` y `anon` carecen de CREATE en el esquema `public`. Continúa pendiente la revisión individual de los cuerpos y sus auxiliares señalados en la matriz.

## Catálogo, variantes y precios

El 6 de noviembre de 2026 se revisaron nueve puntos de entrada de paquetes, tipos de catálogo, variantes y reglas de precios. El contrato `security_2dh_catalog_operations_test.sql` pasó **57/57 comprobaciones en DEV** dentro de una transacción revertida. Cubre lecturas y escrituras entre empresas, listados filtrados, administrador y operador, ausencia de membresía, creación y modificación válidas, borrado local y conservación de datos de la empresa ajena.

La sustitución de componentes con un lote mixto rechaza el componente ajeno mediante `private.validate_bundle_component` y revierte la eliminación previa de la composición original. Las variantes validan cada miembro antes de entrar al escritor heredado. Las reglas de precios validan tanto el producto como la regla existente. Los siete auxiliares públicos heredados y de serialización revisados carecen de EXECUTE para `anon` y `authenticated`; el contrato comprueba ese límite de acceso.

Este bloque añade pruebas y evidencia de las rutas revisadas. La validación del candidato en CI queda pendiente al momento de este commit. La matriz conserva pendientes las demás firmas.

## Alertas operativas y cierre por empleo activo (6 de noviembre de 2026)

Se revisaron siete RPC autenticadas de alertas, tareas y configuración: `acknowledge_operational_alert_v1`, `resolve_operational_alert_v1`, `create_operational_task_v1`, `get_operational_alert_settings_v1`, `list_operational_alerts_v1`, `refresh_operational_alerts_v1` y `update_operational_alert_settings_v1`. Todos los accesos y mutaciones de registros emplean `organization_id` de la membresía actual; resolución de alertas, tareas y configuración requieren `tenant.admin`, mientras que consulta, confirmación y actualización del inbox exigen `tenant.read`. El auxiliar `private.refresh_operational_alerts_for_org` consulta las fuentes y resuelve alertas por la organización explícita; `private.upsert_operational_alert` usa la clave única compuesta `(organization_id,dedup_key)`. Ambos auxiliares privados carecen de EXECUTE para `anon` y `authenticated`.

**Fallo reproducido y corregido.** En la versión previa, `private.current_base_role()` comprobaba `app_users` y `organizations`, pero no el empleo activo. Además, `private.has_permission()` devolvía `NULL` si no había rol. Los llamadores que usaban `IF NOT private.has_permission(...) THEN RAISE` omitían la denegación cuando recibían `NULL`, por la lógica ternaria de PL/pgSQL. Un empleado desactivado retenía acceso a RPC de alertas: tres pruebas negativas fallaron reproduciendo el acceso. La migración `20261106231519_security_2dh_active_employee_permission_gate.sql` obliga a `empleados.activo IS TRUE` y `empleados.employment_status='active'` dentro de `private.current_base_role()`, y normaliza a **false** cualquier valor nulo de `private.has_permission()`. Preserva firmas y contratos de administradores y operadores activos.

**Validación DEV:** `security_2dh_operational_alerts_and_active_employment_test.sql` pasó **41/41 pruebas reversibles**: dos empresas, roles admin/operador, consulta y modificaciones propias, identificadores ajenos, permisos insuficientes, ausencia de membresía, revisión optimista, tareas, refresh y denegación tras inactivar `activo` o `employment_status`. El código instalado de ambos helpers se verificó en Supabase DEV `iqooedpkihmzkmynsisl`, sin conservar fixtures. Pendiente certificar el nuevo candidato en GitHub Actions y completar el resto de las 101 firmas. Esta corrección no se aplicó a producción.

## Matriz de seguimiento

| Firma | Evidencia de comportamiento / siguiente revisión |
|---|---|
| `_gre_empleado_activo()` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `acknowledge_operational_alert_v1(uuid)` | Cuerpo, pertenencia y auxiliares revisados. Pruebas de ejecución autenticada en `security_2dh_operational_alerts_and_active_employment_test.sql` (41 aserciones compartidas), incluido rechazo por empleo inactivo. |
| `actualizar_configuracion_negocio_v1(jsonb)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `actualizar_cotizaciones_vencidas()` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `actualizar_producto_seguro_v1(bigint,jsonb,boolean)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `ajustar_stock_scaled_v2(bigint,bigint,numeric,text,text,numeric,numeric,numeric,numeric,text,numeric,numeric)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `anular_venta_v2(bigint,text)` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `app_tiene_permiso(text)` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `cancel_purchase_order_v1(bigint,text)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `complete_my_onboarding_step_v1(bigint,text)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `crear_nota_credito_with_units_v3(uuid,uuid,text,text,jsonb,numeric,boolean,timestamp with time zone)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `crear_producto_con_stock(uuid,jsonb,jsonb)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `create_branch_v1(text,text,text)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `create_cash_register_v1(uuid,text,text)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `create_my_organization_v1(text,text,text,text,text)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `create_operational_task_v1(text,text,timestamp with time zone,text)` | Cuerpo, pertenencia y auxiliares revisados. Pruebas de ejecución autenticada en `security_2dh_operational_alerts_and_active_employment_test.sql` (41 aserciones compartidas), incluido rechazo por empleo inactivo. |
| `create_purchase_order_v1(uuid,bigint,bigint,timestamp with time zone,timestamp with time zone,text,jsonb)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `create_role_v1(text,text,text[])` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `deactivate_service_v1(bigint)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `delete_product_variant_group_v1(bigint)` | Cuerpo y auxiliares revisados para aislamiento y permisos. Casos de ejecución en `security_2dh_catalog_operations_test.sql` (57 aserciones en conjunto). |
| `delete_sale_price_rule_v1(bigint)` | Cuerpo y auxiliares revisados para aislamiento y permisos. Casos de ejecución en `security_2dh_catalog_operations_test.sql` (57 aserciones en conjunto). |
| `eliminar_borrador_guia_v1(uuid)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `eliminar_cotizacion_v2(bigint)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `eliminar_gasto_v1(bigint)` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `eliminar_pago_empleado_v1(bigint)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `eliminar_pago_gasto_v1(bigint,bigint)` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `eliminar_pago_venta_v1(bigint,bigint)` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `eliminar_producto_seguro_v1(bigint)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `evaluar_eliminacion_producto_v1(bigint)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `get_bundle_components_v1(bigint)` | Cuerpo y auxiliares revisados para aislamiento y permisos. Casos de ejecución en `security_2dh_catalog_operations_test.sql` (57 aserciones en conjunto). |
| `get_business_assistant_context_v1(text,integer,uuid,integer)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `get_business_assistant_settings_v1()` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `get_business_profile_v1()` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `get_configurable_dashboard_v1(timestamp with time zone,timestamp with time zone,uuid)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `get_current_business_configuration_v1()` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `get_dashboard_summary(timestamp with time zone,timestamp with time zone)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `get_employee_permission_settings_v1(bigint)` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `get_estado_caja_chica()` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `get_my_billing_summary_v1()` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `get_my_effective_permissions_v1()` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `get_my_entitlements_v1()` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `get_my_onboarding_progress_v1()` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `get_my_subscription_v1()` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `get_observability_metrics_v1(integer)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `get_operational_alert_settings_v1()` | Cuerpo, pertenencia y auxiliares revisados. Pruebas de ejecución autenticada en `security_2dh_operational_alerts_and_active_employment_test.sql` (41 aserciones compartidas), incluido rechazo por empleo inactivo. |
| `get_organization_signup_state_v1()` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `get_product_traceability_config_v1(bigint)` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `get_product_unit_profiles_v1(bigint[])` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `get_user_role()` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `guardar_cotizacion_v2(uuid,bigint,numeric,timestamp with time zone,text,integer,jsonb)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `guardar_cotizacion_with_units_v2(uuid,bigint,numeric,timestamp with time zone,text,integer,jsonb)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `guardar_guia_remision_v4(uuid,uuid,boolean,text,text,bigint,bigint,uuid,text,text,text,text,text,timestamp with time zone,timestamp with time zone,jsonb,jsonb,jsonb,jsonb,bigint,bigint,bigint,numeric,integer,boolean,text,jsonb,boolean,bigint,bigint,bigint,text)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `list_audit_logs_v1(integer,bigint,text,text)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `list_business_metrics_v1()` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `list_custom_field_definitions_v1(text,boolean)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `list_operational_alerts_v1(text,integer)` | Cuerpo, pertenencia y auxiliares revisados. Pruebas de ejecución autenticada en `security_2dh_operational_alerts_and_active_employment_test.sql` (41 aserciones compartidas), incluido rechazo por empleo inactivo. |
| `list_product_variant_groups_v1()` | Cuerpo y auxiliares revisados para aislamiento y permisos. Casos de ejecución en `security_2dh_catalog_operations_test.sql` (57 aserciones en conjunto). |
| `list_purchase_orders_v1(text,integer)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `list_recent_observability_errors_v1(integer)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `list_sale_price_rules_v1()` | Cuerpo y auxiliares revisados para aislamiento y permisos. Casos de ejecución en `security_2dh_catalog_operations_test.sql` (57 aserciones en conjunto). |
| `list_services_v1(boolean)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `list_subscription_plans_v1()` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `listar_documentos_electronicos_v1(timestamp with time zone,timestamp with time zone,integer,integer)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `obtener_disponibilidad_nota_credito_v2(uuid)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `obtener_tendencia_movimientos(text,timestamp with time zone,timestamp with time zone)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `procesar_pago_deuda_v2(uuid,boolean,bigint,numeric,text,timestamp with time zone,boolean)` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `process_sale_credit_v5(uuid,bigint,numeric,timestamp with time zone,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint,jsonb)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `process_sale_v4(uuid,bigint,numeric,timestamp with time zone,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `process_sale_with_units_v4(uuid,bigint,numeric,timestamp with time zone,boolean,numeric,jsonb,jsonb,bigint,bigint,text,numeric,numeric,text,numeric,bigint)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `receive_purchase_order_v2(uuid,bigint,timestamp with time zone,text,text,jsonb)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `refresh_operational_alerts_v1()` | Cuerpo, pertenencia y auxiliares revisados. Pruebas de ejecución autenticada en `security_2dh_operational_alerts_and_active_employment_test.sql` (41 aserciones compartidas), incluido rechazo por empleo inactivo. |
| `register_traceable_merchandise_receipt_v1(uuid,bigint,bigint,numeric,timestamp with time zone,text,text,bigint,text,numeric,numeric,numeric,numeric,jsonb)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `registrar_gasto_mixto(bigint,text,numeric,text,timestamp with time zone,jsonb)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `registrar_ingreso_mercaderia_scaled_v2(uuid,bigint,timestamp with time zone,text,text,bigint,text,jsonb,numeric,numeric,numeric,numeric)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `registrar_merma_scaled_v4(uuid,bigint,bigint,numeric,text,timestamp with time zone,jsonb)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `registrar_pago_empleado_mixto(bigint,text,timestamp with time zone,jsonb)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `resolve_operational_alert_v1(uuid)` | Cuerpo, pertenencia y auxiliares revisados. Pruebas de ejecución autenticada en `security_2dh_operational_alerts_and_active_employment_test.sql` (41 aserciones compartidas), incluido rechazo por empleo inactivo. |
| `resolve_sale_price_v1(bigint,text,numeric,timestamp with time zone)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `save_business_metrics_v1(jsonb)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `save_product_traceability_config_v1(bigint,bigint,text,boolean)` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `save_product_unit_profile_v6(bigint,bigint,jsonb)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `save_product_variant_group_v1(bigint,text,jsonb,jsonb)` | Cuerpo y auxiliares revisados para aislamiento y permisos. Casos de ejecución en `security_2dh_catalog_operations_test.sql` (57 aserciones en conjunto). |
| `save_sale_price_rule_v1(bigint,text,bigint,text,numeric,numeric,numeric,integer,timestamp with time zone,timestamp with time zone,boolean)` | Cuerpo y auxiliares revisados para aislamiento y permisos. Casos de ejecución en `security_2dh_catalog_operations_test.sql` (57 aserciones en conjunto). |
| `save_service_v1(bigint,text,text,text,numeric,numeric)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `set_bundle_components_v1(bigint,jsonb)` | Cuerpo y auxiliares revisados para aislamiento y permisos. Casos de ejecución en `security_2dh_catalog_operations_test.sql` (57 aserciones en conjunto). |
| `set_catalog_item_type_v1(bigint,text)` | Cuerpo y auxiliares revisados para aislamiento y permisos. Casos de ejecución en `security_2dh_catalog_operations_test.sql` (57 aserciones en conjunto). |
| `set_default_cash_register_v1(uuid)` | Cuerpo revisado y casos incluidos en `security_2dh_branch_cash_tenant_test.sql` (23 aserciones en conjunto). |
| `set_employee_roles_v1(bigint,uuid[])` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `set_entity_custom_fields_v1(text,bigint,jsonb)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `set_main_branch_v1(uuid)` | Cuerpo revisado y casos incluidos en `security_2dh_branch_cash_tenant_test.sql` (23 aserciones en conjunto). |
| `set_role_permissions_v1(uuid,text[])` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `solicitar_baja_tributaria_v1(uuid,text,uuid,text)` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `trasladar_stock_scaled_v4(uuid,bigint,bigint,bigint,numeric,text,timestamp with time zone,jsonb)` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `trasladar_stock(bigint,bigint,bigint,integer,text,text)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `update_branch_v1(uuid,text,text,text)` | Cuerpo revisado y casos incluidos en `security_2dh_branch_cash_tenant_test.sql` (23 aserciones en conjunto). |
| `update_business_assistant_settings_v1(bigint,boolean,integer,integer)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `update_business_capabilities_v1(bigint,jsonb)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |
| `update_cash_register_v1(uuid,text,text)` | Cuerpo revisado y casos incluidos en `security_2dh_branch_cash_tenant_test.sql` (23 aserciones en conjunto). |
| `update_employee_permission_overrides_v1(bigint,jsonb)` | Casos incluidos en las pruebas 2D-H de operaciones entre empresas o empleo fiscal. Completar revisión de rutas restantes. |
| `update_operational_alert_settings_v1(bigint,jsonb)` | Cuerpo, pertenencia y auxiliares revisados. Pruebas de ejecución autenticada en `security_2dh_operational_alerts_and_active_employment_test.sql` (41 aserciones compartidas), incluido rechazo por empleo inactivo. |
| `upsert_custom_field_definition_v1(uuid,text,text,text,text,boolean,text[],jsonb,jsonb,integer,text)` | Pendiente de revisión individual y de vincular pruebas positivas y negativas. |

## Criterios pendientes

- Revisar cada auxiliar llamado desde las funciones privilegiadas.
- Verificar identificadores extranjeros, lotes mixtos, permisos insuficientes, ausencia o revocación de membresía y operaciones válidas.
- Registrar el candidato, el resultado DEV y la ejecución CI de cada ampliación.
- Resolver organización y rol desde una misma membresía seleccionada antes de admitir identidades multiempresa.
