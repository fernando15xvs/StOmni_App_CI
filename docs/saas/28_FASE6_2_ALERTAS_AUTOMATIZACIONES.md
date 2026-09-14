# Fase 6.2 — Alertas y automatizaciones

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Migraciones:

- `supabase/migrations/20260908051000_saas_operational_alerts_automation.sql`
- `supabase/migrations/20260908051100_saas_operational_alert_settings_safety.sql`
- `supabase/migrations/20260908051200_saas_operational_alert_event_driven_stock.sql`

Gate:

- `scripts/verify_saas_operational_alerts.mjs`

pgTAP:

- `supabase/tests/database/operational_alerts_contract_test.sql` — 30 assertions.

Runtime `core_logic`:

- `automation/domain/operational_alert.dart`
- `automation/application/operational_alert_gateway.dart`
- `automation/data/supabase_operational_alert_gateway.dart`
- `automation/providers/operational_alert_providers.dart`

## Corrección de seguridad previa

La notificación legacy de stock bajo utilizaba OneSignal con `included_segments = All`. Ese contrato no es admisible en un SaaS multiempresa porque un evento de ORG_A podía terminar enviado a usuarios ajenos al tenant.

F6.2 elimina los triggers legacy:

- `trigger_stock_alert_acumular_tx`;
- `trigger_stock_alert_evaluar_tx`.

El gate revisa además todas las migraciones posteriores a F6.2 y falla si el trigger global vuelve a crearse o si aparece otra notificación `included_segments: All`.

## Modelo

Se crean dos tablas tenant-owned:

### `operational_alert_settings`

Una fila por `organization_id`, con umbrales configurables:

- stock bajo habilitado/deshabilitado;
- días de aviso de vencimiento;
- antigüedad de deuda pendiente;
- antigüedad de orden de compra pendiente;
- máximo de horas de una sesión de caja abierta;
- `revision` para optimistic concurrency.

Cada organización nueva recibe settings por defecto automáticamente.

### `operational_alerts`

Inbox persistente de alertas con:

- `organization_id`;
- categoría;
- severidad;
- estado;
- `dedup_key` único dentro del tenant;
- entidad e identificador relacionados;
- título/mensaje;
- fecha límite;
- primera/última detección;
- reconocimiento y resolución;
- metadata acotada a 16 KiB.

Las categorías V1 son:

- `stock_low`;
- `expiry`;
- `debt_overdue`;
- `purchase_pending`;
- `cash_session_open`;
- `task`.

## Fuentes y semántica

### Stock bajo

Se calcula por producto dentro de la organización y respeta `business_capabilities.inventory_enabled`.

Además del refresco general existe evaluación event-driven. Un constraint trigger `DEFERRABLE INITIALLY DEFERRED` se ejecuta al final de la transacción de inventario y evalúa el stock final real, evitando falsos positivos durante traslados internos.

### Vencimientos

Se inspeccionan `inventory_lots` con saldo positivo y `expiry_date` dentro del umbral configurado.

### Deuda pendiente

El esquema actual no contiene una fecha contractual universal de vencimiento para ventas a crédito. F6.2 no inventa ese dato: V1 define operativamente una deuda como vencida cuando permanece pendiente durante más días que `debt_overdue_days` (30 por defecto).

Una fase futura puede sustituir esa semántica por `due_at` contractual sin romper el inbox.

### Compras pendientes

Las órdenes `ordered` o `partially_received` generan alerta cuando `expected_at` ya pasó. Si no existe `expected_at`, se usa `ordered_at + purchase_pending_days`.

### Sesiones de caja

Una sesión `ABIERTA` genera alerta al superar `cash_session_max_hours`.

### Tareas

Los administradores pueden crear tareas operativas manuales que usan el mismo inbox y ciclo de reconocimiento/resolución.

## Resolución automática

El refresco usa `last_detected_at` como marca de ejecución. Las alertas automáticas que ya no cumplen su condición se marcan `resolved` en vez de permanecer obsoletas.

Una condición que reaparece vuelve a abrir su misma `dedup_key`, evitando crear filas infinitas por el mismo problema.

## Seguridad

- `organization_id` nunca llega desde Flutter como autoridad.
- Los RPC derivan tenant con `private.require_current_organization_id()`.
- RLS limita lectura al tenant actual.
- `authenticated` no recibe INSERT/UPDATE/DELETE directo sobre las tablas.
- Mutaciones pasan por RPC controlados.
- Crear tareas y resolver manualmente exige `tenant.admin`.
- Settings usan optimistic concurrency por `revision` y allowlist de claves.

## RPC públicos

- `refresh_operational_alerts_v1()`
- `list_operational_alerts_v1(text, integer)`
- `acknowledge_operational_alert_v1(uuid)`
- `create_operational_task_v1(text, text, timestamptz, text)`
- `resolve_operational_alert_v1(uuid)`
- `get_operational_alert_settings_v1()`
- `update_operational_alert_settings_v1(bigint, jsonb)`

Todos están clasificados por `verify_saas_operational_alerts.mjs`, integrado en `verify_saas_rpc_surface.mjs`.

## Core Logic

`OperationalAlertGateway` concentra las operaciones del inbox. Mobile/desktop no necesitan reconstruir alertas consultando por separado inventario, ventas, compras, lotes o cajas.

El adaptador Supabase usa nombres RPC literales y el barrel `core_logic.dart` exporta el contrato completo.

## Validación dinámica pendiente

T07/T09/T12/T13/T14 deberán probar, entre otros:

- ORG_A no puede leer/acknowledge/resolve alertas B;
- el mismo `dedup_key` puede existir simultáneamente en A y B;
- stock bajo A nunca genera alerta B;
- un traslado que conserva stock total no crea falsa alerta;
- vencimiento de lote B no aparece en A;
- settings A no modifican revision de B;
- update con revision obsoleta falla sin sobrescribir cambios;
- usuario no-admin no puede crear tarea ni resolver manualmente;
- una alerta automática desaparecida se resuelve;
- una condición que reaparece reabre la misma alerta;
- no existe trigger OneSignal global después del reset completo.

## Resultado

F6.2 queda cerrada a nivel de implementación. StOmni dispone de un inbox operativo multi-tenant y configurable, con generación determinista para los principales riesgos del negocio y sin depender de notificaciones push globales inseguras. La validación dinámica integral queda pendiente para T00–T19.
