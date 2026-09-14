# Fase 2.1 — Helpers de autorización multi-tenant

## Estado

**IMPLEMENTADA EN CÓDIGO / PRUEBA DINÁMICA LOCAL PENDIENTE**

Migración:

- `supabase/migrations/20260907024638_saas_authorization_helpers.sql`
- commit: `659d0f1acca256b202467c528c2fd196b3c078c9`

Gate específico:

- `scripts/verify_saas_authorization.mjs`
- commit inicial del gate: `40555febaf8531f46b1553cc6aca1ffed20595df`
- integración al workflow existente: `314284d53a78191e89199a78ef674780f3eb4aeb`

No se aplicó DDL al proyecto Supabase remoto y la rama SaaS no fue añadida a los triggers de GitHub Actions.

## Objetivo

Crear una única capa canónica de autorización que pueda ser reutilizada por RLS, RPC y posteriormente Edge Functions sin depender de:

- `empleados.auth_id`;
- `empleados.rol`;
- `configuracion_negocio.id = 1`;
- un `organization_id` recibido desde Flutter/Web/Desktop;
- metadata editable por el usuario.

La identidad de autenticación sigue siendo `auth.uid()`, y la pertenencia empresarial se resuelve únicamente mediante `public.app_users` + `public.organizations`.

## Diseño de seguridad

Los helpers privilegiados viven en el schema no expuesto `private`, no en `public`.

La migración:

```sql
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA private TO authenticated;
```

Además revoca por defecto `EXECUTE` para futuras funciones creadas en ese schema.

Esto evita convertir un helper `SECURITY DEFINER` en un RPC público accidental.

## Helpers implementados

### `private.current_organization_id()`

Devuelve el tenant efectivo del usuario autenticado sólo cuando simultáneamente:

1. `app_users.user_id = auth.uid()`;
2. `app_users.status = 'active'`;
3. la organización vinculada tiene `status = 'active'`.

Si cualquiera de esas condiciones falla devuelve `NULL`.

La función es `STABLE SECURITY DEFINER` porque debe leer tablas de membership que están cerradas a acceso directo del cliente. Usa:

```sql
SET search_path = ''
```

y todas las referencias son schema-qualified.

### `private.is_active_user()`

Devuelve booleano reutilizando exclusivamente `current_organization_id()`.

No vuelve a implementar membership por separado.

### `private.current_base_role()`

Devuelve el rol base V1 (`admin` / `operador`) desde `app_users`, bajo las mismas condiciones de membership y organización activa.

Es un contrato transitorio: en Fase 4.5 la implementación podrá migrar hacia roles y permisos configurables sin obligar a reescribir todos los call-sites de RLS/RPC.

### `private.has_permission(text)`

Implementa un catálogo mínimo V1:

- `tenant.read` -> `admin`, `operador`;
- `tenant.write` -> `admin`, `operador`;
- `tenant.admin` -> sólo `admin`;
- cualquier permiso desconocido -> `false`.

El comportamiento es **deny-by-default**.

### `private.row_belongs_to_current_organization(uuid)`

Compara el `organization_id` de una fila con el tenant efectivo autenticado.

Será el patrón base para las policies tenant-owned:

```sql
organization_id = private.current_organization_id()
```

El cliente no decide el tenant efectivo.

### `private.require_current_organization_id()`

Versión estricta para RPC. Si no existe una membership activa dentro de una organización activa, aborta con SQLSTATE:

```text
42501 insufficient_privilege
```

De esta forma los RPC críticos pueden fallar explícitamente en vez de continuar con un tenant nulo.

## Privilegios

Todas las funciones tienen `REVOKE ALL` explícito para:

- `PUBLIC`;
- `anon`;
- `authenticated`.

Después se concede exclusivamente `EXECUTE` a `authenticated` para los helpers necesarios por RLS/RPC.

