# Fase 5 — Reconciliación Supabase

Fecha de inicio: 2026-08-21.
Última verificación de producción: 2026-08-21.
Proyecto inspeccionado: `AlmacenStOmni` (`CI_PROJECT_REF_REDACTED`).
PostgreSQL administrado: 17.6.

> Todo el diagnóstico de este documento se obtuvo con consultas **solo lectura**. No se aplicó DDL ni se modificaron datos ni el historial de migraciones de producción.

## 1. Historial remoto registrado

`supabase_migrations.schema_migrations` contiene actualmente 10 versiones:

| versión | nombre |
|---|---|
| 20260722180810 | remote_schema |
| 20260806153300 | migracion_roles |
| 20260806163000 | update_functions_roles |
| 20260806171613 | grafico_tendencia_rpc |
| 20260806223000 | tributario_produccion_hardening |
| 20260808223500 | rpc_cotizaciones_vencidas |
| 20260818212617 | supabase_security_hardening |
| 20260818220125 | internal_rpc_surface_hardening |
| 20260818220422 | dashboard_trend_auth_hardening |
| 20260820002405 | gre_cantidad_bultos |

La segunda verificación directa de Fase 5 confirmó que la lista sigue siendo exactamente la misma: no se registró accidentalmente ninguna migración nueva durante el hardening.

Git contenía 13 migraciones timestamped al iniciar Fase 5. Las versiones locales históricas que no figuran en el historial remoto son:

- `20260808240000_rpc_facturacion_electronica.sql`;
- `20260809165000_rpc_procesar_pago_deuda.sql`;
- `20260821191000_stock_alert_transactional_fix.sql`.

Fase 5 agrega migraciones nuevas posteriores; no deben confundirse con esta deriva histórica previa.

## 2. Huella real de producción

Conteo verificado del schema `public`:

| objeto | cantidad |
|---|---:|
| tablas | 44 |
| vistas/materialized views | 2 |
| funciones | 74 |
| triggers de usuario | 16 |
| policies | 58 |
| índices | 145 |

Las 44 tablas de `public` tienen RLS habilitado.

La huella sirve como control inicial; no demuestra equivalencia semántica.

### 2.1 Extensiones instaladas

La reconstrucción no puede validar únicamente `public`. Producción tiene actualmente:

| extensión | versión observada | schema |
|---|---:|---|
| `pg_cron` | 1.6.4 | `pg_catalog` |
| `pg_net` | 0.20.4 | `public` |
| `pg_stat_statements` | 1.11 | `extensions` |
| `pgcrypto` | 1.3 | `extensions` |
| `plpgsql` | 1.0 | `pg_catalog` |
| `supabase_vault` | 0.3.1 | `vault` |
| `uuid-ossp` | 1.1 | `extensions` |

Las versiones son una huella diagnóstica, **no deben pinnearse** en nuevas migraciones. Desde 2026-08-05 Supabase ignora el version pinning solicitado en `CREATE/ALTER EXTENSION` y usa la versión predeterminada disponible en el proyecto.

### 2.2 Storage policies personalizadas

`supabase db dump` excluye por diseño schemas administrados como `storage`; por eso el dump de `public` no puede considerarse por sí solo una reconstrucción completa de StOmni.

Se verificaron 8 policies personalizadas sobre `storage.objects`:

- `logos_admin_delete`;
- `logos_admin_insert`;
- `logos_admin_update`;
- `logos_public_select`;
- `productos_imagenes_admin_delete`;
- `productos_imagenes_admin_insert`;
- `productos_imagenes_admin_update`;
- `productos_imagenes_public_select`.

Las mutaciones de ambos buckets están limitadas a `authenticated` + `app_es_admin()`. La lectura pública está limitada por `bucket_id` a `logos` o `imagenes_productos` según la policy.

Estas policies deben quedar verificadas explícitamente después de un reset/reconstrucción; no asumir que están cubiertas por `public_schema.sql`.

## 3. Diferencias confirmadas

### Baseline vacío — P0

`supabase/migrations/20260722180810_remote_schema.sql` está vacío (0 bytes), aunque `20260722180810 / remote_schema` figura aplicada en producción.

