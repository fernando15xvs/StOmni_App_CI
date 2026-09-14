# Fase 3.6 — Compras por empresa

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Migraciones:

- `supabase/migrations/20260908020030_saas_purchases_tenant_schema.sql`
- `supabase/migrations/20260908020031_saas_purchases_rpc_guards.sql`
- `supabase/migrations/20260908020032_saas_purchases_request_scope_hardening.sql`

Gate estático:

- `scripts/verify_saas_purchases.mjs`

Contrato pgTAP:

- `supabase/tests/database/purchases_tenant_contract_test.sql`

No se aplicó DDL al proyecto Supabase remoto. La rama `feature/saas-multitenant-foundation` continúa fuera de los triggers de GitHub Actions.

## Alcance real del dominio

La inspección read-only del laboratorio identificó seis tablas propias de F3.6:

- `purchase_orders`;
- `purchase_order_lines`;
- `purchase_receipts`;
- `purchase_receipt_lines`;
- `gastos`;
- `pagos_gasto`.

`proveedores` ya recibió ownership tenant en F3.2 y se utiliza como padre tenant-qualified.

En el laboratorio las seis tablas tenían `0` filas al momento de la inspección. Esto permitió verificar metadata, constraints, RLS, triggers y RPC sin consultar datos de negocio reales.

## Runtime confirmado

El gateway de compras de `core_logic` utiliza exclusivamente:

```text
list_purchase_orders_v1
create_purchase_order_v1
receive_purchase_order_v2
cancel_purchase_order_v1
```

El repositorio de gastos mantiene lectura directa por Data API de `gastos` / `pagos_gasto`, pero sus mutaciones pasan por:

```text
registrar_gasto_mixto
eliminar_gasto_v1
eliminar_pago_gasto_v1
```

El pago de cuentas por pagar continúa entrando por:

```text
procesar_pago_deuda_v2
```

## Ownership tenant y FKs compuestas

Las seis tablas reciben:

```sql
organization_id uuid NOT NULL
```

con FK a `organizations(id)` y clave `UNIQUE (organization_id, id)`.

Las relaciones operativas dejan de confiar únicamente en un ID global y pasan a FKs compuestas:

- orden -> proveedor;
- orden -> almacén;
- línea -> orden;
- línea -> producto;
- recepción -> orden;
- línea de recepción -> recepción;
- línea de recepción -> línea de orden;
- gasto -> proveedor;
- pago de gasto -> gasto;
- pago de gasto -> request idempotente de deuda.

Así, un ID válido perteneciente a ORG_B no puede insertarse como referencia dentro de una fila de ORG_A.

## Backfill fail-closed

La migración intenta derivar tenant desde relaciones ya tenant-aware antes de recurrir a fallback:

- orden desde proveedor + almacén que coincidan en organización;
- línea desde orden + producto;
- recepción desde orden;
- línea de recepción desde recepción + línea de orden;
- gasto desde proveedor;
- pago desde gasto.

Si queda información histórica sin scope, el fallback sólo se permite cuando `configuracion_negocio` representa exactamente una organización inequívoca. Con más de una organización candidata la migración aborta.

Antes del `NOT NULL` final también se rechazan relaciones históricas cross-tenant.

## Idempotencia por empresa

Se eliminaron namespaces globales para requests de compras:

```text
purchase_orders      UNIQUE (organization_id, request_id)
purchase_receipts    UNIQUE (organization_id, request_id)
pagos_gasto          UNIQUE (organization_id, request_id) WHERE request_id IS NOT NULL
```

La tercera migración elimina además un precheck transitorio que podía inferir que un UUID ya existía en otra organización.

Consecuencia buscada: ORG_A y ORG_B pueden utilizar el mismo UUID de request sin colisionar ni revelar la existencia de la operación de la otra organización.

## Singleton de capability eliminado

Durante la auditoría se encontró un singleton adicional fuera del CRUD principal:

```sql
_business_enforce_purchase_capability()
...
WHERE business_id = 1
```

El trigger `business_guard_purchase_order` dependía de esa función.