El schema `private` no necesita ser añadido a los schemas expuestos por PostgREST para que sus funciones puedan utilizarse dentro de policies mediante nombre schema-qualified.

## Decisiones deliberadas

### No usar JWT user metadata para autorización

No se usa `raw_user_meta_data`, `user_metadata` ni un claim editable por cliente para decidir empresa, rol o permisos.

### No duplicar lógica desde empleados

Los helpers legacy:

- `app_empleado_activo()`;
- `app_es_admin()`;

siguen existiendo temporalmente para compatibilidad de código legacy, pero **no son la fuente canónica del nuevo modelo SaaS**.

Su sustitución en policies/RPC se realizará en las siguientes fases.

### No aceptar organization_id como contexto

`current_organization_id()` no recibe parámetros. El tenant siempre se deriva desde la sesión autenticada.

## Gate estático

Se añadió `scripts/verify_saas_authorization.mjs`.

Valida como mínimo:

- schema `private`;
- cierre de privilegios;
- `SECURITY DEFINER` fuera de `public`;
- `search_path = ''`;
- resolución desde `app_users + organizations`;
- uso de `auth.uid()`;
- membresía activa;
- organización activa;
- permisos deny-by-default;
- `tenant.admin` reservado al admin;
- pertenencia por `organization_id`;
- error `42501` del helper estricto;
- ausencia de autorización basada en metadata editable;
- ausencia de `EXECUTE` para `PUBLIC/anon`.

Self-test ejecutado localmente sobre copia exacta de la migración:

```text
SaaS authorization self-test OK (5 contratos/casos).
SaaS authorization gate OK (Fase 2.1).
```

Los casos negativos del self-test comprueban que el gate rechaza:

1. `search_path` inseguro;
2. aceptar organizaciones suspendidas;
3. permiso desconocido con allow-by-default;
4. autorización basada en metadata editable.

## Relación con la documentación actual de Supabase

El diseño sigue el patrón recomendado actualmente por Supabase para RLS:

- mantener RLS en tablas expuestas;
- usar `auth.uid()` como identidad de sesión;
- ubicar helpers `SECURITY DEFINER` de autorización fuera del schema expuesto;
- fijar `search_path = ''` en funciones `SECURITY DEFINER`;
- schema-qualify las relaciones;
- revocar `EXECUTE` por defecto y conceder sólo lo necesario.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| tenant derivado server-side desde auth.uid() | ✅ |
| membership activa requerida | ✅ |
| organización activa requerida | ✅ |
| rol separado de empleados | ✅ |
| permisos deny-by-default | ✅ |
| helper de pertenencia tenant | ✅ |
| helper estricto para RPC | ✅ |
| SECURITY DEFINER fuera de public | ✅ |
| search_path seguro | ✅ |
| grants mínimos | ✅ |
| gate estático + self-test | ✅ |
| prueba dinámica con ADMIN_A/ADMIN_B | ⏳ T05/T07 local |
| sustitución total de helpers legacy | ⏳ Fases 2.2/2.3 |

## Dependencia detectada antes de Fase 2.2

El roadmap original situaba RLS multi-tenant completo antes de migrar las tablas operativas a `organization_id`.

Eso no es ejecutable literalmente: una tabla tenant-owned no puede aislarse correctamente por organización antes de poseer una clave tenant canónica.

Por lo tanto, Fase 2.2 establecerá y aplicará el patrón RLS a las tablas fundacionales ya tenant-aware. Los grupos operativos de Bloque 3 deberán aplicar el mismo patrón al incorporar su `organization_id`. El gate cross-tenant global no podrá declararse verde hasta que todas las superficies tenant-owned relevantes hayan sido migradas y probadas.

## Resultado

Fase 2.1 queda cerrada a nivel de diseño, migración y gate estático. La verificación dinámica completa se mantiene dentro del mapa maestro T05–T09 y se ejecutará sobre Supabase local limpio al final del roadmap.