Consecuencia: las migraciones actuales de Git no pueden reconstruir una base vacía porque asumen tablas iniciales ya existentes.

### Facturación agrupada no registrada

`20260808240000_rpc_facturacion_electronica.sql` existe localmente y agrupa RPCs mediante `\ir RPCs/...`, pero no figura en el historial remoto. Sus resultados deben compararse función por función antes de reparar historial.

### Pago de deuda divergente

`20260809165000_rpc_procesar_pago_deuda.sql` no figura en el historial remoto.

- archivo histórico local: `admin` / `vendedor`;
- función real en producción: `admin` / `operador`;
- producción actual no tiene `request_id` en el pago.

Fase 5 ya contiene una migración nueva separada para `procesar_pago_deuda_v2` idempotente. Aún no fue desplegada.

### Alerta de stock no registrada

`20260821191000_stock_alert_transactional_fix.sql` existe en Git y su comportamiento está activo/validado en producción, pero su versión no aparece en `schema_migrations`.

No debe ejecutarse otra vez a ciegas.

## 4. Seguridad/RLS observada

### Policies públicas excesivamente permisivas

Se confirmaron:

| tabla | policy | acceso |
|---|---|---|
| `clientes` | `Permitir todo en clientes` | `public`, `ALL`, `true` |
| `transferencias_stock` | `Permitir todo en transferencias_stock` | `public`, `ALL`, `true` |

Se corregirán mediante hardening explícito posterior, no como cambio oculto de baseline.

### Funciones sin `SET search_path` explícito

- `increment_stock(bigint,bigint,integer)`;
- `set_facturacion_updated_at()`;
- `set_vendedor_observaciones_kardex()`;
- `vincular_usuario_empleado()`.

`vincular_usuario_empleado()` es además `SECURITY DEFINER` y tendrá prioridad alta.

### `SECURITY DEFINER` ejecutable por authenticated

Existe una superficie amplia. No todo es vulnerable: varias funciones son la API legítima de Flutter. Cada una se clasifica como:

- API pública de negocio;
- helper interno;
- legacy/obsoleta;
- administrativa.

Los helpers internos deberán perder `EXECUTE` para `anon/authenticated`.

## 5. Roles legacy en funciones reales

La tabla `empleados` acepta únicamente `admin` y `operador`, pero todavía hay definiciones de función con literales históricos, incluyendo `anular_venta`, `anular_venta_v2`, `eliminar_cotizacion_v2` y `guardar_cotizacion_v2`.

No se reescribirán migraciones aplicadas para fingir otro historial; se corregirá con migraciones nuevas.

## 6. Idempotencia existente

Producción ya posee patrones de `request_id` en ventas, transferencias, documentos tributarios y tablas de operaciones procesadas.

`pagos_venta` y `pagos_gasto` no tienen `request_id` actualmente. La migración Fase 5 `20260821224600_debt_payment_idempotency.sql` lo corrige en Git, sin despliegue todavía.

## 7. Triggers relevantes

Entre los 16 triggers activos se verificaron:

- alertas transaccionales de stock;
- `trg_set_venta_fue_credito`;
- `trg_set_vendedor_observaciones_kardex`;
- triggers `updated_at` de facturación/GRE;
- normalización GRE;
- validación de origen de nota de crédito.

El baseline deberá reproducirlos.

## 8. Limpieza de `supabase/migrations/`

`temp_functions.sql` fue verificado como un volcado JSON, no una migración SQL. No era timestamped y no pertenecía al historial de Supabase CLI.

Fue retirado en Fase 5. Esto no cambia producción ni elimina funciones reales.

## 9. Estrategia de baseline

No se fabricará el DDL principal a mano desde `information_schema`.

Flujo seguro:

1. obtener snapshot oficial del schema `public` con Supabase CLI (`db dump`), sin datos;
2. calcular SHA-256 del dump;
3. guardar inventario read-only separado de extensiones y customizaciones en schemas administrados, especialmente policies de `storage.objects`;
4. comparar dump vs migraciones actuales;
5. construir baseline candidato sin reescribir el pasado aplicado;
6. aplicar baseline + migraciones correctivas en entorno local/temporal;
7. ejecutar `supabase db reset` **solo** en local/entorno descartable;
8. verificar `public`, grants, extensiones requeridas y las 8 Storage policies personalizadas;
9. comparar la huella reconstruida contra producción;
10. recién entonces decidir cómo reconciliar `schema_migrations` remoto.

