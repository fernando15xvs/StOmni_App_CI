# Fase 5.1 — Capacidades por empresa

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Migraciones:

- `supabase/migrations/20260908043000_saas_tenant_capabilities_complete.sql`
- `supabase/migrations/20260908043100_saas_capability_guard_corrections.sql`

Runtime:

- `packages/core_logic/lib/business/domain/business_profile.dart`
- `packages/core_logic/lib/business/data/business_profile_mapper.dart`
- configuradores de trazabilidad mobile/desktop.

Gate:

- `scripts/verify_saas_tenant_capabilities.mjs`

pgTAP:

- `supabase/tests/database/tenant_capabilities_contract_test.sql` — 18 assertions.

## Modelo

F5.1 extiende `business_capabilities`, que ya era tenant-aware desde F3.1. No se crea una segunda fuente de configuración.

Las capacidades finales de V1 son:

- inventario;
- múltiples sucursales;
- múltiples almacenes;
- ventas a crédito;
- facturación electrónica;
- compras;
- servicios;
- variantes;
- lotes;
- vencimientos;
- números de serie.

`business_capabilities` ya contenía crédito, fiscal, compras, servicios, variantes y trazabilidad. F5.1 materializa las capacidades que todavía se devolvían hardcodeadas:

```text
inventory_enabled
multiple_branches
multiple_warehouses
```

Todas son por `organization_id` y conservan optimistic locking mediante `revision`.

## Invariantes

El backend rechaza combinaciones imposibles:

- vencimientos requieren lotes;
- inventario desactivado exige compras, lotes, vencimientos, series y múltiples almacenes desactivados;
- no se puede desactivar multi-sucursal mientras existan varias sucursales activas;
- no se puede desactivar multi-almacén mientras existan varios almacenes activos;
- no se puede desactivar inventario mientras exista stock, lotes con saldo o seriales en stock;
- no se pueden desactivar lotes/series mientras exista saldo trazable correspondiente.

`supplier_management` permanece obligatorio en el contrato actual porque proveedores forman parte estructural de compras/gastos; no se presenta todavía como capacidad desactivable.

## Enforcement backend

No se confía en que Flutter oculte pantallas.

Se agregan guards para:

- creación/reactivación de sucursal cuando `multiple_branches=false`;
- creación/reactivación de almacén cuando `multiple_warehouses=false`;
- creación/reactivación de almacén cuando `inventory_enabled=false`;
- mutaciones de `inventario_almacen` cuando inventario está desactivado.

Los triggers de INSERT/UPDATE cubren clientes viejos. El trigger de saldo devuelve correctamente `OLD` en DELETE para no cancelar una eliminación permitida.

## Perfil y actualización

`get_business_profile_v1()` devuelve las capacidades persistidas, incluida `multiple_branches`.

`update_business_capabilities_v1()`:

- deriva tenant server-side;
- exige `tenant.admin`;
- valida claves y tipos;
- conserva `revision` optimista;
- filtra todas las verificaciones de datos por `organization_id`;
- aplica las invariantes antes de actualizar.

## Core Logic

`BusinessCapabilities` incorpora `multipleBranches`.

Se elimina la suposición anterior de que el backend sólo era compatible si `inventoryEnabled=true` y `multipleWarehouses=true`. Una empresa sin inventario ahora es un perfil válido siempre que desactive las capacidades dependientes.

`BusinessProfileMapper` codifica/decodifica `multiple_branches` y conserva las demás capacidades.

Los configuradores de trazabilidad mobile y desktop preservan `multipleBranches` al guardar cambios de lotes/series; así una edición no reactiva accidentalmente otra capacidad.

## Gate

`verify_saas_tenant_capabilities.mjs` valida DB + runtime:

- columnas persistidas;
- invariantes;
- tenant scope;
- guards de sucursal/almacén/inventario;
- semántica correcta en DELETE;
- modelo y mapper Dart;
- preservación de `multipleBranches` en mobile/desktop.

## Validación dinámica pendiente

T04/T07/T09/T12/T13 deberán demostrar, entre otros:

- ORG_A puede tener capacidades distintas de ORG_B;
- modificar A no incrementa `revision` de B;
- cliente A no puede actualizar capabilities B;
- desactivar inventario con stock falla y no cambia revision;
- inventario desactivado bloquea nuevas mutaciones aunque el cliente invoque APIs directamente;
- multi-sucursal/multi-almacén impiden nuevas altas/reactivaciones cuando están desactivados;
- perfiles con inventario desactivado se decodifican correctamente en Flutter.

## Resultado

F5.1 queda cerrada a nivel de implementación. Las capacidades dejan de ser sólo metadatos de presentación y se convierten en políticas funcionales por tenant con enforcement backend.
