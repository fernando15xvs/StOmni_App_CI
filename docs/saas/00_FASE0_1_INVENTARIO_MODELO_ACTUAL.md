# Fase 0.1 — Inventario del modelo actual

Estado: **CERRADA / AUDITADA**  
Rama: `feature/saas-multitenant-foundation`

## Objetivo

Mapear el estado real de StOmni antes de introducir `organizations` y `organization_id`, sin modificar todavía el esquema operativo.

## Foto actual verificada

Inventario obtenido del proyecto Supabase de prueba `StOmniApp` y contrastado con el código del repositorio:

- 62 tablas `public`.
- 2 vistas `public`.
- 176 funciones/procedimientos `public`.
- 67 policies RLS `public`.
- 31 triggers de aplicación.
- 21 Edge Functions desplegadas.
- 3 buckets Storage de StOmni.
- 0 tablas con `organization_id`.
- 0 tablas con `empresa_id`.
- Sólo `business_capabilities` y `business_metric_definitions` tienen `business_id`, pero ese identificador sigue ligado al singleton histórico `configuracion_negocio.id = 1`.
- 0 de las 67 policies RLS contiene aislamiento por `organization_id`/`empresa_id`.

Conclusión: el backend actual tiene seguridad por usuario/rol, pero **todavía no tiene frontera de tenant**.

---

## 1. Clasificación de tablas

### A. Tablas de negocio que deben pertenecer a una empresa

Estas tablas deben quedar tenant-scoped directa o transitivamente, y la regla objetivo es que ninguna fila pueda cruzar de empresa:

`almacenes`, `clientes`, `comprobantes_electronicos`, `configuracion_negocio`, `constancias_descuento`, `correlativos_procesos_tributarios`, `cotizaciones`, `detalle_cotizaciones`, `detalle_ventas`, `documentos_tributarios_reconciliaciones`, `empleados`, `employee_permission_overrides`, `facturacion_intentos`, `gastos`, `gre_conductores`, `gre_transportistas`, `gre_transportistas_agencias`, `gre_vehiculos`, `guias_remision`, `guias_remision_detalles`, `guias_remision_intentos`, `inventario_almacen`, `inventario_movimientos`, `inventory_lots`, `inventory_serials`, `inventory_traceability_receipts`, `inventory_traceability_consumptions`, `notas_credito`, `notas_credito_detalles`, `notas_credito_intentos`, `pagos_empleados`, `pagos_gasto`, `pagos_venta`, `procesos_tributarios`, `procesos_tributarios_detalles`, `procesos_tributarios_intentos`, `productos`, `proveedores`, `series_comprobantes`, `sesiones_caja`, `solicitudes_baja_tributaria`, `transferencias_stock`, `ventas`, `business_capabilities`, `business_metric_definitions`, `product_unit_profiles`, `sale_price_rules`, `purchase_orders`, `purchase_order_lines`, `purchase_receipts`, `purchase_receipt_lines`, `product_variant_groups`, `product_variant_members`, `product_traceability_configs`, `service_metadata`.

Total: **55 tablas de negocio tenant-scoped**.

### B. Tablas internas de sistema que también deben llevar contexto de tenant

Aunque no sean datos que normalmente se muestren en UI, deben evitar colisiones o referencias cruzadas:

- `inventario_operaciones_idempotentes`
- `pagos_deuda_requests`
- `sys_processed_requests`
- `ventas_requests_anulados`

Total: **4 internas tenant-scoped**.

### C. Tabla temporal/transaccional

- `stock_alert_tx_context`

Debe seguir siendo interna/efímera, pero su clave futura debe evitar mezclar operaciones de empresas distintas cuando evalúe alertas.

### D. Datos globales compartidos

- `gre_ubigeos`: catálogo geográfico; candidato claro a global/read-only.
- `personas_cache`: candidato a cache global de consultas DNI/RUC. Requiere decisión explícita de privacidad/retención en Fase 0.2 antes de declararlo definitivamente global.

---

## 2. Vistas

Existen dos vistas:

- `movimientos`
- `reportes_movimientos_financieros`

