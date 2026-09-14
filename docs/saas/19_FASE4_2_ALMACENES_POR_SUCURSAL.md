# Fase 4.2 — Almacenes por sucursal

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN INTEGRAL LOCAL PENDIENTE**

Migración:
- `supabase/migrations/20260908031000_saas_warehouses_by_branch.sql`

Gate:
- `scripts/verify_saas_warehouse_branches.mjs`

pgTAP:
- `supabase/tests/database/warehouse_branch_contract_test.sql` — 10 assertions.

## Objetivo

Relacionar cada almacén con una sucursal perteneciente a la misma organización, sin romper el runtime actual que todavía crea almacenes sin selector explícito de sucursal.

## Implementación

Se añadió `almacenes.branch_id uuid` y se realizó backfill hacia la sucursal principal activa de cada organización. La migración aborta si algún almacén no puede obtener una sucursal principal válida.

Después del backfill:
- `branch_id` queda `NOT NULL`;
- FK compuesta `(organization_id, branch_id) -> branches(organization_id,id)` impide cruces de tenant;
- índice `(organization_id, branch_id, activo)` prepara listados por sucursal.

## Compatibilidad

El trigger `private.enforce_warehouse_branch()` mantiene compatibilidad con la UI existente:
- con usuario autenticado deriva la organización desde la sesión;
- si `branch_id` no se envía, asigna la sucursal principal activa del tenant;
- si se envía, exige que esa sucursal esté activa y pertenezca a la misma organización;
- para operaciones privilegiadas exige un `organization_id` explícito ya validado.

El trigger F3.4 de `organization_id` sigue siendo la primera barrera tenant; el nuevo trigger se ejecuta después y valida la dimensión sucursal.

## Integridad operativa

`update_branch_v1` fue endurecido para impedir que una sucursal con almacenes activos pase a `inactive`. Esto evita dejar stock operativo asociado a una sucursal deshabilitada.

No se modifica la estructura de inventario: existencias, movimientos, lotes, seriales y transferencias ya referencian almacenes tenant-safe desde F3.4 y heredan la dimensión de sucursal a través del almacén.

## Lo que NO hace F4.2

- no crea cajas/puntos de venta — F4.3;
- no añade sucursal a empleados — F4.4;
- no obliga todavía a la UI a elegir sucursal; el default principal preserva compatibilidad;
- no aplica DDL al Supabase remoto.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| Todo almacén tiene branch | ✅ Implementado |
| Branch y almacén pertenecen al mismo tenant | ✅ FK compuesta |
| Backfill usa principal del mismo tenant | ✅ |
| Almacén nuevo sin branch usa principal | ✅ |
| Branch explícita se valida dentro del tenant | ✅ |
| Branch con almacén activo no se desactiva | ✅ |
| Índice tenant/branch disponible | ✅ |
| Gate estático versionado | ✅ |
| pgTAP 10 assertions versionado | ✅ |
| `db reset` + pgTAP ejecutado | ⏳ T03/T04 |
| ORG_A no puede asignar almacén a branch ORG_B | ⏳ T07/T09/T14 |

## Resultado

F4.2 queda cerrada a nivel de implementación. La siguiente fase autorizada es F4.3 — Cajas y puntos de operación.
