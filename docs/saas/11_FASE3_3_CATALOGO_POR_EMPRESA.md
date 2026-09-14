# Fase 3.3 — Catálogo por empresa

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Migraciones principales:

- `supabase/migrations/20260907033419_saas_catalog_tenant.sql`
- `supabase/migrations/20260907210310_saas_product_update_tenant.sql`
- `supabase/migrations/20260907235417_saas_inventory_surface_lockdown.sql` (cierre de entrypoints de producto que tocan inventario)

Gate:

- `scripts/verify_saas_catalog_foundation.mjs`

Contrato pgTAP:

- `supabase/tests/database/catalog_tenant_contract_test.sql`
- `supabase/tests/database/inventory_rpc_surface_contract_test.sql` para evaluación/eliminación de producto.

No se aplicó DDL al Supabase remoto. La rama SaaS permanece fuera de los triggers de GitHub Actions.

## Alcance real encontrado

El catálogo activo está formado por:

- `productos`;
- `product_unit_profiles`;
- `product_variant_groups`;
- `product_variant_members`;
- `service_metadata`;
- `sale_price_rules`;
- `product_traceability_configs`.

No se encontró una tabla `categorias` activa en el esquema observado; no se creó una tabla artificial sólo para satisfacer el roadmap.

## Ownership tenant

Las siete tablas reciben `organization_id uuid NOT NULL`, FK a `organizations`, índices tenant y backfill fail-closed.

Las relaciones internas se convierten a FKs compuestas con `organization_id`, incluyendo:

- producto -> proveedor;
- perfil/presentación -> producto;
- trazabilidad -> producto;
- servicio -> producto;
- regla de precio -> producto;
- variante -> grupo + producto.

El objetivo es que conocer un `id` de otro tenant no permita construir una relación válida.

## Unicidad por empresa

El código/SKU deja de ser una unicidad global y pasa a:

```text
(organization_id, upper(btrim(codigo)))
```

La edición segura de productos también compara código/nombre/proveedor dentro del tenant actual, evitando falsos conflictos entre empresas.

## RLS y escritura server-side

Las tablas expuestas usan RLS tenant-aware y `private.enforce_row_organization_id()` para impedir que el cliente elija otro tenant.

Las operaciones complejas permanecen detrás de RPC. Los wrappers validan producto/grupo/regla dentro de la organización antes de ejecutar lógica privilegiada.

## Servicios e imágenes

`save_service_v1()` fue llevado al contexto tenant y sólo trabaja con almacenes/productos del tenant actual.

Las imágenes de producto usan namespace:

```text
<organization_uuid>/products/...
```

La policy de Storage sigue siendo la autoridad; el path generado por Flutter no concede acceso por sí solo.

## Evaluación/eliminación definitiva

Las implementaciones históricas se conservaron como funciones legacy sin `EXECUTE` cliente:

- `_legacy_evaluar_eliminacion_producto_v1`;
- `_legacy_eliminar_producto_seguro_v1`.

Los nombres públicos ahora son wrappers que exigen:

1. `tenant.admin`;
2. `private.assert_product_in_current_organization(p_producto_id)`;
3. ejecución de la implementación histórica sólo después de validar el tenant.

Esto evita que un administrador intente evaluar/eliminar un producto de otra organización sólo conociendo su ID.

## Runtime

Los prechecks administrativos ya no dependen de `empleados.auth_id`; usan el contexto canónico de `app_users` mediante `get_my_tenant_context_v1()`.

La caché local sigue pudiendo trabajar con IDs globales durante el rollout, pero todo acceso remoto queda filtrado por RLS/RPC tenant-aware.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| 7 tablas de catálogo con tenant directo | ✅ |
| backfill fail-closed | ✅ |
| `organization_id NOT NULL` | ✅ |
| SKU único dentro de empresa | ✅ |
| FKs catálogo tenant-qualified | ✅ |
| RLS tenant-aware | ✅ |
| INSERT/UPDATE no pueden mover tenant | ✅ |
| RPC puros de catálogo validados por tenant | ✅ |
| edición producto scopeada por tenant | ✅ |
| evaluación/eliminación protegidas | ✅ |
| imágenes namespaced por tenant | ✅ |
| pgTAP versionado | ✅ |
| prueba ORG_A/ORG_B | ⏳ T07/T09/T12 |
| `supabase db reset` completo | ⏳ T03/T18 |

## Resultado

F3.3 queda cerrada a nivel de implementación. El catálogo ya tiene ownership empresarial directo, unicidades y relaciones por tenant y una superficie RPC restringida. La validación dinámica completa permanece reservada para T00–T19.