### Nota importante sobre `db pull`

La CLI actual puede proponer actualizar/reparar el historial remoto durante `db pull`. Por esa razón no se utilizará de forma automática contra producción durante este checkpoint. El dump read-only + reconstrucción descartable mantiene separado el trabajo de captura del eventual `migration repair`.

### Nota importante sobre `db dump`

La CLI documenta que `db dump` excluye schemas administrados como `auth`, `storage` y schemas creados por extensiones. Por lo tanto `public_schema.sql` es el baseline del **schema de aplicación**, no una prueba suficiente de equivalencia total del proyecto Supabase.

## 10. Herramienta incluida

`scripts/fase5_supabase_snapshot.ps1`

La herramienta actual:

- ejecuta únicamente inspección/exportación del schema de aplicación;
- genera `migration_list.txt` y `public_schema.sql`;
- calcula SHA-256;
- detecta coincidencias de roles legacy/policies permisivas dentro del dump;
- escribe en `supabase/.snapshots/fase5/`;
- no ejecuta `db push`, `db reset`, `migration repair` ni DDL.

El inventario de extensiones y Storage policies se mantiene como verificación separada porque `db dump` excluye schemas administrados.

Ejecución:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\fase5_supabase_snapshot.ps1
```

Si el repositorio local todavía no está vinculado:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\fase5_supabase_snapshot.ps1 -LinkProject
```

## 11. Matriz actual

| área | producción | Git | estado |
|---|---|---|---|
| baseline inicial | completo | archivo vacío | 🔴 divergente |
| historial remoto | 10 migraciones | más versiones locales | 🔴 divergente |
| roles empleados | `admin`/`operador` | nuevas migraciones respetan ambos | 🟢/🟡 |
| pago de deuda | no idempotente | v2 idempotente preparada | 🟡 pendiente despliegue |
| alerta stock | aplicada | migración presente/no registrada | 🟡 historial |
| facturación agrupada | funciones presentes | migración no registrada | 🟡 comparar |
| RLS `public` | 44/44 tablas | policies por reconciliar | 🟡 |
| Storage policies custom | 8 verificadas | deben entrar en prueba de reconstrucción | 🟡 |
| extensiones | 7 instaladas | deben verificarse por nombre/capacidad, no versión fija | 🟡 |
| `clientes` | policy `public ALL true` | hardening pendiente | 🔴 |
| `transferencias_stock` | policy `public ALL true` | hardening pendiente | 🔴 |
| funciones | 74 | múltiples fuentes | 🟡 comparar |
| triggers | 16 | múltiples fuentes | 🟡 comparar |

## 12. Prohibiciones durante este checkpoint

- no `db reset --linked`;
- no `migration repair` en producción;
- no `db push`;
- no aceptar automáticamente la reparación de historial propuesta por `db pull`;
- no copiar datos reales al repo;
- no versionar secretos/Vault/API keys;
- no borrar funciones legacy solo por el nombre;
- no fijar versiones de extensiones en migraciones nuevas.

## 13. Criterio de salida

Checkpoint 1 termina cuando una base vacía se pueda reconstruir desde Git y se verifiquen, como mínimo:

- tablas y columnas;
- constraints;
- índices;
- funciones/RPC;
- triggers;
- RLS/policies de `public`;
- grants relevantes;
- extensiones requeridas por capacidad/nombre;
- vistas;
- las 8 Storage policies personalizadas actualmente usadas por StOmni.

## Estado

**Inventario semántico inicial ampliado y revalidado directamente contra producción. El bloqueo P0 continúa siendo el baseline vacío. Falta obtener el dump oficial en un entorno con Supabase CLI vinculado, construir el baseline candidato y ejecutar la reconstrucción en un entorno descartable. Producción continúa sin cambios de Fase 5.**
