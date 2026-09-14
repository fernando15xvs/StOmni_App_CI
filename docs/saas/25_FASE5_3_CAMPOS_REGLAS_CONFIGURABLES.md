# Fase 5.3 — Campos y reglas configurables

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN INTEGRAL LOCAL PENDIENTE**

Migraciones:

- `supabase/migrations/20260908045000_saas_typed_custom_fields_rules.sql`
- `supabase/migrations/20260908045100_saas_custom_fields_safety.sql`
- `supabase/migrations/20260908045200_saas_custom_fields_trigger_order.sql`

Gate:

- `scripts/verify_saas_custom_fields.mjs`

pgTAP:

- `supabase/tests/database/custom_fields_contract_test.sql` — 25 assertions.

## Diseño

F5.3 evita un esquema EAV por valor. Cada entidad conserva sus valores personalizados en un único objeto JSONB:

- `productos.custom_fields`;
- `clientes.custom_fields`;
- `proveedores.custom_fields`.

Las definiciones viven en `custom_field_definitions`, tenant-owned y con RLS. Esto permite flexibilidad sin convertir consultas, backups y relaciones en cientos de filas atributo/valor.

## Entidades soportadas V1

- `catalog_item`;
- `customer`;
- `supplier`.

Los campos de catálogo pueden restringirse además a uno o más `item_type` de F5.2.

## Tipos soportados

- texto;
- número;
- booleano;
- fecha ISO;
- selección única;
- selección múltiple.

Las reglas V1 son deliberadamente declarativas:

- `min` / `max` para números;
- `min_length` / `max_length` para texto;
- allowlist de opciones para select/multiselect;
- requerido/opcional.

No se aceptan regex, SQL, JavaScript ni expresiones configurables ejecutables. Esto evita convertir configuración de tenant en una superficie de ejecución o DoS del backend.

## Límites de datos

- objeto de valores máximo 64 KiB;
- máximo 100 opciones por definición;
- texto máximo 4 000 caracteres;
- multiselect máximo 100 valores;
- opciones duplicadas rechazadas.

## Rollout seguro

Un campo no puede convertirse en `required` si existen filas aplicables sin un valor válido. El flujo esperado es:

1. crear definición opcional;
2. poblar valores;
3. activar requerido.

Tampoco se permite cambiar tipo/opciones/reglas si el cambio invalida valores ya persistidos, ni restringir un campo a otros `item_type` mientras existan valores fuera del nuevo alcance.

## Validación en base de datos

`private.validate_entity_custom_fields()` se ejecuta antes de INSERT/UPDATE en las tres entidades.

Usa `to_jsonb(NEW)` para ser compatible con layouts distintos y comprueba:

- claves conocidas;
- aplicabilidad por item type;
- tipo del valor;
- reglas;
- campos requeridos;
- límite total del payload.

En productos, el trigger se denomina `zzz_productos_validate_custom_fields` para ejecutarse después de `zz_productos_catalog_item_type`; así un writer legacy de servicios primero queda normalizado como `service` y después se evalúan los campos que corresponden a servicios.

## RPC

- `list_custom_field_definitions_v1` — lectura tenant-aware;
- `upsert_custom_field_definition_v1` — sólo `tenant.admin`;
- `set_entity_custom_fields_v1` — `tenant.write`, siempre scopeado por organización.

## Core Logic

Se añadieron:

- `CustomFieldEntityType`;
- `CustomFieldValueType`;
- `CustomFieldValidation`;
- `CustomFieldDefinition`;
- `CustomFieldGateway`;
- `SupabaseCustomFieldGateway`;
- `customFieldGatewayProvider`.

Esto constituye el contrato que F5.4 usa para construir formularios dinámicos sin replicar reglas de tipos/opciones en cada app.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| Valores JSONB junto a entidad, no EAV | ✅ |
| Definiciones tenant-owned + RLS | ✅ |
| Catálogo/clientes/proveedores soportados | ✅ |
| Tipos de campo tipados | ✅ |
| Requeridos con rollout seguro | ✅ |
| Cambios de reglas validan datos existentes | ✅ |
| item_type aplicable a campos de catálogo | ✅ |
| reglas ejecutables/regex no permitidas | ✅ |
| límites de payload/opciones | ✅ |
| validación server-side | ✅ |
| gateway `core_logic` | ✅ |
| gate estático | ✅ |
| pgTAP 25 assertions | ✅ |
| db reset + pgTAP | ⏳ T03/T04/T12 |
| ORG_A/ORG_B | ⏳ T07/T09/T14 |
| Flutter analyze/test | ⏳ T13 |

## Resultado

F5.3 queda cerrada a nivel de implementación. F5.4 puede consumir estas definiciones para formularios y navegación dinámica. El Gate del Bloque 5 continúa pendiente de validación dinámica final.