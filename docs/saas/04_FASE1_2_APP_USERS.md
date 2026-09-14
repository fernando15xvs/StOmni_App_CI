# Fase 1.2 — `app_users`

Estado: **CERRADA / AUDITADA EN CÓDIGO**  
Rama: `feature/saas-multitenant-foundation`

## Objetivo

Separar la identidad de autenticación (`auth.users`) de la pertenencia/autorización de StOmni mediante `public.app_users`, garantizando por constraint la regla V1:

```text
una identidad Auth -> una sola organización
```

---

## 1. Migración creada

```text
supabase/migrations/20260907020815_saas_app_users.sql
```

Commit:

```text
a2a213f4cb705e096bf398bbe4ced907d8ef84f0
```

La tabla creada es:

```text
public.app_users
```

con:

- `user_id uuid primary key references auth.users(id) on delete cascade`;
- `organization_id uuid not null references organizations(id) on delete restrict`;
- `status text not null default 'active'`;
- `base_role text not null default 'operador'`;
- `created_at timestamptz not null default now()`;
- `updated_at timestamptz not null default now()`.

También se crea:

```text
UNIQUE (organization_id, user_id)
```

para permitir FKs compuestas tenant-aware desde `employees` y otras relaciones futuras.

---

## 2. Regla V1 garantizada por base

La decisión central no queda en Flutter ni en una validación de aplicación:

```text
app_users.user_id = PRIMARY KEY
```

Por ello un mismo `auth.users.id` no puede tener dos filas con organizaciones distintas.

Si en una versión futura StOmni admite una identidad con acceso a varias empresas, deberá existir una migración explícita hacia un modelo de memberships. La V1 no deja esa ambigüedad abierta.

---

## 3. Integridad de relaciones

### Auth

```text
app_users.user_id -> auth.users.id
```

usa `ON DELETE CASCADE`.

Motivo: si una identidad Auth es eliminada, su autorización StOmni no debe quedar huérfana. Más adelante, los helpers de acceso resolverán `auth.uid()` contra `app_users`; una fila inexistente significará acceso denegado.

### Organización

```text
app_users.organization_id -> organizations.id
```

usa `ON DELETE RESTRICT`.

StOmni modela cierre/suspensión mediante `organizations.status`, no mediante borrado físico automático del tenant.

---

## 4. Estados y rol base

Estados admitidos:

```text
active
disabled
```

Roles base V1:

```text
admin
operador
```

`base_role` es deliberadamente transitorio: permite migrar el comportamiento actual sin bloquear el futuro modelo configurable del Bloque 4.

---

## 5. Inmutabilidad

Se añadió:

```text
public._app_users_before_update()
trg_app_users_before_update
```

que impide cambiar en una fila existente:

- `user_id`;
- `organization_id`.

Mover una identidad a otra organización no es una operación normal de actualización en V1; deberá tratarse como una operación administrativa/migración explícita y auditable.

El trigger también mantiene `updated_at` con `clock_timestamp()`.

---

## 6. Seguridad

`app_users` nace con RLS habilitado:

```sql
ALTER TABLE public.app_users ENABLE ROW LEVEL SECURITY;
```

Y sin acceso directo de clientes:

```sql
REVOKE ALL ON TABLE public.app_users FROM PUBLIC, anon, authenticated;
```

No hay policy temporal permisiva. El acceso cliente se abrirá sólo cuando existan los helpers tenant-aware del Bloque 2.

La función de trigger es:

- `SECURITY INVOKER`;
- `search_path = pg_catalog`;
- no ejecutable directamente como RPC por `PUBLIC`, `anon` o `authenticated`.

---

## 7. Compatibilidad Auth verificada

Se consultó el proyecto de laboratorio `StOmniApp` de forma read-only.

`auth.users.id` reportó:

```text
data_type = uuid
udt_name = uuid
is_nullable = NO
```

Por tanto el FK definido en la migración coincide con la identidad real de Supabase Auth.

No se leyó información personal de usuarios ni se modificó Auth.

---

## 8. Gate estático actualizado

`scripts/verify_saas_foundation.mjs` fue ampliado para verificar tanto:

- `organizations`;
- `app_users`.

Commit:

```text
1f6aeb9dd0eda71d5b0ec7bb7675df87fc390430
```

El gate comprueba en `app_users`:

- FK a `auth.users`;
- FK a `organizations`;
- PK de `user_id`;
- clave única compuesta `(organization_id, user_id)`;
- estados válidos;
- roles base válidos;
- timestamps;
- RLS;
- ausencia de grants directos a cliente;
- inmutabilidad de `user_id` y `organization_id`;
- helper `SECURITY INVOKER` con `search_path` fijo;
- ausencia de dependencias singleton legacy.

Resultados ejecutados sobre el contenido antes de versionarlo:

```text
SaaS foundation self-test OK (3 contratos/casos).
SaaS foundation gate OK (2 migraciones).
```

---

## 9. Qué no hizo esta fase

Todavía no se realizó:

- backfill de usuarios existentes;
- creación de organización legacy;
- migración de `empleados.auth_id`;
- creación de empleados sin login;
- policies tenant-aware;
- bootstrap de empresa;
- modificación del proyecto remoto.

Esos puntos pertenecen a las Fases 1.3, 1.4 y Bloque 2.

---

## 10. Criterios de aceptación

- [x] `app_users` creada en migración reproducible;
- [x] `user_id` referencia `auth.users(id)`;
- [x] `organization_id` referencia `organizations(id)`;
- [x] una identidad sólo puede pertenecer a una empresa en V1;
- [x] clave compuesta disponible para FKs tenant-aware;
- [x] estados restringidos;
- [x] rol base restringido;
- [x] `user_id` y `organization_id` inmutables;
- [x] RLS habilitado;
- [x] sin acceso cliente directo;
- [x] contrato Auth UUID verificado read-only;
- [x] gate estático ampliado y verde;
- [x] sin datos/backfill prematuros;
- [x] sin dependencia singleton.

## Resultado

**Fase 1.2 APROBADA EN LA RAMA.**

Siguiente fase autorizada:

```text
Fase 1.3 — separar empleados de identidad/login
```
