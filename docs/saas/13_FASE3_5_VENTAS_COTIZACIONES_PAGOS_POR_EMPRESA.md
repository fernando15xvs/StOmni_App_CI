# Fase 3.5 — Ventas, cotizaciones y pagos por empresa

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Migraciones:

- `supabase/migrations/20260908000316_saas_sales_tenant_schema.sql`
- `supabase/migrations/20260908000924_saas_sales_rpc_guards.sql`
- `supabase/migrations/20260908001424_saas_sales_legacy_internal_scope.sql`

Gate:

- `scripts/verify_saas_sales.mjs`

Contrato pgTAP:

- `supabase/tests/database/sales_tenant_contract_test.sql`

No se aplicó DDL al Supabase remoto. La rama `feature/saas-multitenant-foundation` continúa fuera de los triggers de GitHub Actions.

## Superficie migrada

F3.5 cubre las tablas comerciales activas:

- `ventas`;
- `detalle_ventas`;
- `pagos_venta`;
- `cotizaciones`;
- `detalle_cotizaciones`;
- `pagos_deuda_requests`;
- `ventas_requests_anulados`;
- `constancias_descuento`.

`constancias_descuento` fue incorporada después del inventario inicial porque se crea dentro de la misma transacción de venta y sus policies seguían siendo legacy.

## Ownership y relaciones

Las tablas reciben `organization_id uuid NOT NULL`, FK a `organizations`, índices tenant y backfill fail-closed.

Las relaciones de negocio importantes pasan a ser tenant-qualified:

```text
venta -> cliente
venta -> vendedor
venta -> autorizador de descuento
detalle venta -> venta + producto + almacén
pago -> venta
cotización -> cliente
detalle cotización -> cotización + producto + almacén
request de deuda -> empleado
constancia descuento -> venta + actor + autorizador
```

De esta forma, conocer IDs válidos de otra empresa no permite formar una relación válida.

## RLS y superficie de tablas

Las tablas de lectura comercial usan policies tenant-aware.

Las tablas de idempotencia y las mutaciones complejas no se exponen mediante grants directos; las escrituras pasan por RPC.

`anon` no obtiene acceso al dominio comercial.

## Motor central de venta

Flutter usa actualmente:

- `process_sale_v4`;
- `process_sale_with_units_v4`.

El motor histórico `process_sale_v3` contiene gran parte de la lógica económica consolidada. En vez de copiar aproximadamente 39 000 caracteres y crear una segunda implementación divergente, F3.5 aplica un parche determinista a la definición autoritativa existente.

La migración aborta si los fragmentos esperados no existen. Una verificación read-only contra PostgreSQL 17.6 confirmó que los 10 fragmentos críticos esperados existen en la definición actual.

El parche scopea por organización:

- request_id de ventas anuladas;
- replay/idempotencia de venta;
- `configuracion_negocio`;
- actor autenticado;
- cliente;
- producto/proveedor;
- almacén;
- lectura de stock;
- actualización de stock;
- aprobación de cotización.

El antiguo singleton:

```sql
FROM configuracion_negocio
ORDER BY id
LIMIT 1
```

deja de decidir qué empresa configura la venta; la configuración se resuelve con el tenant autenticado.

`process_sale_v3` pierde `EXECUTE` cliente y queda como motor interno.

## Precheck antes de SECURITY DEFINER

Los entrypoints v4 comprueban antes de ejecutar precios/trazabilidad:

- request_id no usado por otro tenant;
- cliente del tenant actual;
- cotización del tenant actual;
- todos los productos del tenant actual;
- todos los almacenes del tenant actual;
- permiso `sales.create`;
- permiso `sales.discount` cuando corresponde.

Las FKs compuestas y triggers constituyen una segunda barrera aunque un motor interno intente escribir una relación cruzada.

## Cotizaciones

Los motores históricos se conservan privados y los nombres públicos son wrappers tenant-aware.

También se reescribieron:

- `actualizar_cotizaciones_vencidas()` para actualizar sólo la organización actual;
- `eliminar_cotizacion_v2()` para buscar/borrar sólo dentro del tenant.

## Pagos y deudas

`eliminar_pago_venta_v1()` valida tanto venta como pago dentro del tenant y recalcula el saldo usando únicamente pagos de esa organización.

`procesar_pago_deuda_v2()` mantiene durante el rollout sólo la rama de deuda de cliente. La implementación histórica queda privada y además fue scopeada internamente como defense-in-depth.

### Restricciones transitorias deliberadas

1. **Deuda de proveedor:** deshabilitada en este RPC hasta F3.6, porque `gastos/pagos_gasto` todavía no estaban tenantificados al cerrar F3.5.
2. **Pago de deuda en efectivo:** deshabilitado hasta F4.3, porque las sesiones/cajas todavía no son tenant-aware.
3. **Boleta/factura electrónica:** deshabilitadas temporalmente en los entrypoints v4 hasta F3.7, porque series, comprobantes e intentos fiscales todavía no son tenant-aware.

Estas restricciones son fail-closed: es preferible rechazar una operación durante el rollout que permitir que use estado global de otro tenant.

## Anulación

`anular_venta_v2()` valida primero la venta del tenant antes de delegar.

La implementación histórica de anulación también fue parcheada internamente para scopear:

- actor;
- venta;
- vendedor snapshot;
- detalles;
- constancias;
- pagos y borrados comerciales.

El motor legacy no tiene `EXECUTE` para `authenticated`.

## Allowlist RPC

Se retiran de la superficie cliente motores y versiones anteriores, incluidos:

- `process_sale_v3`;
- `process_sale_authorized_v4`;
- `process_sale_with_units_v1/v2/v3`;
- `anular_venta`;
- `anular_venta_with_units_v3`;
- `guardar_cotizacion_with_units_v1`;
- `procesar_pago_deuda` v1.

Los nombres usados por Flutter quedan en allowlist explícita.

## Verificaciones estructurales

Además del gate estático, el contrato pgTAP contiene 30 checks sobre:

- `organization_id NOT NULL`;
- FKs compuestas;
- RLS;
- grants/revokes;
- motor v3 scopeado;
- entrypoints v4;
- anulación;
- pagos;
- motores legacy privados;
- restricciones de rollout.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| 8 tablas comerciales tenant-owned | ✅ |
| backfill fail-closed | ✅ |
| FKs cliente/producto/almacén/venta tenant-qualified | ✅ |
| RLS tenant-aware | ✅ |
| `process_sale_v3` deja de usar configuración singleton | ✅ |
| v4 valida payload antes de motor privilegiado | ✅ |
| cotizaciones tenant-aware | ✅ |
| pagos de venta tenant-aware | ✅ |
| anulación tenant-aware | ✅ |
| RPC legacy fuera de Data API | ✅ |
| boleta/factura bloqueadas hasta F3.7 | ✅ fail-closed |
| deuda proveedor bloqueada hasta F3.6 | ✅ fail-closed |
| efectivo de deuda bloqueado hasta F4.3 | ✅ fail-closed |
| gate estático versionado | ✅ |
| pgTAP versionado | ✅ |
| ORG_A/ORG_B cross-tenant | ⏳ T07/T09/T12 |
| `supabase db reset` completo | ⏳ T03/T18 |

## Resultado

F3.5 queda cerrada a nivel de implementación. Ventas, cotizaciones, pagos de venta, deuda de cliente e idempotencia comercial ya tienen ownership tenant y una superficie RPC restringida. Las dependencias todavía globales se mantienen cerradas explícitamente hasta sus fases correspondientes.
