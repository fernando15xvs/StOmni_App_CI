# Política de backups y recuperación — StOmni SaaS

## Alcance

Esta política cubre la recuperación de StOmni SaaS para:

- esquema PostgreSQL versionado;
- datos empresariales en `public`;
- identidad mínima necesaria de Supabase Auth;
- objetos binarios de Supabase Storage;
- exportación de datos por organización.

No autoriza ejecutar scripts destructivos contra producción ni sustituye los mecanismos administrados del proveedor de infraestructura.

## Principio de recuperación

StOmni separa cuatro responsabilidades:

1. **Esquema:** se reconstruye desde `supabase/migrations/` en el commit exacto del backup.
2. **Datos de negocio:** se recuperan desde backup lógico PostgreSQL.
3. **Identidad Auth:** se preservan `auth.users` y `auth.identities`; sesiones y tokens efímeros no forman parte del export tenant.
4. **Storage:** los bytes se respaldan fuera del dump PostgreSQL y cada objeto lleva SHA-256.

El metadata de una fila `storage.objects` no equivale al archivo binario. Una recuperación sólo es válida cuando los bytes reales también están disponibles y su hash coincide.

## Producción alojada

En un despliegue comercial alojado en Supabase:

- la protección primaria de base de datos debe usar los backups administrados disponibles en el plan/proyecto contratado;
- cualquier capacidad PITR debe configurarse y verificarse según el plan realmente adquirido;
- no se debe declarar un RPO/RTO más estricto que el que soporte la configuración real del proveedor;
- las migraciones del repositorio siguen siendo la fuente de verdad del esquema de aplicación;
- los objetos de Storage requieren una estrategia de protección separada de los dumps de PostgreSQL.

Los scripts `scripts/saas_*_local.mjs` son herramientas de laboratorio y validación. Están diseñados para endpoints loopback y deben fallar cerrado ante URLs remotas.

## RPO, RTO y retención

Los valores comerciales de **RPO**, **RTO** y retención **no se inventan en el código**.

Antes del GO comercial deben quedar registrados en `docs/saas/FINAL_VALIDATION_REPORT.md` o en el runbook operativo definitivo, basados en:

- plan Supabase contratado;
- frecuencia de backup/PITR realmente habilitada;
- tamaño real de DB y Storage;
- tiempo medido en restore drill;
- criticidad contractual del negocio.

Si esos valores no están seleccionados y demostrados, el release no puede afirmar un SLA de recuperación.

## Backup lógico local de validación

Runner:

```text
node scripts/saas_backup_local.mjs
```

Salida por defecto:

```text
.dart_tool/saas/backups/<timestamp>/
```

El snapshot contiene:

- `public-data.dump`;
- `auth-identity-data.dump` con `auth.users` y `auth.identities`;
- `storage/*.bin` para los objetos reales;
- `manifest.json` con tamaños, SHA-256, fingerprints, commit y versiones de herramientas.

El runner toma fingerprints antes y después del dump. Si la DB cambia durante el proceso, rechaza el snapshot para no producir evidencia inconsistente.

## Restore drill local

Runner:

```text
node scripts/saas_restore_drill_local.mjs <backup-dir>
```

Es deliberadamente destructivo y sólo puede ejecutarse cuando:

```text
STOMNI_ALLOW_DESTRUCTIVE_RESTORE=YES
```

El drill:

1. valida que DB/API sean loopback;
2. valida manifest, tamaños y hashes locales;
3. exige por defecto el mismo commit del backup;
4. ejecuta `supabase db reset` para reconstruir el esquema desde migraciones;
5. limpia únicamente datos restaurables del laboratorio;
6. restaura Auth y `public` con `pg_restore`;
7. repone bytes Storage por la API local;
8. compara fingerprints DB exactos;
9. compara inventario, tamaño y SHA-256 de todos los objetos Storage;
10. sólo entonces genera `RESTORE_DRILL_GREEN`.

Evidencia:

```text
.dart_tool/saas/f9_3_restore_report.json
```

Un backup creado no equivale a una recuperación probada. La recuperación sólo se considera demostrada después de ejecutar este drill en T18 sobre el commit candidato.

## Compatibilidad de esquema

El restore falla por defecto cuando el backup fue creado en un commit distinto al checkout actual.

La excepción:

```text
STOMNI_ALLOW_SCHEMA_MISMATCH=YES
```

sólo existe para un drill deliberado de migración entre versiones y debe registrarse como desviación. No convierte automáticamente un restore entre schemas distintos en válido.

## Exportación por empresa

Runner:

```text
node scripts/saas_export_tenant.mjs --organization-id <UUID>
```

El export incluye:

- la fila raíz de `organizations`;
- todas las tablas `public` que tengan `organization_id`, filtradas por el UUID solicitado;
- objetos Storage cuyo nombre esté bajo `<organization_id>/...`;
- manifest con conteos, fingerprints y SHA-256.

No incluye:

- hashes de contraseña;
- sesiones/tokens Auth;
- catálogos globales compartidos;
- secretos;
- esquema SQL.

Un export tenant es un paquete de portabilidad/auditoría de datos, no un backup completo de recuperación de plataforma.

## Manejo de artefactos

Los artefactos se escriben bajo `.dart_tool/saas/`, que está excluido de Git por la regla general `.dart_tool/`.

No deben versionarse:

- dumps con datos reales;
- exports de clientes;
- manifests con información operacional real;
- objetos Storage descargados;
- logs que contengan datos personales.

## Pruebas obligatorias

Antes del GO comercial:

- T00 registra `psql`, `pg_dump` y `pg_restore`;
- T02 ejecuta `verify_saas_backup_recovery.mjs` y su self-test;
- T12 genera y revisa export de ORG_A/ORG_B con datos ficticios;
- T18 crea un backup y ejecuta restore drill completo;
- T18 repite la restauración en la segunda ejecución limpia cuando corresponda;
- T19 incorpora el reporte F9.3 y el tiempo real medido de recuperación.

## Cadencia posterior al GO

Como mínimo operativo:

- ejecutar un restore drill antes del primer release comercial;
- repetirlo después de cambios mayores de esquema/Storage que alteren la estrategia de recuperación;
- establecer una cadencia periódica en el runbook de producción según el RPO/RTO finalmente aprobados;
- revisar que la política real de backups del proveedor siga habilitada después de cambios de plan o infraestructura.

No se considera suficiente comprobar que “existe un backup”: debe demostrarse que puede restaurarse.