La implementación nueva resuelve la capability exclusivamente por:

```sql
private.require_current_organization_id()
-> business_capabilities.organization_id
```

También `_service_block_purchase_line_v1()` fue scopeada por organización para que la validación producto/servicio no consulte otro tenant.

Ambas funciones privilegiadas usan `search_path=''` y no tienen `EXECUTE` cliente.

## RPC de órdenes

Los entrypoints activos fueron redefinidos para derivar el tenant server-side:

### `create_purchase_order_v1`

- exige `purchases.manage`;
- valida proveedor, almacén y cada producto dentro del tenant actual;
- usa advisory lock namespaced por `organization_id + request_id`;
- replay idempotente filtra `(organization_id, request_id)`;
- escribe `organization_id` explícitamente en cabecera y líneas.

### `list_purchase_orders_v1`

- exige `purchases.manage`;
- la consulta raíz filtra `organization_id`;
- serializa mediante `private.purchase_order_json()`.

### `cancel_purchase_order_v1`

- valida la orden contra el tenant actual antes de bloquearla;
- sólo evalúa líneas del mismo tenant;
- UPDATE incluye `organization_id`.

### `receive_purchase_order_v2`

- exige `purchases.manage` + `inventory.receive`;
- valida orden y líneas por tenant;
- replay de recepción usa `(organization_id, request_id)`;
- recepción y detalle escriben tenant explícito;
- producto se carga por tenant;
- delega el movimiento físico a los RPC de inventario ya endurecidos en F3.4.

`receive_purchase_order_v1` quedó revocado para `authenticated`.

El serializer histórico público `_purchase_order_json` también quedó fuera de la API cliente; la versión usada por los nuevos RPC vive en schema `private`.

## Gastos y cuentas por pagar

`gastos` y `pagos_gasto` conservan SELECT directo porque el runtime Flutter lo necesita, pero:

- RLS filtra por organización;
- `authenticated` sólo recibe `SELECT` directo;
- INSERT/UPDATE/DELETE directos quedan revocados;
- las mutaciones se hacen por RPC tenant-aware.

`registrar_gasto_mixto`:

- requiere `tenant.write`;
- valida proveedor dentro del tenant;
- escribe tenant server-side;
- crea sus pagos dentro del mismo tenant.

`eliminar_gasto_v1` y `eliminar_pago_gasto_v1` validan la pertenencia antes de mutar y todos sus SELECT/DELETE/UPDATE críticos incluyen `organization_id`.

La firma legacy `registrar_gasto` no utilizada por Flutter quedó revocada.

## Caja Chica permanece fail-closed

Las sesiones/cajas pertenecen a F4.3 y todavía no tienen ownership tenant final.

Por eso F3.6 no permite reabrir prematuramente esa dependencia:

- `registrar_gasto_mixto` rechaza pagos con `afecta_caja_chica=true`;
- `procesar_pago_deuda_v2` rechaza deuda a proveedor con `p_descontar_de_caja=true`;
- el cobro de deuda de cliente en efectivo ya permanecía bloqueado desde F3.5.

La operación no-cash sí está disponible.

## Pago de deuda a proveedor reactivado

F3.5 había cerrado temporalmente `p_es_cliente=false` hasta que `gastos` recibiera tenant.

F3.6 la reactiva con las siguientes garantías:

- `purchases.manage` obligatorio;
- `private.assert_expense_in_current_organization(p_deuda_id)` antes de entrar al motor interno;
- lookup y UPDATE de `gastos` dentro del motor legacy también fueron scopeados por tenant como defensa en profundidad;
- finalización de `pagos_deuda_requests` usa tenant;
- cualquier impacto en caja sigue rechazado hasta F4.3.

La compatibilidad del parche determinista fue comprobada read-only contra la definición PostgreSQL del laboratorio: los tres fragmentos esperados —lookup del gasto, update del gasto y finalización del request— coincidieron.

## `pagos_deuda_requests.deuda_id` polimórfico

`deuda_id` puede representar una venta o un gasto, por lo que una única FK declarativa no puede expresar el target.

