# Fase 5.2 — Catálogo genérico

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN INTEGRAL LOCAL PENDIENTE**

Migraciones:

- `supabase/migrations/20260908044000_saas_generic_catalog_item_types_bundles.sql`
- `supabase/migrations/20260908044100_saas_generic_catalog_bundle_safety.sql`

Gate:

- `scripts/verify_saas_generic_catalog.mjs`

pgTAP:

- `supabase/tests/database/generic_catalog_contract_test.sql` — 24 assertions.

## Objetivo

Separar la semántica comercial de un artículo de la existencia física. El catálogo deja de modelar todo como “producto con stock” y obtiene cuatro tipos explícitos:

- `stock_product`: producto inventariable;
- `non_stock_product`: producto vendible sin inventario físico;
- `service`: servicio no inventariable;
- `bundle`: paquete comercial compuesto por otros ítems.

`es_servicio` se conserva únicamente como compatibilidad transitoria con writers existentes; `item_type` es el contrato autoritativo nuevo.

## Integridad tenant

`bundle_components` pertenece explícitamente a una organización y sus dos relaciones a `productos` son FKs compuestas `(organization_id,id)`. No es posible formar un bundle de ORG_A con componentes de ORG_B.

La tabla tiene RLS tenant-aware y no ofrece escritura Data API directa. La configuración pasa por RPC admin.

## Transiciones de tipo

`private.normalize_catalog_item_type()` bloquea convertir un producto inventariable a no-stock/servicio/bundle cuando todavía existe:

- saldo de inventario distinto de cero;
- lote con cantidad;
- serie disponible.

Un bundle con componentes tampoco puede convertirse a otro tipo hasta eliminar primero su composición.

`set_catalog_item_type_v1()` ofrece una transición explícita y tenant-aware para administración futura de UI.

## Bundles

### Composición

`bundle_components` almacena:

- bundle;
- componente;
- cantidad comercial por bundle.

V1 no admite bundles anidados. La decisión reduce ciclos y mantiene determinista el consumo/reversión.

### Venta

El bundle no tiene saldo propio. Al insertar su `detalle_ventas`, un trigger:

1. obtiene los componentes del mismo tenant;
2. convierte cada cantidad comercial a la escala de almacenamiento del componente;
3. bloquea las filas de stock necesarias;
4. valida saldo según `permitir_sin_stock`;
5. descuenta componentes inventariables;
6. crea movimientos de kardex `BUNDLE_COMPONENT`;
7. guarda un snapshot JSON inmutable en `detalle_ventas.bundle_components_snapshot`.

Servicios y productos no inventariables pueden ser componentes, pero no generan movimientos físicos.

### Anulación

La composición actual del bundle no se consulta al anular. Se usa exclusivamente el snapshot que quedó registrado en la venta.

El trigger de restauración sólo repone componentes cuando ya existe evidencia de la operación en `ventas_requests_anulados`; un DELETE ordinario de un detalle no repone stock accidentalmente.

Esto hace reversible la venta interna incluso si la composición del bundle cambia después.

## Límites fail-closed V1

Dos escenarios se rechazan deliberadamente hasta tener un contrato completo de reversión:

1. **Componente con lote/serie.** El flujo de venta trazable actual consume `p_detalles` del checkout y requiere, para series, selección explícita por unidad. Un componente oculto del bundle no dispone todavía de ese payload. Se rechaza en configuración y nuevamente al vender.
2. **Bundle en boleta/factura electrónica.** Una nota de crédito parcial debe devolver proporcionalmente los componentes. Hasta que F5/F6 incorpore esa reversión fiscal, bundles se limitan a ticket interno.

Estos límites son fail-closed: nunca se descuenta stock sin poder revertirlo correctamente.

## Compras y trazabilidad

Sólo `stock_product` puede:

- entrar a órdenes/recepciones de inventario;
- usar lotes o números de serie;
- mantener saldo físico.

`non_stock_product`, `service` y `bundle` conservan saldo cero y no generan kardex propio.

## Core Logic y offline

Se añadió `CatalogItemType` al dominio Dart. `Producto` y `ProductoBusqueda` exponen `itemType` y mantienen getters de compatibilidad (`esServicio`, `esInventariable`, `esBundle`).

`ProductoMapper` serializa/decodifica `item_type`; ya no decide semántica física sólo por `unidad_medida=Servicios`.

El contrato de sincronización solicita `item_type` y SQLite sube a versión 10 con:

- `item_type`;
- `es_servicio` legacy;
- backfill de servicios históricos;
- índice por tipo.

Así una sesión offline no convierte accidentalmente un bundle o artículo no-stock en un producto inventariable.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| Tipo explícito producto/no-stock/servicio/bundle | ✅ |
| `es_servicio` preservado como compatibilidad | ✅ |
| componentes tenant-qualified | ✅ |
| bundles anidados bloqueados | ✅ |
| transición stock→no-stock con existencias bloqueada | ✅ |
| consumo de componentes transaccional | ✅ |
| snapshot histórico de composición | ✅ |
| anulación de ticket restaura componentes | ✅ |
| componentes trazables fail-closed | ✅ V1 |
| bundles electrónicos fail-closed | ✅ V1 |
| compras sólo aceptan stock_product | ✅ |
| caché offline conserva item_type | ✅ |
| gate estático versionado | ✅ |
| pgTAP 24 assertions versionado | ✅ |
| `supabase db reset` + pgTAP | ⏳ T03/T04/T12 |
| pruebas ORG_A/ORG_B y bundles reales | ⏳ T07/T09/T14 |
| Flutter analyze/test | ⏳ T13 |

## Resultado

F5.2 queda cerrada a nivel de implementación. La siguiente fase es F5.3 — campos y reglas configurables. El Gate del Bloque 5 permanece abierto hasta completar F5.1–F5.4 y ejecutar validación dinámica final.