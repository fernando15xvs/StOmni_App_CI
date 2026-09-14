# Fase 2.2 — RLS multi-tenant de la fundación

## Estado

**IMPLEMENTADA EN CÓDIGO PARA LA FUNDACIÓN TENANT-AWARE / COBERTURA OPERATIVA SE COMPLETA EN BLOQUE 3**

Migración:

- `supabase/migrations/20260907025411_saas_foundation_rls.sql`
- commit: `89fc15859981d75062227f89ed65d364a3e10a07`

Gate específico:

- `scripts/verify_saas_rls.mjs`
- commit: `6b6faeecfd6b899faed8b63b6c9c43ceb1370af0`
- integración al workflow: `bcaffdbd73d6ce04f3d97c4d5538826be1b45ade`

No se aplicó DDL al Supabase remoto y la rama SaaS sigue fuera de los triggers de GitHub Actions.

## Alcance real de esta fase

El roadmap original situaba RLS multi-tenant antes de que Bloque 3 añadiera `organization_id` a las tablas operativas.

Eso crea una dependencia imposible: una tabla tenant-owned no puede aislarse correctamente por empresa si todavía no posee un tenant canónico.

Por ello la fase se divide de forma explícita:

1. **Fase 2.2 cierra el patrón RLS y lo aplica a todas las tablas de fundación que ya poseen `organization_id`.**
2. **Cada fase de Bloque 3 debe aplicar el mismo patrón RLS al mismo tiempo que migra sus tablas operativas.**
3. El gate global de aislamiento no puede marcarse verde hasta terminar esa cobertura y ejecutar T07.

Esto evita crear policies provisionales basadas en relaciones indirectas o en el singleton legacy.

## Tablas cubiertas ahora

La migración protege:

- `public.organizations`;
- `public.app_users`;
- `public.empleados`;
- `public.configuracion_negocio`;
- `public.business_capabilities`.

## Principio de autorización

Todas las policies tenant-aware resuelven la empresa con:

```sql
(SELECT private.current_organization_id())
```

El `organization_id` almacenado en la fila debe coincidir con ese tenant.

No se usa:

- `empleados.auth_id` como fuente de tenant;
- `empleados.rol` como autorización canónica;
- `app_empleado_activo()`;
- `app_es_admin()`;
- `business_id = 1`;
- identificador de empresa enviado desde Flutter.

## Grants y RLS son controles separados

Para cada tabla la migración primero revoca acceso de cliente:

```sql
REVOKE ALL ... FROM PUBLIC, anon, authenticated;
```

Después concede únicamente las operaciones requeridas.

Las policies RLS deciden qué filas de esas operaciones son accesibles.

Este patrón evita asumir que una policy por sí sola concede o revoca privilegios de tabla.

## `organizations`

Acceso directo de cliente:

- `SELECT`: permitido únicamente sobre la organización efectiva del usuario activo;
- `INSERT`: no concedido;
- `UPDATE`: no concedido;
- `DELETE`: no concedido.

El alta de organización continúa siendo responsabilidad del bootstrap server-side.

Esto también evita que un administrador empresarial pueda cambiar directamente el estado de su organización (`active/suspended/closed`) desde un cliente normal.

## `app_users`

Acceso directo:

- `SELECT` únicamente.

Policy:

- la fila debe pertenecer al tenant actual;
- un operador sólo ve su propia membership;
- un admin puede listar memberships de su organización.

No se concede INSERT/UPDATE/DELETE directo porque la gestión de membresías deberá pasar por flujos controlados y no por escritura arbitraria de UUIDs Auth.

## `empleados`

Se eliminan las policies legacy:

- `empleados_admin_delete`;
- `empleados_admin_insert`;
- `empleados_admin_update`;
- `empleados_select_activos`.

Nuevas reglas:

### SELECT

Requiere:

- fila del tenant actual;
- permiso `tenant.read`.

### INSERT

Requiere:

- `organization_id` del tenant actual;
- permiso `tenant.admin`.

### UPDATE

Incluye obligatoriamente ambos lados de seguridad:

```sql
USING (...)
WITH CHECK (...)
```

De este modo un admin no puede seleccionar una fila válida y luego moverla a otra organización mediante UPDATE.