Ambas agregan pagos/gastos/pagos a empleados sin dimensión de empresa. La segunda comprueba `app_es_admin()`, pero ese helper sólo valida rol global del empleado actual. Las dos deberán quedar tenant-aware antes de usarse con más de una empresa.

---

## 3. Singleton de negocio detectado

### Esquema

- `configuracion_negocio.id` tiene default `1`.
- `business_capabilities.business_id` tiene `CHECK (business_id = 1)`.
- `business_capabilities` referencia `configuracion_negocio(id)`.
- `business_metric_definitions.business_id` referencia `configuracion_negocio(id)`.

### RPC/funciones con dependencia singleton explícita

Se detectaron al menos estas 12 funciones con referencia directa a `configuracion_negocio`, `business_capabilities` y/o `id = 1`:

1. `_business_enforce_new_sale_capabilities`
2. `_business_enforce_purchase_capability`
3. `_business_services_enabled`
4. `_business_variants_enabled`
5. `actualizar_configuracion_negocio_v1`
6. `crear_guia_remision_v1`
7. `get_business_profile_v1`
8. `guardar_guia_remision_v3`
9. `list_business_metrics_v1`
10. `process_sale_v3`
11. `save_business_metrics_v1`
12. `update_business_capabilities_v1`

Esto es el mínimo explícito. Las 176 funciones deben pasar por auditoría tenant-aware durante Bloques 2 y 3, incluso si no contienen literalmente `id = 1`.

---

## 4. Helpers de autorización actuales

Los helpers actuales (`app_empleado_activo`, `app_es_admin`, `_gre_empleado_activo`, `get_user_role`, `app_tiene_permiso`) resuelven el acceso buscando `empleados.auth_id = auth.uid()`.

Problema para SaaS: verifican que el usuario sea empleado/admin, pero **no resuelven ni exigen una empresa**. Por tanto, una policy como `app_empleado_activo()` no distingue Empresa A de Empresa B.

Impacto: los helpers deben evolucionar antes de convertir las policies en multi-tenant.

---

## 5. RLS actual

Resultado auditado:

- Policies totales: **67**.
- Policies con referencia directa a `auth.uid()`: 2.
- Policies que usan `app_es_admin()`: 23.
- Policies que usan `app_empleado_activo()`: 41.
- Policies tenant-aware: **0**.

Esto no significa que el RLS actual sea inútil: protege frente a usuarios no autorizados en el modelo singleton. Significa que **no puede aislar dos empresas dentro de la misma base**.

---

## 6. Triggers

Hay 31 triggers de aplicación.

Riesgos principales:

- `business_guard_new_sale` / `business_guard_new_invoice` usan `_business_enforce_new_sale_capabilities`, que consulta capacidades singleton.
- `business_guard_purchase_order` usa `_business_enforce_purchase_capability`, también singleton.
- Triggers de inventario, servicios, trazabilidad, descuentos y fiscal trabajan sobre tablas que hoy no tienen tenant.

Regla futura: todo trigger que consulte otra tabla debe comprobar que las filas relacionadas pertenecen a la misma `organization_id` o apoyarse en FKs compuestas/funciones tenant-safe.

---

## 7. Edge Functions

Las 21 Edge Functions están activas y con `verify_jwt = true`, lo cual se conserva.

El problema está después de autenticar:

- `_shared/auth_guard.ts` busca el empleado por `auth_id`, pero no devuelve `organization_id`.
- `AuthorizedEmployeeContext` no contiene tenant.
- Las funciones usan un cliente `service_role`, por lo que pueden saltarse RLS; por ello cada consulta administrativa debe quedar explícitamente filtrada por tenant.
- `_shared/proceso_tributario_common.ts` consulta `configuracion_negocio.id = 1`.
- `_shared/guia_remision_common.ts` toma la primera fila de `configuracion_negocio`.
- `create_employee` / `delete_employee` actualmente administran empleados sin una frontera de empresa.

Gate futuro de Edge Functions: el contexto autorizado deberá incluir la empresa resuelta desde backend y ninguna función podrá confiar en un `organization_id` enviado por Flutter.

---

## 8. Core Logic / Flutter

Dependencias singleton confirmadas:

