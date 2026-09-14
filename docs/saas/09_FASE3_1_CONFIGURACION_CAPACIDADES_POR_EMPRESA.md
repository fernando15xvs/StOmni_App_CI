# Fase 3.1 — Configuración y capacidades por empresa

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN INTEGRAL LOCAL PENDIENTE**

Esta fase elimina el singleton operativo de configuración/capacidades y convierte ese dominio en tenant-aware sin aplicar DDL al Supabase remoto.

Migración principal:

- `supabase/migrations/20260907030554_saas_domain_configuration_tenant.sql`

Gate específico:

- `scripts/verify_saas_domain_configuration.mjs`

Superficies runtime saneadas:

- `packages/core_logic/lib/services/configuracion_service.dart`
- `packages/core_logic/lib/business/data/business_profile_mapper.dart`
- `packages/core_logic/lib/business/data/supabase_business_profile_gateway.dart`
- `packages/core_logic/lib/features/facturacion/application/business_fiscal_profile_mapper.dart`

## Objetivo

Cada organización debe poseer exactamente su propia configuración y capacidades. Ningún cliente Flutter puede elegir el tenant mediante un identificador manipulable y ningún flujo nuevo puede depender de `configuracion_negocio.id = 1` o `business_capabilities.business_id = 1`.

## Backfill legacy fail-closed

La migración detecta el estado histórico sin `organization_id`.

Si existe una única configuración legacy sin tenant:

1. crea una organización UUID real;
2. usa los datos comerciales existentes para su nombre;
3. asigna `PE`, `PEN` y `America/Lima` al tenant histórico;
4. enlaza `configuracion_negocio` con esa organización;
5. enlaza `business_capabilities` con la misma organización;
6. migra las identidades Auth históricas de `empleados` hacia `app_users`;
7. enlaza cada empleado con la organización histórica y, cuando corresponde, con `app_user_id`.

La migración aborta si encuentra un estado ambiguo que no puede asignarse de forma segura.

No se utiliza UUID fijo ni se crea un nuevo singleton.

## Enforcement final del dominio

Después del backfill se endurece:

- `empleados.organization_id NOT NULL`;
- `configuracion_negocio.organization_id NOT NULL`;
- `business_capabilities.organization_id NOT NULL`;
- constraints transitorias de empleados validadas.

Configuración y capacidades quedan relacionadas por tenant mediante sus claves compuestas existentes.

## RPC tenant-aware

### `get_current_business_configuration_v1()`

Obtiene `organization_id` exclusivamente desde el contexto autenticado mediante los helpers de F2.1 y devuelve únicamente la configuración de ese tenant.

### `actualizar_configuracion_negocio_v1(jsonb)`

- deriva tenant server-side;
- exige `tenant.admin`;
- conserva el allowlist de campos editables;
- no permite modificar reglas fiscales sensibles fuera del contrato existente;
- actualiza exclusivamente la fila de la organización autenticada.

### `get_business_profile_v1()`

Devuelve configuración + capacidades de la organización autenticada. Ya no selecciona `id = 1`.

### `update_business_capabilities_v1(bigint,jsonb)`

- deriva tenant server-side;
- exige admin;
- mantiene optimistic locking mediante `revision`;
- actualiza únicamente `business_capabilities.organization_id = tenant actual`;
- mantiene invariantes de lotes/vencimientos/series.

## Sin bypass por Data API

Se retiró `UPDATE` directo para `configuracion_negocio` y `business_capabilities` al rol `authenticated`.

Motivo: RLS evita cross-tenant, pero una actualización directa todavía podría saltarse el allowlist fiscal o el control de revisión. Las escrituras de estas dos tablas quedan canalizadas por RPC.

## Helpers de capacidades

Los helpers que consultan capabilities dejaron de usar `business_id = 1`, incluyendo:

- `_business_services_enabled()`;
- `_business_variants_enabled()`;
- `_business_enforce_purchase_capability()`;
- `_business_enforce_new_sale_capabilities()`.

Estos helpers resuelven ahora la organización autenticada.

Esto no significa todavía que catálogo, compras o ventas estén completamente aislados: sus tablas operativas reciben tenant en F3.3–F3.6.

## Runtime Flutter/Core

### ConfiguracionService

- lectura mediante RPC tenant-aware;
- no consulta directamente `configuracion_negocio` por `id`;
- conserva `organization_id` devuelto por backend para Storage;
- elimina `_legacyWritableBusinessId`;
- logos bajo `<organization_uuid>/logos/...`.

### BusinessProfileMapper

Acepta IDs de configuración dinámicos no vacíos; ya no exige `business_id == '1'`.

### SupabaseBusinessProfileGateway

- elimina fallback `.eq('id', 1)`;
- elimina validación `businessId == '1'`;
- elimina cache key con sufijo `:1`;
- los errores de RPC no degradan a una lectura singleton insegura.

### BusinessFiscalProfileMapper

Ya no inventa `businessId = 1` cuando el backend no devuelve identificador.

## Storage de logos

Las escrituras del bucket `logos` se migran a policies tenant-aware:

- usuario administrador activo;
- primer segmento de la ruta igual al UUID de su organización;
- A no puede escribir en el prefijo de B.

El bucket continúa con su contrato de lectura pública existente; el endurecimiento integral de Storage se verifica en T11 y en los bloques que migren las demás superficies de archivos.

## Gate anti-singleton

Los cuatro archivos runtime saneados fueron retirados del baseline de deuda legacy de `verify_no_new_singletons.mjs`.

A partir de esta fase, reintroducir en esos archivos:

- `businessId = '1'`;
- `.eq('id', 1)`;
- caché `business_profile...:1`;
- fallback fiscal `1`;

se considera una regresión nueva y debe fallar el gate.

El baseline legacy restante queda limitado a superficies fiscales/GRE que se migrarán en F3.7/F2.4.

## Tests/contratos actualizados

Se actualizaron contratos que anteriormente esperaban el singleton:

- arquitectura de perfil fiscal;
- cleanup/prefijo de logos;
- pgTAP de `actualizar_configuracion_negocio_v1`;
- pgTAP de `get_business_profile_v1` y capabilities.

Los nuevos contratos exigen resolución tenant server-side y ausencia de IDs fijos.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| configuración vinculada a organización | ✅ |
| capabilities vinculadas a organización | ✅ |
| backfill legacy fail-closed | ✅ |
| `organization_id NOT NULL` final | ✅ |
| lectura de configuración tenant-aware | ✅ |
| escritura de configuración tenant-aware | ✅ |
| capabilities tenant-aware + revision | ✅ |
| escritura directa sensible revocada | ✅ |
| singleton eliminado del runtime de este dominio | ✅ |
| logos con prefijo tenant para escrituras | ✅ |
| gate específico versionado y conectado a CI | ✅ |
| `supabase db reset` completo | ⏳ T03/T18 |
| ORG_A vs ORG_B real | ⏳ T07/T12 |
| Flutter analyze/test completo | ⏳ T13 |

## Riesgos residuales correctamente diferidos

Todavía existen referencias a configuración/capabilities desde dominios que aún son globales. No deben confundirse con F3.1:

- catálogo/servicios/variantes -> F3.3;
- inventario -> F3.4;
- ventas/cotizaciones/pagos -> F3.5;
- compras -> F3.6;
- fiscal/GRE y Edge Functions tributarias -> F3.7/F2.4.

## Resultado

F3.1 queda cerrada a nivel de implementación y contrato. La configuración y las capacidades ya no tienen un negocio fijo como autoridad. El aislamiento dinámico final se demostrará en el mapa maestro T00–T19 sobre el commit candidato definitivo.