### DELETE

Sólo admin dentro del tenant actual.

Se conserva acceso a la secuencia `empleados_id_seq` para soportar inserciones autorizadas con ID por defecto.

## `configuracion_negocio`

Se elimina `configuracion_select`, que todavía dependía de `app_empleado_activo()`.

Acceso cliente:

- `SELECT`: usuario activo del tenant con `tenant.read`;
- `UPDATE`: sólo admin del tenant;
- `INSERT/DELETE`: no se conceden directamente.

Las filas legacy con `organization_id IS NULL` quedan fuera de estas policies. Su backfill corresponde a Fase 3.1.

## `business_capabilities`

Se elimina `business_capabilities_read`, también legacy.

Acceso cliente:

- `SELECT`: tenant actual + `tenant.read`;
- `UPDATE`: tenant actual + `tenant.admin`;
- `INSERT/DELETE`: no directos.

El bootstrap conserva su INSERT privilegiado server-side porque la función `SECURITY DEFINER` corre con el owner y no se usa `FORCE ROW LEVEL SECURITY`.

## Por qué no se usa FORCE RLS

No se activa `FORCE ROW LEVEL SECURITY` en estas tablas porque los helpers privados y el bootstrap usan funciones `SECURITY DEFINER` que deben leer/escribir la fundación de forma controlada.

Forzar RLS al owner podría reintroducir recursión o impedir el bootstrap.

La seguridad se mantiene mediante:

- funciones privilegiadas mínimas;
- schema privado para helpers;
- `search_path` fijado;
- grants de `EXECUTE` explícitos;
- tenant resuelto desde `auth.uid()`.

## Compatibilidad con la guía actual de Supabase

La implementación sigue los puntos relevantes de la guía RLS actual:

- RLS habilitado en tablas expuestas;
- grants explícitos y separados de las policies;
- `TO authenticated` combinado con predicado de autorización, no usado como autorización suficiente;
- UPDATE con `USING` + `WITH CHECK`;
- helper calls constantes por sentencia envueltas en `SELECT` cuando no dependen de la fila;
- `auth.uid()` utilizado para identidad de sesión.

## Gate estático

`scripts/verify_saas_rls.mjs` valida:

- RLS habilitado en las cinco tablas;
- `REVOKE ALL` previo;
- grants mínimos por tabla;
- policies con comparación contra `current_organization_id()`;
- lectura de `app_users` limitada a self/admin;
- escritura de empleados limitada a admin;
- `USING` + `WITH CHECK` para UPDATE;
- retiro explícito de las policies legacy;
- ausencia de `app_es_admin()` y `app_empleado_activo()` en las nuevas policies;
- ausencia de `FORCE RLS` en esta etapa;
- ausencia de tenant singleton.

Resultado ejecutado localmente sobre copia exacta:

```text
SaaS RLS self-test OK (5 contratos/casos).
SaaS RLS gate OK (Fase 2.2 fundación).
```

Los casos negativos verifican que el gate rechaza:

1. una policy sin tenant;
2. un UPDATE sin `WITH CHECK`;
3. reintroducción de helpers legacy;
4. `FORCE RLS` incompatible con el diseño privilegiado actual.

## Estado de cobertura

| Superficie | Estado |
|---|---|
| organizations | ✅ |
| app_users | ✅ |
| empleados | ✅ fundación; backfill final pendiente |
| configuracion_negocio | ✅ policy; backfill/runtime pendiente F3.1 |
| business_capabilities | ✅ policy; backfill/runtime pendiente F3.1 |
| clientes/proveedores | ⏳ F3.2 |
| catálogo | ⏳ F3.3 |
| inventario/almacenes | ⏳ F3.4 |
| ventas/pagos | ⏳ F3.5 |
| compras | ⏳ F3.6 |
| fiscal/GRE | ⏳ F3.7 |
| test dinámico cross-tenant | ⏳ T07 / F2.5 |

## Resultado

El patrón RLS multi-tenant queda cerrado y aplicado a la fundación. No se declara todavía aislamiento global del producto: esa afirmación sólo será válida cuando cada dominio de Bloque 3 tenga `organization_id`, adopte el mismo patrón y la suite T07 demuestre A→B y B→A bloqueados.