- `ConfiguracionService` inicia con `BusinessFiscalProfileKey(businessId: '1')` y sólo permite escritura legacy sobre negocio `1`.
- `BusinessProfileMapper` rechaza cualquier `business_id != '1'`.
- `SupabaseBusinessProfileGateway`:
  - se describe como adaptador singleton;
  - cachea con sufijo `:1`;
  - fallback consulta `configuracion_negocio.id = 1`;
  - rechaza `updateCapabilities` si `businessId != '1'`.
- `BusinessFiscalProfileMapper` usa `1` como fallback legacy.
- `GuiasRemisionRepository` toma la primera configuración de negocio.

La UI todavía no necesita selector de empresa en V1 porque el contrato definido por producto será una cuenta -> una empresa, pero el contexto de empresa sí deberá existir en `core_logic`.

---

## 9. Restricciones únicas que deben revisarse

Actualmente existen unicidades globales que pueden impedir que dos empresas registren datos legítimamente iguales. Deben evaluarse para convertirlas a claves compuestas con `organization_id` cuando aplique:

- `empleados.email`
- `gre_conductores(tipo_documento, numero_documento)`
- `gre_transportistas.ruc`
- `gre_vehiculos.placa`
- `constancias_descuento.codigo`
- `comprobantes_electronicos(tipo_documento_sunat, serie, correlativo)`
- `guias_remision(tipo_documento_sunat, serie, correlativo)`
- `notas_credito(serie, correlativo)`
- `procesos_tributarios.identificador`
- `procesos_tributarios(tipo_proceso, fecha_referencia, correlativo)`
- `series_comprobantes(tipo_documento_sunat, serie)`

Los UUID `request_id` pueden seguir siendo globalmente únicos, pero las tablas de idempotencia deberán guardar también el tenant para impedir cruces lógicos o ataques de replay entre empresas.

### Nota de identidad

Supabase Auth trata el email como identidad del proyecto, mientras que `empleados.email` también es único global hoy. En Fase 0.2 se debe decidir explícitamente cómo manejar el caso excepcional de una misma dirección de correo asociada a personas de dos empresas distintas sin romper el principio de aislamiento.

---

## 10. Storage

Buckets actuales:

- `logos` (público)
- `imagenes_productos` (público)
- `comprobantes-electronicos` (privado)

Las policies actuales autorizan por rol y bucket, pero no por prefijo de `organization_id`. Antes de tener dos empresas reales deberán pasar a rutas como:

`<organization_id>/...`

y las policies deberán comprobar que ese prefijo coincide con la empresa del usuario.

---

## 11. Orden de migración derivado del inventario

Para reducir riesgo, el inventario confirma este orden:

1. crear `organizations` + relación de acceso;
2. crear helpers de tenant;
3. separar identidad y empleado;
4. migrar configuración/capacidades;
5. migrar catálogos base (clientes/proveedores/productos/almacenes);
6. migrar inventario;
7. migrar ventas/compras/pagos;
8. migrar fiscal;
9. adaptar Edge Functions y Storage;
10. cerrar con ataques cross-tenant automatizados.

No se debe añadir `organization_id` a todas las tablas en una sola migración.

---

## Riesgos prioritarios registrados

| Prioridad | Hallazgo | Tratamiento |
|---|---|---|
| P0 | 0/67 policies aíslan por empresa | Bloque 2 |
| P0 | 0/62 tablas tienen `organization_id` | Bloques 1–3 |
| P0 | helpers Auth sólo validan empleado/rol | Bloque 2.1 |
| P0 | Edge Functions usan `service_role` sin tenant context | Bloque 2.4 |
| P0 | configuración/capacidades siguen en `id = 1` | Bloque 3.1 |
| P1 | Storage no está separado por tenant | Bloque 2.5 / 3 |
| P1 | varias unicidades son globales | Fases de dominio correspondientes |
| P1 | vistas financieras mezclan todo el dataset | Bloque 3.5 |
| P1 | Auth/email necesita contrato explícito | Fase 0.2 |

## Resultado de Fase 0.1

**APROBADA.** El mapa de impacto está suficientemente definido para diseñar el contrato técnico de tenant sin modificar datos operativos. La siguiente fase autorizada es **Fase 0.2 — Contrato técnico de tenant**.
