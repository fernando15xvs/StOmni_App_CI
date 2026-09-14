# Fase 1.3 — Separación de empleado e identidad de acceso

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN FINAL LOCAL PENDIENTE**

Esta fase implementa la separación estructural entre la ficha laboral `public.empleados` y la identidad de acceso a StOmni (`auth.users` + `public.app_users`). No se aplicó DDL al proyecto Supabase remoto durante esta fase.

Migración:

- `supabase/migrations/20260907022207_saas_employees_identity_separation.sql`
- commit de implementación: `fb0a31b949a5e685764811a9e2a978ca354e1900`

Gate estático ampliado:

- `scripts/verify_saas_foundation.mjs`
- commit de ampliación del gate: `0cf975a3f7090742146340678ca706b980e104b1`

## Objetivo

Un empleado es una entidad del dominio de una empresa y puede existir sin poseer una cuenta de acceso. Si necesita iniciar sesión, la asociación con una identidad de aplicación debe ser explícita, opcional y pertenecer a la misma organización.

## Cambios implementados

### 1. Tenant explícito en empleados

Se añadió:

```sql
organization_id uuid
```

con FK hacia `public.organizations(id)` y `ON DELETE RESTRICT`.

La migración incorpora:

```sql
CHECK (organization_id IS NOT NULL) NOT VALID
```

Esto sigue el patrón `expand -> backfill -> enforce -> contract`: las filas históricas aún no migradas pueden existir temporalmente, pero no se permite seguir creando/modificando datos sin tenant una vez que la migración sea aplicada.

### 2. Login opcional

Se añadió:

```sql
app_user_id uuid NULL
```

`NULL` significa que el empleado no posee una cuenta de acceso a StOmni.

Se añadió `UNIQUE (app_user_id)`, por lo que una identidad de aplicación no puede estar asociada simultáneamente a dos empleados.

### 3. Enlace tenant-safe con app_users

Se añadió la FK compuesta:

```sql
(organization_id, app_user_id)
  -> public.app_users(organization_id, user_id)
```

Esto impide vincular un empleado de la Empresa A con un usuario perteneciente a la Empresa B.

### 4. Transición desde auth_id legacy

`empleados.auth_id` **no se elimina todavía**. Se conserva sólo por compatibilidad durante la migración del runtime y de las políticas legacy.

Se añadió una restricción transitoria `NOT VALID` que exige, cuando ambos campos estén presentes:

```sql
auth_id = app_user_id
```

Así se evita que la identidad legacy y la nueva identidad apunten a personas diferentes durante el periodo de transición.

### 5. Email deja de ser identidad global

La restricción global:

```text
empleados_email_key UNIQUE(email)
```

se elimina.

En su lugar se crea:

```sql
UNIQUE (organization_id, email) NULLS NOT DISTINCT
WHERE email IS NOT NULL
```

Consecuencia esperada:

- misma empresa + mismo email -> rechazado;
- empresas distintas + mismo email -> permitido;
- el email del empleado queda tratado como dato de contacto empresarial y no como identidad de autenticación global.

`NULLS NOT DISTINCT` también evita que las filas legacy sin `organization_id` creen duplicados de email mientras el backfill todavía no se haya ejecutado.

### 6. Índice tenant

Se añadió:

```sql
CREATE INDEX empleados_organization_id_idx
  ON public.empleados (organization_id);
```

para preparar filtros y políticas tenant-aware posteriores.

## Estado observado en laboratorio antes de aplicar la migración

Consulta únicamente de lectura sobre el proyecto Supabase de laboratorio:

- empleados totales: `1`;
- empleados con `auth_id`: `1`;
- empleados sin `auth_id`: `0`;
- empleados con email: `1`;
- `auth_id` duplicados: `0`;
- `auth_id` ya era nullable;
- existía una unicidad global sobre `email`;
- las policies actuales de `empleados` siguen siendo legacy y no son tenant-aware.

No se consultaron datos personales de la fila de empleado.

## Lo que deliberadamente NO hace esta fase

Esta fase no adelanta responsabilidades de bloques posteriores:

- no crea una organización ficticia ni singleton para rellenar datos;
- no hace backfill de `organization_id`;
- no hace backfill de `app_user_id`;
- no valida todavía las restricciones `NOT VALID`;
- no convierte todavía `organization_id` a `NOT NULL` físico;
- no elimina `auth_id` legacy;
- no elimina todavía `rol` legacy;
- no sustituye las policies RLS actuales; eso corresponde al Bloque 2;
- no modifica todavía `configuracion_negocio` ni `business_capabilities`; eso corresponde a la migración de configuración/capacidades;
- no aplica DDL al Supabase remoto.

## Validación estática ejecutada

El gate `scripts/verify_saas_foundation.mjs` ahora inspecciona las migraciones de:

1. `organizations`;
2. `app_users`;
3. separación de empleados.

Resultado local del gate sobre los archivos exactos antes de subir los cambios:

```text
SaaS foundation self-test OK (5 contratos/casos).
SaaS foundation gate OK (3 migraciones).
```

El gate verifica, entre otros puntos:

- `organization_id` presente;
- `app_user_id` opcional;
- FK de organización;
- FK compuesta tenant-safe;
- un `app_user` como máximo por empleado;
- transición consistente `auth_id/app_user_id`;
- eliminación de la unicidad global del correo;
- unicidad del correo por organización;
- preservación temporal de `auth_id`;
- ausencia de grants cliente inseguros;
- ausencia de nuevas dependencias singleton.

## Criterios de aceptación de la fase

| Criterio | Estado |
|---|---|
| Un empleado puede existir sin login | ✅ Estructuralmente permitido (`app_user_id NULL`) |
| Un empleado con login se enlaza opcionalmente a `app_users` | ✅ |
| El enlace no puede cruzar organizaciones | ✅ FK compuesta |
| Un `app_user` no puede representar dos empleados | ✅ UNIQUE |
| Email de empleado deja de ser globalmente único | ✅ |
| Datos históricos no se fuerzan a un tenant inventado | ✅ |
| Compatibilidad legacy preservada para migración gradual | ✅ |
| RLS multi-tenant final | ⏳ Bloque 2 |
| Backfill/enforcement final | ⏳ Bloques de migración posteriores |
| Suite completa local/Flutter/Supabase | ⏳ Validación final del roadmap |

## Riesgo residual controlado

Hasta que se complete el backfill y el Bloque 2, las policies legacy de `empleados` siguen sin proporcionar aislamiento multiempresa. Por esa razón esta migración **no debe interpretarse como autorización multi-tenant completa** ni utilizarse todavía para habilitar producción multiempresa.

## Resultado

La Fase 1.3 queda cerrada a nivel de diseño e implementación de esquema. La prueba integral se conserva como pendiente para el mapa maestro de validación final, que deberá ejecutarse sobre una base Supabase local limpia junto con las pruebas Flutter y de aislamiento entre dos organizaciones.
