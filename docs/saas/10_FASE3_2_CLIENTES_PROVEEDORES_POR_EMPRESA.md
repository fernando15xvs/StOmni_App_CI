# Fase 3.2 — Clientes y proveedores por empresa

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Migración:

- `supabase/migrations/20260907032027_saas_customers_suppliers_tenant.sql`

Gate:

- `scripts/verify_saas_customers_suppliers.mjs`

Contrato pgTAP:

- `supabase/tests/database/customers_suppliers_tenant_contract_test.sql`

No se aplicó DDL al Supabase remoto y la rama SaaS continúa fuera de los triggers de GitHub Actions.

## Estado legacy observado

Lectura únicamente de metadata/estadísticas en el proyecto Supabase de laboratorio:

- `clientes`: `0` filas;
- `proveedores`: `0` filas;
- duplicados de documento cliente: `0`;
- duplicados de RUC proveedor: `0`;
- documentos/RUC vacíos: `0`.

No se consultaron datos personales.

Las policies legacy eran:

- clientes: CRUD condicionado sólo por `app_empleado_activo()`;
- proveedores: lectura por `app_empleado_activo()` y escritura por `app_es_admin()`.

## Tenant directo

Se añade a ambas tablas:

```sql
organization_id uuid NOT NULL
```

con FK hacia `organizations(id)` y `ON DELETE RESTRICT`.

También se crean claves:

```text
clientes      UNIQUE (organization_id, id)
proveedores   UNIQUE (organization_id, id)
```

Estas claves preparan las futuras FKs compuestas de ventas, cotizaciones, productos, gastos y compras para impedir referencias cross-tenant.

## Backfill fail-closed

Si existen clientes/proveedores históricos sin tenant, la migración sólo los asigna automáticamente cuando `configuracion_negocio` identifica exactamente **una organización empresarial**.

Si existen datos legacy y más de una organización candidata, la migración aborta en lugar de adivinar el tenant.

Después del backfill se exige `organization_id NOT NULL`.

## Unicidades por empresa

Se crean índices únicos normalizados por tenant:

```text
clientes:    (organization_id, btrim(dni_ruc))
proveedores: (organization_id, btrim(ruc))
```

Sólo aplican a valores no vacíos.

Consecuencias:

- el mismo documento/RUC puede existir en dos organizaciones distintas;
- no puede duplicarse dentro de la misma organización;
- diferencias accidentales de espacios no evitan la unicidad.

La migración comprueba duplicados antes de crear los índices y aborta si el estado histórico es ambiguo.

## Asignación server-side de tenant

Se crea el helper reutilizable:

```sql
private.enforce_row_organization_id()
```

Para usuarios autenticados normales:

- obtiene el tenant desde `private.current_organization_id()`;
- en INSERT asigna `NEW.organization_id` server-side;
- si el cliente intenta suministrar otra organización, rechaza la operación;
- en UPDATE `organization_id` es inmutable.

Para `service_role`/`postgres`:

- se exige un `organization_id` explícito;
- también se prohíbe cambiar el tenant de una fila existente.

Esto permite conservar los repositorios Flutter existentes: no deben conocer ni enviar el UUID del tenant para crear clientes/proveedores.

## RLS de clientes

Políticas nuevas:

- `clientes_tenant_select` -> `tenant.read` + misma organización;
- `clientes_tenant_insert` -> `tenant.write` + misma organización;
- `clientes_tenant_update` -> USING + WITH CHECK tenant-aware;
- `clientes_tenant_delete` -> `tenant.write` + misma organización.

Se conserva la semántica legacy: admin y operador activos pueden gestionar clientes.

## RLS de proveedores

Políticas nuevas:

- `proveedores_tenant_select` -> `tenant.read` + misma organización;
- INSERT/UPDATE/DELETE -> `tenant.admin` + misma organización.

Así se conserva el comportamiento legacy de escritura administrativa, pero ahora aislado por tenant.

## Grants explícitos

Debido al modelo actual de Data API de Supabase, las migraciones no dependen de exposición implícita de tablas. Se declaran grants explícitos a `authenticated` y se revoca acceso a `anon`.

RLS continúa siendo la capa de autorización por fila; grants y RLS se tratan como controles distintos.

## Runtime

No fue necesario inyectar `organization_id` en los repositorios Flutter/Core.

Los repositorios existentes pueden continuar con:

```text
.from('clientes')
.from('proveedores')
```

porque:

- SELECT/UPDATE/DELETE quedan filtrados por RLS;
- INSERT recibe tenant desde el trigger server-side;
- las comprobaciones de documento/RUC quedan naturalmente scopeadas por RLS.

Esto evita confiar en un tenant construido en UI.

## Relaciones diferidas

Actualmente existen FKs simples hacia estas tablas desde dominios que aún no han sido migrados:

Clientes:

- `ventas.cliente_id`;
- `cotizaciones.cliente_id`.

Proveedores:

- `productos.proveedor_id`;
- `gastos.proveedor_id`;
- `purchase_orders.supplier_id`.

No se modifican prematuramente. Sus FKs se convertirán a `(organization_id, id)` cuando cada tabla hija reciba tenant en F3.3/F3.5/F3.6.

## Gate estático

`verify_saas_customers_suppliers.mjs` comprueba entre otros:

- columnas tenant;
- FKs a organizations;
- claves compuestas por tabla;
- backfill ambiguo fail-closed;
- NOT NULL final;
- unicidad de documento/RUC por organización;
- trigger de asignación server-side;
- organization_id inmutable;
- RLS USING/WITH CHECK;
- escritura de proveedores restringida a admin;
- ausencia de helpers legacy;
- ausencia de grants a anon.

El gate fue endurecido para que las constraints de clientes no puedan satisfacer accidentalmente los checks de proveedores y viceversa.

## Contrato dinámico previsto

El pgTAP agregado verificará después de `supabase db reset`:

- esquema final;
- constraints e índices;
- triggers;
- policies nuevas;
- policies legacy ausentes;
- grants Data API.

La prueba real ORG_A/ORG_B queda en T07/T12.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| clientes con tenant directo | ✅ |
| proveedores con tenant directo | ✅ |
| backfill seguro | ✅ |
| tenant NOT NULL final | ✅ |
| documento cliente único por empresa | ✅ |
| RUC proveedor único por empresa | ✅ |
| INSERT deriva tenant server-side | ✅ |
| cliente no puede elegir otro tenant | ✅ |
| organization_id inmutable | ✅ |
| RLS clientes tenant-aware | ✅ |
| RLS proveedores tenant-aware | ✅ |
| FKs compuestas futuras preparadas | ✅ |
| pgTAP contract versionado | ✅ |
| prueba dinámica ORG_A/ORG_B | ⏳ T07/T12 |
| db reset completo | ⏳ T03/T18 |

## Resultado

F3.2 queda cerrada a nivel de implementación. Clientes y proveedores ya poseen ownership empresarial explícito y la API cliente puede seguir operando sin recibir autoridad sobre `organization_id`.
