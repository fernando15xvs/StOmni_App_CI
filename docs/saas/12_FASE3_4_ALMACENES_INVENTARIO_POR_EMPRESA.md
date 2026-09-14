# Fase 3.4 — Almacenes e inventario por empresa

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Migraciones:

- `supabase/migrations/20260907205440_saas_inventory_tenant_schema.sql`
- `supabase/migrations/20260907205926_saas_inventory_rpc_guards.sql`
- `supabase/migrations/20260907235417_saas_inventory_surface_lockdown.sql`

Gates:

- `scripts/verify_saas_inventory.mjs`
- `scripts/verify_saas_inventory_runtime.mjs`
- `scripts/verify_saas_inventory_surface.mjs`

Contratos pgTAP:

- `supabase/tests/database/inventory_tenant_contract_test.sql`
- `supabase/tests/database/inventory_rpc_surface_contract_test.sql`

No se aplicó DDL al Supabase remoto. La rama SaaS continúa fuera de los triggers de GitHub Actions.

## Superficie real migrada

La auditoría amplió el alcance más allá de las tablas obvias. F3.4 cubre 11 tablas:

- `almacenes`;
- `inventario_almacen`;
- `inventario_movimientos`;
- `inventario_operaciones_idempotentes`;
- `inventory_lots`;
- `inventory_serials`;
- `inventory_traceability_consumptions`;
- `inventory_traceability_receipts`;
- `stock_alert_tx_context`;
- `transferencias_stock`;
- `sys_processed_requests`.

Esto evita dejar tablas auxiliares globales capaces de conectar tenants indirectamente.

## Ownership y relaciones

Todas las tablas reciben `organization_id uuid NOT NULL` con FK a `organizations`.

Se preparan claves compuestas en padres como almacenes y movimientos, y las relaciones producto/almacén/movimiento pasan a FKs tenant-qualified.

Ejemplos de invariantes:

```text
existencia.organization_id = producto.organization_id = almacen.organization_id
lote.organization_id       = producto.organization_id = almacen.organization_id
serie.organization_id      = producto.organization_id = almacen.organization_id
traslado.organization_id   = producto = origen = destino
```

## Backfill

El backfill intenta primero derivar tenant desde producto/almacén ya migrados. Sólo utiliza fallback legacy cuando existe exactamente una organización inequívoca.

Si quedan filas no scopeadas o aparece una relación cruzada, la migración aborta.

Durante la revisión se detectó y corrigió un problema de compatibilidad PostgreSQL 17.6: no se utiliza `min(uuid)`; el UUID fallback se obtiene mediante orden determinista después de comprobar que existe exactamente una organización candidata.

## Trigger de inventario

`private.enforce_inventory_organization_id()`:

- deriva tenant desde producto/almacén;
- verifica que todos los padres pertenezcan al mismo tenant;
- rechaza relaciones producto/almacén cruzadas;
- rechaza origen/destino de traslado de otra empresa;
- para usuario autenticado impone el tenant de la sesión;
- para procesos privilegiados exige tenant explícito o derivable;
- mantiene `organization_id` inmutable.

## RLS

Se reemplazan las policies legacy basadas en `app_empleado_activo()` / `app_es_admin()` por policies tenant-aware.

Lecturas principales:

- almacenes -> tenant.read;
- existencias -> tenant.read;
- lotes/seriales -> tenant.read;
- kardex administrativo -> tenant.admin.

Las tablas internas de idempotencia/trazabilidad no reciben grants cliente directos; se accede a ellas mediante RPC controlados.

## RPC activos

Se protegieron los flujos usados por la app:

- ajuste de stock;
- ingreso de mercadería;
- merma;
- traslado;
- recepción trazable;
- creación de producto con stock;
- edición de producto/apertura;
- servicio;
- lectura de lotes/seriales;
- activación/desactivación de almacenes.

Los RPC validan producto, almacén, proveedor y request_id dentro del tenant antes de ejecutar lógica `SECURITY DEFINER`.

## Cierre de superficie legacy

Supabase no aplica RLS a funciones como si fueran tablas; por ello F3.4 no se considera cerrada únicamente con RLS.

Se revocó `EXECUTE` de entrypoints históricos que podían invocarse directamente, entre ellos:

- `ajustar_stock_y_kardex`;
- `registrar_ingreso_mercaderia_v2` base;
- `registrar_merma_v2`;
- `registrar_merma_scaled_v2/v3`;
- `trasladar_stock_v2`;
- `trasladar_stock_scaled_v2/v3`.

Sólo la allowlist vigente queda expuesta a `authenticated`.

## Runtime Flutter/Core

Se eliminaron tres riesgos de transición:

1. prechecks admin basados en `empleados.auth_id`;
2. upload de producto sin namespace de empresa;
3. `upsert` directo de `inventario_almacen` desde Flutter.

El saldo se modifica mediante RPC de inventario y el contexto de admin se resuelve mediante `get_my_tenant_context_v1()`.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| 11 tablas de inventario con tenant | ✅ |
| `organization_id NOT NULL` | ✅ |
| backfill fail-closed | ✅ |
| FKs producto/almacén tenant-qualified | ✅ |
| lotes y seriales aislados | ✅ |
| transferencias origen/destino aisladas | ✅ |
| idempotencia scopeada por tenant | ✅ |
| RLS tenant-aware | ✅ |
| RPC activos validan tenant | ✅ |
| RPC legacy sin EXECUTE cliente | ✅ |
| saldo no se escribe directamente desde Flutter | ✅ |
| precheck admin no depende de empleado | ✅ |
| pgTAP de esquema + superficie versionados | ✅ |
| prueba cross-tenant ORG_A/ORG_B | ⏳ T07/T09/T12 |
| `supabase db reset` completo | ⏳ T03/T18 |

## Dependencias siguientes

Ventas y compras todavía llaman inventario desde sus propios RPC. F3.5/F3.6 deben validar sus entidades de negocio y tenant antes de delegar a estas operaciones.

## Resultado

F3.4 queda cerrada a nivel de implementación. Inventario posee ownership explícito, relaciones compuestas y una superficie RPC allowlisted. Las pruebas dinámicas completas quedan pendientes para el mapa T00–T19.