Se añadió:

```text
private.enforce_debt_request_target_tenant()
pagos_deuda_requests_validate_target_tenant
```

El trigger valida:

- `es_cliente=true` -> `ventas(organization_id,id)`;
- `es_cliente=false` -> `gastos(organization_id,id)`.

También se valida cualquier fila legacy existente antes de cerrar la migración.

## RLS y superficie Data API

Tablas de órdenes/recepciones:

- RLS habilitado;
- sin acceso directo de `anon` ni `authenticated`;
- operación exclusivamente por RPC allowlisted.

`gastos` / `pagos_gasto`:

- RLS tenant-aware para SELECT;
- `anon` sin acceso;
- `authenticated` sólo SELECT directo;
- mutaciones únicamente por RPC.

Esto separa el control de grants del control RLS y evita que un `SECURITY DEFINER` legacy vuelva a convertirse accidentalmente en API pública.

## Gate estático

`scripts/verify_saas_purchases.mjs` verifica, entre otros:

- ownership tenant de las seis tablas;
- FKs compuestas;
- request-id por tenant;
- triggers de tenant inmutable;
- RLS/grants;
- eliminación del `business_id=1` del guard de compras;
- guards de producto por tenant;
- helpers privados y serializer privado;
- create/list/cancel/receive scopeados;
- ausencia de inferencia de UUID de otros tenants;
- gastos y pagos por RPC;
- Caja Chica fail-closed;
- rama proveedor de `procesar_pago_deuda_v2` reabierta de forma tenant-aware;
- target polimórfico de deuda validado por trigger;
- runtime Flutter usando sólo entrypoints permitidos;
- funciones legacy fuera de la allowlist.

El gate incluye self-test con mutaciones negativas. Está versionado para T02. No se declara ejecutado en este entorno: la validación integral se hará localmente sobre el commit candidato final.

## Contrato dinámico previsto

`purchases_tenant_contract_test.sql` contiene 35 assertions pgTAP para ejecutar después de `supabase db reset`.

La suite final debe comprobar además con ORG_A/ORG_B:

- un proveedor B no puede entrar en una orden A;
- un almacén/producto B no puede entrar en una orden A;
- una recepción A no puede consumir línea B;
- listar compras A nunca devuelve B;
- mismo request UUID en A y B puede coexistir;
- gasto/pago B no es visible ni mutable desde A;
- `procesar_pago_deuda_v2(false, gasto_B, ...)` es rechazado desde A;
- una recepción modifica sólo inventario del tenant dueño;
- Caja Chica continúa bloqueada mientras F4.3 siga pendiente.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| 6 tablas de compras/gastos con tenant directo | ✅ |
| ownership `NOT NULL` final | ✅ |
| FKs compuestas anti-cross-tenant | ✅ |
| idempotencia por empresa | ✅ |
| singleton `business_id=1` de compras eliminado | ✅ |
| create/list/cancel/receive tenant-aware | ✅ |
| serializer de OC privado | ✅ |
| receive v1 legacy revocado | ✅ |
| gastos SELECT por RLS y mutación sólo RPC | ✅ |
| deuda a proveedor no-cash tenant-aware | ✅ |
| target polimórfico venta/gasto validado | ✅ |
| Caja Chica fail-closed hasta F4.3 | ✅ |
| gate estático versionado | ✅ |
| pgTAP de 35 contratos versionado | ✅ |
| gate T02 ejecutado sobre commit final | ⏳ |
| `supabase db reset` completo | ⏳ T03/T18 |
| ataque ORG_A/ORG_B | ⏳ T07/T09/T12 |

## Resultado

F3.6 queda cerrada a nivel de implementación. Órdenes, recepciones, gastos y cuentas por pagar ya poseen ownership empresarial explícito, relaciones tenant-qualified y entrypoints server-side que derivan la organización desde la sesión autenticada. El único comportamiento operativo deliberadamente diferido de este dominio es el impacto en Caja Chica, que sólo se reabrirá cuando las cajas sean tenant-aware en F4.3.
