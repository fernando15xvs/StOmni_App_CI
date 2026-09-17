# Fase 9.3 — Backups y recuperación

## Estado

**IMPLEMENTADA COMO TOOLING Y POLÍTICA / RESTORE DRILL LOCAL PENDIENTE**

F9.3 deja versionados los mecanismos y contratos necesarios para respaldar, restaurar y exportar datos de StOmni SaaS sin declarar una recuperación como exitosa antes de ejecutarla realmente.

La fase incorpora:

- helpers comunes: `scripts/saas_backup_common.mjs`;
- snapshot local: `scripts/saas_backup_local.mjs`;
- restore drill local: `scripts/saas_restore_drill_local.mjs`;
- exportación por empresa: `scripts/saas_export_tenant.mjs`;
- gate estático: `scripts/verify_saas_backup_recovery.mjs`;
- política: `docs/saas/BACKUP_RECOVERY_POLICY.md`.

No se ejecutó GitHub Actions, no se aplicó DDL al Supabase remoto y no se ha marcado todavía ningún restore como dinámicamente verde.

## Contrato de recuperación

La recuperación se divide deliberadamente en capas:

1. `supabase/migrations/` reconstruye el esquema;
2. `pg_dump`/`pg_restore` conservan datos `public`;
3. un dump separado preserva `auth.users` y `auth.identities`;
4. los bytes reales de Storage se descargan y restauran fuera de PostgreSQL;
5. SHA-256 y fingerprints verifican integridad.

Esto evita tratar `storage.objects` como si contuviera el archivo físico.

## Backup local

`saas_backup_local.mjs` sólo acepta Supabase local por loopback.

Genera por defecto:

```text
.dart_tool/saas/backups/<timestamp>/
```

con:

- `public-data.dump`;
- `auth-identity-data.dump`;
- `storage/*.bin`;
- `manifest.json`.

El manifest registra:

- commit Git;
- estado dirty/clean del checkout;
- versiones `supabase`, `psql`, `pg_dump`, `pg_restore`;
- fingerprint de cada tabla `public`;
- fingerprint de `auth.users` y `auth.identities`;
- inventario de buckets;
- cada objeto Storage con tamaño y SHA-256.

El runner toma fingerprints antes y después del snapshot. Si cambian, el backup se rechaza en vez de aceptar un corte inconsistente.

## Restore drill

`saas_restore_drill_local.mjs` es destructivo por diseño y exige:

```text
STOMNI_ALLOW_DESTRUCTIVE_RESTORE=YES
```

Además:

- valida que DB/API sean loopback;
- valida formato, tamaños y SHA-256 del backup;
- exige el mismo commit del snapshot por defecto;
- sólo admite mismatch de schema con `STOMNI_ALLOW_SCHEMA_MISMATCH=YES` explícito;
- ejecuta `supabase db reset` para reconstruir el esquema;
- valida y usa `supabase_admin` únicamente contra la DB loopback local para que
  `pg_restore --disable-triggers` tenga el privilegio exigido por PostgreSQL;
- restaura Auth y datos de negocio con `pg_restore --data-only`;
- reconstruye Storage por API local;
- verifica exactamente fingerprints DB e hashes de Storage.

Sólo después genera:

```text
.dart_tool/saas/f9_3_restore_report.json
```

con estado:

```text
RESTORE_DRILL_GREEN
```

La existencia de este runner no significa que el restore ya haya sido probado. Ese resultado queda reservado para T18.

## Exportación por empresa

`saas_export_tenant.mjs` exige un `organization_id` UUID y exporta:

- la organización raíz;
- todas las tablas `public` con `organization_id`, siempre filtradas por ese tenant;
- Storage bajo `<organization_id>/...`;
- manifest con conteos, fingerprints y hashes.

No exporta:

- `auth.users`;
- hashes de contraseña;
- sesiones;
- refresh tokens;
- secretos;
- catálogos globales compartidos.

Por tanto, el export tenant sirve para portabilidad/auditoría de la empresa sin convertirse accidentalmente en un volcado de credenciales de plataforma.

## Producción alojada

La política separa el tooling local de la protección real en hosted.

En producción, la base debe usar los **backups administrados por Supabase** que correspondan al plan/proyecto efectivamente contratado. Si se utiliza PITR, su disponibilidad y ventana deben comprobarse sobre la configuración real.

Los scripts locales no deben ejecutarse contra `*.supabase.co`; el helper común falla cerrado ante hosts no loopback.

Storage requiere protección separada porque un backup lógico de PostgreSQL no sustituye los bytes almacenados.

## RPO, RTO y retención

Los valores comerciales de **RPO** y **RTO** **no se inventan** en F9.3.

Antes del GO deben definirse a partir de:

- plan Supabase real;
- backup/PITR realmente habilitado;
- volumen de DB/Storage;
- tiempo medido del restore drill;
- obligaciones comerciales acordadas.

La fase tampoco afirma una retención ficticia independiente del proveedor. El runbook definitivo deberá registrar la política realmente configurada.

## Gate F9.3

`scripts/verify_saas_backup_recovery.mjs` bloquea regresiones estructurales en:

- loopback-only para DB/API;
- captura separada de `public` y Auth identidad;
- backup de bytes Storage;
- snapshot consistente antes/después;
- opt-in destructivo exacto para restore;
- `supabase db reset` como fuente de esquema;
- `pg_restore` de datos;
- verificación DB + Storage antes de declarar `RESTORE_DRILL_GREEN`;
- export tenant filtrado por `organization_id`;
- exclusión de credenciales Auth en export;
- integración con el mapa maestro;
- Gate Bloque 9 todavía abierto.

El self-test incluye fuentes deliberadamente inseguras para comprobar que el gate detecta pérdida de Storage, opt-in débil, hashes no verificados y exposición Auth en export tenant.

## Validación de sintaxis

Durante la implementación se intentó ejecutar `node --check` desde un contenedor aislado del entorno de trabajo. Ese contenedor no tenía resolución DNS hacia GitHub y no pudo descargar los archivos de la rama.

Por tanto, **no se registra un falso verde de sintaxis**. La comprobación real queda en T02 sobre el checkout local del usuario, junto con el gate y su self-test.

## Integración en T00–T19

F9.3 debe quedar enlazada así:

- **T00:** registrar versiones de `psql`, `pg_dump`, `pg_restore`;
- **T02:** ejecutar gate F9.3 + self-test;
- **T12:** generar export ORG_A y ORG_B y comprobar que no existe mezcla;
- **T18:** crear snapshot, destruir/reconstruir Supabase local y ejecutar restore drill;
- **T19:** incorporar `f9_3_restore_report.json`, tiempo medido y decisión de RPO/RTO antes del GO.

## Resultado

F9.3 puede marcarse cerrada **a nivel de implementación** cuando tooling, política, gate, auditoría, checklist y mapa maestro estén versionados de forma coherente.

La recuperación **no está probada todavía**. El restore drill debe ejecutarse en T18 y el resultado final debe documentarse en T19.

El Gate Bloque 9 permanece abierto hasta cerrar F9.4–F9.6 y completar la validación final T00–T19.
