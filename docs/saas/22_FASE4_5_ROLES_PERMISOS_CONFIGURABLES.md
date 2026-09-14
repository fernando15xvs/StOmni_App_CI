# Fase 4.5 — Roles y permisos configurables

## Estado

**IMPLEMENTADA EN CÓDIGO / VALIDACIÓN DINÁMICA LOCAL PENDIENTE**

Migraciones:

- `supabase/migrations/20260908041000_saas_configurable_roles_permissions.sql`
- `supabase/migrations/20260908041100_saas_permission_override_rls_scope.sql`

Gate:

- `scripts/verify_saas_configurable_roles.mjs`

Contrato pgTAP:

- `supabase/tests/database/configurable_roles_contract_test.sql`

No se aplicó DDL al proyecto Supabase remoto. La validación final se ejecutará localmente en T00–T19.

## Diseño

Se introduce RBAC configurable manteniendo `app_users.base_role` como raíz de seguridad de plataforma para `tenant.read`, `tenant.write` y `tenant.admin`.

Esto evita un problema circular: los permisos necesarios para administrar el propio RBAC no dependen del RBAC que se está modificando.

Los permisos de dominio sí pasan al modelo configurable:

```text
permissions
roles
role_permissions
employee_roles
employee_permission_overrides
```

## Catálogo de permisos

`permissions` es un catálogo global controlado por StOmni. Incluye inicialmente los códigos ya usados por el backend:

- `products.create`;
- `products.update`;
- `products.change_price`;
- `inventory.receive`;
- `inventory.adjust`;
- `sales.create`;
- `sales.discount`;
- `purchases.manage`;
- `reports.view_profit`;
- `business.configure`.

Los tenants no crean códigos arbitrarios: configuran qué roles reciben los códigos soportados por la aplicación.

## Roles por empresa

`roles` pertenece a `organization_id` y expone clave compuesta tenant-safe.

Cada organización recibe automáticamente:

- `admin` — rol de sistema con todos los permisos de dominio;
- `operator` — rol inicial compatible con el comportamiento anterior.

La creación de una organización futura genera ambos roles y sus permisos base automáticamente.

## Relación rol/permisos

`role_permissions` utiliza:

```text
(organization_id, role_id, permission_code)
```

La FK de rol incluye `organization_id`, por lo que una organización no puede asignar permisos a un rol perteneciente a otra.

## Asignación a empleados

`employee_roles` permite múltiples roles por empleado y usa dos FKs compuestas:

- empleado dentro del mismo tenant;
- rol dentro del mismo tenant.

Los empleados existentes reciben un rol inicial a partir del campo legacy `empleados.rol`. Los nuevos empleados reciben un rol inicial mediante trigger para mantener compatibilidad mientras la UI evoluciona.

`empleados.rol` deja de ser la fuente autoritativa de permisos de dominio; se conserva como compatibilidad transitoria.

## Overrides por empleado

`employee_permission_overrides` recibe `organization_id NOT NULL`.

Su PK pasa de:

```text
(employee_id, permission_code)
```

a:

```text
(organization_id, employee_id, permission_code)
```

También se elimina el CHECK hardcodeado de códigos y se reemplaza por FK al catálogo `permissions`.

La policy RLS fue corregida para referenciar explícitamente `employee_permission_overrides.organization_id`, evitando resolución ambigua dentro de subconsultas.

## `app_tiene_permiso`

La firma pública se conserva para no cambiar decenas de call-sites.

La implementación nueva:

1. obtiene el tenant desde `private.current_organization_id()`;
2. resuelve el empleado activo dentro del tenant;
3. reconoce el rol `admin` como acceso completo de dominio;
4. aplica override explícito si existe;
5. en ausencia de override, evalúa `employee_roles -> roles -> role_permissions`;
6. nunca consulta roles de otro tenant.

La función ya no usa `_app_role_base_permissions()` para decidir permisos efectivos.

## Compatibilidad con Flutter

Se mantienen las firmas existentes:

- `get_my_effective_permissions_v1()`;
- `get_employee_permission_settings_v1(bigint)`;
- `update_employee_permission_overrides_v1(bigint,jsonb)`.

Por debajo, las tres usan el RBAC tenant-aware nuevo.

Esto permite actualizar backend primero y adaptar la interfaz de administración de roles después sin romper el cliente actual.

## Administración de roles

Se añaden RPC:

- `create_role_v1`;
- `set_role_permissions_v1`;
- `set_employee_roles_v1`.

Todas derivan tenant server-side y exigen `tenant.admin`.

El rol de sistema `admin` no permite retirar sus permisos mediante `set_role_permissions_v1`, evitando dejar una empresa sin autoridad administrativa de dominio por error de configuración.

## RLS

`roles`, `role_permissions`, `employee_roles` y overrides aplican lectura tenant-aware.

`permissions` es un catálogo global de sólo lectura para usuarios autenticados.

Las mutaciones RBAC no se realizan directamente por Data API: pasan por RPC administrativas.

## Gate estático

`verify_saas_configurable_roles.mjs` verifica:

- existencia de las cuatro tablas RBAC;
- FKs tenant-qualified;
- roles base por empresa;
- bootstrap para organizaciones nuevas;
- overrides con ownership tenant;
- RLS con referencia externa explícita;
- `app_tiene_permiso` basado en role_permissions;
- ausencia de `_app_role_base_permissions` en el path efectivo;
- RPC administrativas;
- inmutabilidad de permisos del rol admin.

## Contrato dinámico previsto

`configurable_roles_contract_test.sql` contiene 22 assertions pgTAP.

T07/T09/T12 deberán probar además:

- rol A no visible/asignable desde B;
- empleado A no puede recibir rol B;
- mismo `code` de rol puede existir en tenants distintos;
- cambiar permisos de un rol A no afecta B;
- override A nunca afecta empleado B;
- operador sólo obtiene los permisos configurados;
- admin conserva permisos aunque existan overrides antiguos;
- RPC administrativas fallan para usuario no-admin.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| catálogo de permisos explícito | ✅ |
| roles por organización | ✅ |
| role_permissions tenant-aware | ✅ |
| employee_roles tenant-aware | ✅ |
| overrides tenant-aware | ✅ |
| app_tiene_permiso configurable | ✅ |
| firmas Flutter compatibles | ✅ |
| RPC de administración de roles | ✅ |
| rol admin protegido | ✅ |
| RLS RBAC | ✅ |
| gate estático versionado | ✅ |
| pgTAP versionado | ✅ |
| db reset completo | ⏳ T03/T18 |
| ataques ORG_A/ORG_B | ⏳ T07/T09/T12 |

## Resultado

F4.5 queda cerrada a nivel de implementación. StOmni deja de depender de una matriz fija `admin/operador` para permisos de dominio y pasa a roles configurables por empresa, conservando una raíz de seguridad independiente en `app_users.base_role` para administrar el propio tenant.
