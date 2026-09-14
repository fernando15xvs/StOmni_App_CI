# Fase 1.4 — Bootstrap seguro de nueva organización

## Estado

**IMPLEMENTADA EN CÓDIGO / PRUEBA INTEGRAL LOCAL T06 PENDIENTE**

Migración:

- `supabase/migrations/20260907023826_saas_secure_organization_bootstrap.sql`
- commit: `4bbf8c53c50bfc30a4dc07f108f068f683c0cc52`

Gate específico:

- `scripts/verify_saas_bootstrap.mjs`
- commit: `790e819a392bb23f5f394fa7b67cea5b052906d5`

No se aplicó DDL al Supabase remoto y no se ejecutó GitHub Actions.

## Problema previo

El roadmap exige que el alta técnica de una empresa sea atómica:

1. crear `organization`;
2. vincular el usuario autenticado como admin;
3. crear configuración inicial;
4. crear capacidades default.

El modelo legacy impedía hacerlo correctamente porque:

- `configuracion_negocio.id` tenía default constante;
- `business_capabilities` tenía `CHECK (business_id = 1)`;
- la configuración/capacidades aún no tenían vínculo tenant directo.

Crear tablas paralelas habría duplicado el dominio y generado deuda. La solución elegida es una transición aditiva compatible con el patrón `expand -> backfill -> enforce -> contract`.

## Cambios estructurales

### 1. IDs nuevos de configuracion_negocio dejan de ser constantes

Se crea:

```sql
public.configuracion_negocio_id_seq
```

La secuencia se posiciona tomando el `max(id)` existente y preserva correctamente el caso de tabla vacía mediante el parámetro `is_called` de `setval`.

Después:

```sql
ALTER COLUMN id SET DEFAULT nextval(...)
```

La fila legacy no cambia de identificador; sólo las filas nuevas dejan de depender del singleton.

### 2. configuracion_negocio recibe tenant

Se añade:

```sql
organization_id uuid
```

con:

- FK a `organizations(id)`;
- `UNIQUE (organization_id)` para una configuración por empresa;
- `UNIQUE (organization_id, id)` para soportar referencias tenant-qualified.

El campo queda nullable durante la transición para no inventar un tenant a la configuración legacy antes del backfill de Fase 3.1.

### 3. business_capabilities deja de ser singleton

Se elimina:

```text
business_capabilities_singleton
```

Se añade `organization_id uuid` con:

- FK a `organizations(id)`;
- una fila de capacidades por organización;
- FK compuesta `(organization_id, business_id)` hacia `configuracion_negocio(organization_id, id)`.

De este modo una fila de capacidades nueva no puede apuntar a la configuración de otra empresa.

## RPC bootstrap_organization_v1

Firma:

```sql
bootstrap_organization_v1(
  p_display_name text,
  p_country_code text,
  p_currency_code text,
  p_timezone text,
  p_legal_name text DEFAULT NULL
) RETURNS uuid
```

### Invariantes de seguridad

- **No existe parámetro `organization_id`.**
- el usuario se deriva con `auth.uid()`;
- se bloquea la fila de `auth.users` con `FOR UPDATE` para serializar bootstraps concurrentes del mismo usuario;
- un usuario que ya existe en `app_users` no puede bootstrapear otra empresa en V1;
- una identidad legacy todavía vinculada a `empleados.auth_id/app_user_id` debe migrarse y no puede crear silenciosamente una empresa diferente;
- el UUID de organización se crea en servidor;
- el primer `app_user` se crea con `base_role = 'admin'`;
- configuración y capacidades reciben el mismo `organization_id` generado;
- la función es `SECURITY DEFINER` porque necesita atravesar las tablas cerradas por RLS durante el onboarding;
- `search_path = pg_catalog` y todas las tablas sensibles están schema-qualified;
- `PUBLIC` y `anon` no pueden ejecutarla;
- `authenticated` recibe únicamente `EXECUTE` del RPC, no acceso directo a las tablas de fundación;
- no existe `EXCEPTION WHEN OTHERS` que convierta un fallo parcial en éxito.

## Atomicidad

La llamada RPC es una sola sentencia PostgreSQL. Si falla cualquiera de los inserts de:

- `organizations`;
- `app_users`;
- `configuracion_negocio`;
- `business_capabilities`;

la sentencia completa aborta y no debe dejar entidades huérfanas.

La verificación dinámica de rollback, doble bootstrap y dos admins distintos queda registrada como prueba crítica **T06** del mapa maestro final.

## Gate específico ejecutado

Se ejecutó localmente sobre una copia exacta de la migración y del script de gate:

```text
SaaS bootstrap self-test OK (4 contratos/casos).
SaaS bootstrap gate OK: 20260907023826_saas_secure_organization_bootstrap.sql
```

El self-test demuestra que el gate rechaza, como mínimo:

1. `organization_id` suministrado por el cliente;
2. un `business_id` fijo en el bootstrap;
3. captura genérica `WHEN OTHERS` que rompería la garantía de rollback.

## Compatibilidad PostgreSQL

El diseño fue contrastado con PostgreSQL 17 para:

- constraints `UNIQUE` multicolumna;
- FK compuesta hacia columnas con unicidad correspondiente;
- `setval(regclass, bigint, boolean)` y semántica de `is_called`.

## Lo que deliberadamente queda para fases posteriores

- backfill de la fila legacy de `configuracion_negocio`;
- backfill de `business_capabilities.organization_id` legacy;
- `NOT NULL` final de esos tenant IDs;
- reescritura de runtime que todavía busca configuración singleton;
- RLS multi-tenant de configuración/capacidades;
- migración completa de `get_business_profile_v1` y RPC relacionados;
- prueba real de dos organizaciones con dos usuarios Auth contra Supabase local.

Estas tareas pertenecen a Bloques 2/3 y a T03–T07/T12 del mapa de validación.

## Criterios de aceptación

| Criterio | Estado |
|---|---|
| organization creada server-side | ✅ |
| primer usuario ligado como admin | ✅ |
| configuración inicial creada | ✅ |
| capacidades default creadas | ✅ |
| cliente no proporciona organization_id | ✅ |
| operación diseñada como atómica | ✅ |
| singleton de capabilities eliminado | ✅ |
| nuevas configuraciones sin ID constante | ✅ |
| gate estático específico | ✅ |
| rollback real con fallo inducido | ⏳ T06 local |
| ORG_A + ADMIN_A y ORG_B + ADMIN_B reales | ⏳ T05/T06 local |
| aislamiento RLS entre ambas | ⏳ Bloque 2 / T07 |

## Resultado

La Fase 1.4 queda implementada sin crear un segundo modelo de configuración y sin confiar en identificadores tenant enviados por Flutter. El **Gate de Bloque 1 no debe declararse integralmente verde hasta ejecutar en local los escenarios de dos organizaciones y rollback** definidos en T05/T06.
