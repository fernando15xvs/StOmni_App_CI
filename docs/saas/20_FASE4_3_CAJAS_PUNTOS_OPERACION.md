# Fase 4.3 — Cajas y puntos de operación

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Migraciones:

- `supabase/migrations/20260908032000_saas_cash_registers_sessions.sql`
- `supabase/migrations/20260908032100_saas_cash_payment_attribution.sql`
- `supabase/migrations/20260908033500_saas_cash_debt_and_expense_runtime.sql`
- `supabase/migrations/20260908033600_saas_cash_single_session_per_user.sql`

Runtime:

- `packages/core_logic/lib/features/balance/data/balance_repository.dart`

Gate:

- `scripts/verify_saas_cash_registers.mjs`

Contrato pgTAP:

- `supabase/tests/database/cash_registers_tenant_contract_test.sql`

No se aplicó DDL al proyecto Supabase remoto. La validación integral continúa reservada para T00–T19 en local.

## Modelo operativo

Se crea `cash_registers` como punto de operación de Caja dependiente de:

```text
organization -> branch -> cash_register -> cash_session
```

Cada caja pertenece simultáneamente a una organización y sucursal mediante FK compuesta. `code` es único dentro de `(organization_id, branch_id)` y cada sucursal tiene una caja principal automática.

## Sesiones

`sesiones_caja` recibe:

- `organization_id NOT NULL`;
- `branch_id NOT NULL`;
- `cash_register_id NOT NULL`.

Las relaciones son tenant-qualified y el contexto queda inmutable después de abrir la sesión.

Se permiten varias cajas abiertas en una organización, pero:

- sólo una sesión abierta por `cash_register`;
- sólo una sesión abierta por usuario dentro del tenant mientras los entrypoints actuales derivan la caja desde `auth.uid()`.

Esto evita que un RPC tenga que adivinar cuál de dos cajas abiertas del mismo usuario debe afectar.

## RLS y permisos

`cash_registers` permite lectura tenant-aware a usuarios autenticados y sus mutaciones se realizan por RPC administrativas:

- `create_cash_register_v1`;
- `update_cash_register_v1`;
- `set_default_cash_register_v1`.

`sesiones_caja` aplica RLS por organización. Una sesión nueva se asigna al usuario autenticado y sólo el propio usuario o un administrador del tenant puede modificarla según la policy.

## Atribución de movimientos

`pagos_venta` y `pagos_gasto` reciben:

- `cash_register_id`;
- `cash_session_id`.

Un trigger privado vincula automáticamente un movimiento en efectivo a la sesión ABIERTA del mismo tenant/usuario. Las FKs incluyen `organization_id`, por lo que una sesión de ORG_B no puede atribuirse a un pago de ORG_A.

Pagos históricos o no-cash conservan `cash_session_id = NULL`.

## Vistas financieras

`movimientos` y `reportes_movimientos_financieros` fueron reconstruidas con:

```sql
WITH (security_invoker=true)
```

De esta forma respetan las policies de las tablas base y dejan de depender de privilegios del owner de la vista.

Los pagos de empleados se excluyen temporalmente de estas vistas hasta F4.4, porque `pagos_empleados` aún no posee el contrato final tenant/cash.

## Estado de Caja

`get_estado_caja_chica()` ya no busca una caja global. Resuelve el tenant actual y la sesión ABIERTA del usuario, y calcula:

- ingresos desde `pagos_venta.cash_session_id`;
- egresos desde `pagos_gasto.cash_session_id`;
- saldo esperado de esa sesión exacta.

## Gastos con Caja

`registrar_gasto_mixto` deja de estar fail-closed para Caja. Si un pago efectivo marca `afecta_caja_chica=true`:

1. exige sesión abierta del usuario;
2. bloquea la sesión;
3. calcula saldo disponible por `cash_session_id`;
4. rechaza saldo insuficiente;
5. inserta el pago atribuyéndolo a esa sesión.

Los pagos no-cash no requieren sesión.

## Deudas

`procesar_pago_deuda_v2` deja de delegar en `_legacy_procesar_pago_deuda_v2` para el flujo autoritativo.

La implementación nueva:

- deriva `organization_id` desde sesión autenticada;
- valida venta/gasto dentro del tenant;
- resuelve el empleado actor dentro del mismo tenant;
- usa advisory lock namespaced por `organization_id + request_id`;
- hace replay por `(organization_id, request_id)`;
- registra cobros de cliente en efectivo en la sesión actual;
- valida saldo antes de descontar Caja para proveedores;
- actualiza venta/gasto únicamente dentro del tenant.

El motor `_legacy_procesar_pago_deuda_v2` conserva `REVOKE` para clientes.

## Corrección de idempotencia descubierta

Durante F4.3 se detectó que `pagos_deuda_requests` conservaba su PK histórica global `request_id`, aunque F3.5 ya había añadido unicidad tenant-aware.

Se corrige a:

```text
PRIMARY KEY (organization_id, request_id)
```

Esto permite que ORG_A y ORG_B reutilicen el mismo UUID de request sin colisión ni inferencia entre tenants.

## Gate estático

`verify_saas_cash_registers.mjs` bloquea, entre otros:

- caja/sucursal sin FK tenant-qualified;
- sesión sin ownership empresarial;
- más de una sesión por caja sin constraint;
- pagos sin `cash_session_id`;
- vistas financieras sin `security_invoker`;
- saldo agregado por fecha en vez de sesión;
- resolución de “última caja abierta” global;
- delegación del entrypoint de deuda al motor legacy;
- PK de deuda no tenant-aware.

## Contrato dinámico previsto

`cash_registers_tenant_contract_test.sql` contiene 24 assertions pgTAP estructurales.

La validación final ORG_A/ORG_B deberá probar además:

- caja A no visible/modificable desde B;
- caja A no puede pertenecer a branch B;
- dos usuarios de A pueden abrir cajas distintas simultáneamente;
- un mismo usuario no puede abrir dos cajas a la vez;
- pago venta A queda ligado a sesión A;
- gasto efectivo A no puede consumir saldo de sesión B;
- deuda cliente/proveedor rechaza IDs de otro tenant;
- mismo `request_id` puede coexistir en A y B;
- saldo esperado sólo incluye movimientos de la sesión actual.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| `cash_registers` tenant + branch-aware | ✅ |
| sesiones tenant/branch/register-aware | ✅ |
| RLS por organización | ✅ |
| una sesión abierta por caja | ✅ |
| una sesión abierta por usuario | ✅ |
| pagos venta/gasto con `cash_session_id` | ✅ |
| vistas financieras `security_invoker` | ✅ |
| gasto cash reabierto con saldo por sesión | ✅ |
| deuda cash reimplementada sin motor global | ✅ |
| idempotencia deuda por tenant | ✅ |
| motor legacy de deuda cerrado | ✅ |
| gate estático versionado | ✅ |
| pgTAP versionado | ✅ |
| `supabase db reset` | ⏳ T03/T18 |
| ataques ORG_A/ORG_B | ⏳ T07/T09/T12 |

## Resultado

F4.3 queda cerrada a nivel de implementación. StOmni dispone de cajas por sucursal y sesiones atribuibles por tenant, con movimientos financieros ligados a una sesión concreta y sin depender de una “caja global”. El componente pendiente de Caja es `pagos_empleados`, que se incorpora deliberadamente en F4.4 junto con el modelo laboral final de empleados.
