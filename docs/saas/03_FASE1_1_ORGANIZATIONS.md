# Fase 1.1 — `organizations`

Estado: **CERRADA / AUDITADA EN CÓDIGO**  
Rama: `feature/saas-multitenant-foundation`

## Objetivo

Crear la entidad raíz multi-tenant de StOmni sin migrar todavía datos operativos ni convertir `configuracion_negocio`.

La fase implementa el contrato congelado en Fase 0.2 y mantiene el cambio aditivo para que las siguientes fases puedan construir `app_users`, bootstrap y aislamiento encima de una raíz estable.

---

## 1. Migración creada

```text
supabase/migrations/20260907020334_saas_organizations.sql
```

Commit de la migración:

```text
153837f9cb7bd7892556cf8be4fcde40f6c91f2b
```

La migración crea:

```text
public.organizations
```

con:

- `id uuid primary key default gen_random_uuid()`;
- `legal_name text null`;
- `display_name text not null`;
- `country_code text not null`;
- `currency_code text not null`;
- `timezone text not null`;
- `status text not null default 'active'`;
- `created_at timestamptz not null default now()`;
- `updated_at timestamptz not null default now()`.

No se crea ninguna organización real ni se hace backfill en esta fase.

---

## 2. Invariantes implementadas

### UUID de tenant

`organizations.id` usa UUID generado por PostgreSQL mediante `gen_random_uuid()`.

El ID no deriva de RUC, configuración legacy, país, plan ni ningún dato comercial.

### ID inmutable

Se añadió el trigger:

```text
trg_organizations_before_write
```

respaldado por:

```text
public._organizations_before_write()
```

Un `UPDATE` que intente cambiar `organizations.id` falla con SQLSTATE `23514`.

### Estado

Sólo se permiten:

```text
active
suspended
closed
```

### País y moneda

La base valida formato canónico:

- país: exactamente dos letras mayúsculas;
- moneda: exactamente tres letras mayúsculas.

La semántica corresponde a ISO 3166-1 alpha-2 e ISO 4217, respectivamente.

### Zona horaria

Además de impedir valores vacíos, el trigger valida que el valor exista en:

```text
pg_catalog.pg_timezone_names
```

De esta forma no queda limitada a `America/Lima` ni a Perú.

### `updated_at`

En cada actualización válida, el trigger reemplaza `updated_at` con `clock_timestamp()`.

---

## 3. Seguridad desde el nacimiento de la tabla

La tabla se crea con:

```sql
ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;
```

Y, como defensa adicional:

```sql
REVOKE ALL ON TABLE public.organizations FROM PUBLIC, anon, authenticated;
```

No se crea todavía ninguna policy de cliente porque la Fase 1.1 aún no tiene `app_users` ni helpers seguros para resolver el tenant autenticado.

Las policies se abrirán después de construir el modelo de pertenencia y autorización, no mediante una policy temporal permisiva.

El helper de trigger es `SECURITY INVOKER`, usa `search_path = pg_catalog` y tiene `EXECUTE` revocado para `PUBLIC`, `anon` y `authenticated` como RPC directa.

---

## 4. Compatibilidad con Supabase actual verificada

Antes de cerrar la fase se revisó el changelog/documentación actual de Supabase.

Hallazgo relevante de 2026: las tablas nuevas pueden no quedar expuestas automáticamente a Data API según la configuración del proyecto; grants y RLS son capas separadas. La migración de StOmni no depende de exposición implícita y deja `organizations` cerrada a cliente de forma explícita.

Se hizo además una comprobación **sólo de lectura** contra el proyecto de laboratorio `StOmniApp`.

Proyecto detectado:

```text
PostgreSQL 17.6
estado ACTIVE_HEALTHY
```

Consulta de compatibilidad:

```text
uuid_generation_ok = true
timezone_catalog_ok = true
```

Esto confirma que el laboratorio dispone de:

- `gen_random_uuid()`;
- `pg_catalog.pg_timezone_names`;
- entrada `America/Lima` en el catálogo de zonas horarias.

No se ejecutó DDL sobre el proyecto remoto.

---

## 5. Gate estático de la fundación

Se añadió:

```text
scripts/verify_saas_foundation.mjs
```

Commit:

```text
fc0dc3a5a4ac760b2d291b860bd0e5764f0dbae1
```

El gate verifica que la migración conserve:

- tabla `public.organizations`;
- UUID generado;
- campos obligatorios del contrato;
- estados válidos;
- timestamps;
- RLS habilitado;
- revocación de acceso cliente;
- ID inmutable;
- actualización automática de `updated_at`;
- validación de timezone;
- `SECURITY INVOKER`;
- `search_path` fijo;
- ausencia de grants directos a `anon/authenticated`;
- ausencia de dependencia ejecutable de `business_id`, `configuracion_negocio` o `id = 1`.

Durante el desarrollo, el primer pase detectó un falso positivo causado por un comentario de la migración. El verificador se corrigió para evaluar la dependencia singleton sobre SQL ejecutable, no sobre comentarios.

Resultados finales ejecutados sobre el mismo contenido versionado:

```text
SaaS foundation self-test OK (2 casos).
SaaS foundation gate OK: 20260907020334_saas_organizations.sql
```

El self-test cubre al menos:

1. contrato válido aceptado;
2. grant inseguro a `authenticated` rechazado.

---

## 6. Integración con CI

El workflow existente incorpora ahora:

```bash
node scripts/verify_saas_foundation.mjs --self-test
node scripts/verify_saas_foundation.mjs
```

Commit:

```text
abde1dbc262481db92286e04dd31cbdb7ed564bb
```

La rama `feature/saas-multitenant-foundation` sigue sin estar añadida a los triggers de `push`, por lo que este trabajo no consume GitHub Actions mientras se mantenga el flujo acordado.

---

## 7. Qué no hizo esta fase

Intencionalmente todavía no se realizó:

- creación de `app_users`;
- vínculo con `auth.users`;
- creación de organización legacy;
- backfill de datos existentes;
- modificación de `configuracion_negocio`;
- modificación de `business_capabilities`;
- policies de acceso por organización;
- migración del dominio operativo;
- aplicación de la migración al proyecto remoto.

Esto evita adelantar dependencias que pertenecen a las Fases 1.2–3.x.

---

## 8. Criterios de aceptación

- [x] `organizations` definida como raíz de tenant;
- [x] UUID opaco generado en PostgreSQL;
- [x] nombre legal/comercial modelado;
- [x] país, moneda y zona horaria modelados;
- [x] estados `active | suspended | closed` restringidos;
- [x] timestamps implementados;
- [x] UUID inmutable a nivel de base;
- [x] timezone validada contra catálogo PostgreSQL;
- [x] RLS habilitado desde la creación;
- [x] sin acceso directo de `anon/authenticated`;
- [x] helper de trigger `SECURITY INVOKER` con `search_path` seguro;
- [x] gate estático implementado y verde;
- [x] primitivas PostgreSQL verificadas en laboratorio mediante consulta read-only;
- [x] sin dependencia del singleton legacy;
- [x] sin backfill ni cambios destructivos.

## Resultado

**Fase 1.1 APROBADA EN LA RAMA.**

La migración queda preparada para formar parte del reset/apply controlado del entorno cuando se ejecute la validación integral. No se alteró la base remota durante esta fase, evitando divergencia de historial de migraciones.

Siguiente fase autorizada:

```text
Fase 1.2 — app_users con una sola empresa por usuario
```
