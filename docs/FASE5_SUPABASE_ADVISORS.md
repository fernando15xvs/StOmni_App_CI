# Fase 5 — Supabase Security & Performance Advisors

Fecha de inventario: 2026-08-21  
Proyecto: `AlmacenStOmni` (`CI_PROJECT_REF_REDACTED`)

> Este documento describe un inventario obtenido en **solo lectura**. No se aplicó DDL ni se modificaron datos de producción.

## Criterio

Los advisors no se corrigen de forma automática. Cada aviso se clasifica como:

- **Corregir**: riesgo concreto con cambio acotado y verificable.
- **Revisar antes de cambiar**: puede ser intencional según la arquitectura.
- **Mantener/documentar**: el warning es compatible con el diseño actual.

## Seguridad

### RLS habilitado sin policy

Detectado en tablas internas como:

- `correlativos_procesos_tributarios`
- `inventario_operaciones_idempotentes`
- `personas_cache`
- `stock_alert_tx_context`
- `sys_processed_requests`

**Clasificación: mantener/revisar.**

RLS sin policies puede ser deliberadamente deny-by-default para tablas que solo deben tocar funciones `SECURITY DEFINER`/backend. No se crearán policies públicas solo para silenciar el advisor.

### `function_search_path_mutable`

Detectado en:

- `set_facturacion_updated_at`
- `vincular_usuario_empleado`
- `increment_stock`
- `set_vendedor_observaciones_kardex`

**Clasificación: corregir.**

Los helpers que permanezcan deben fijar `search_path` explícito. Los trigger helpers también deben evitar EXECUTE directo innecesario desde la API.

### `increment_stock`

Estado inspeccionado:

- ejecutable por `authenticated`;
- no es `SECURITY DEFINER`;
- no tiene `search_path` fijo;
- no valida empleado/rol por sí mismo;
- no tiene caller actual encontrado en Flutter;
- no se encontró otra función `public` que lo invoque;
- `inventario_almacen` solo expone SELECT por RLS a `authenticated`.

**Clasificación: candidato legacy de alto riesgo.**

No se eliminará en producción hasta demostrar en el entorno descartable que no existe dependencia oculta. La opción preferida será revocar EXECUTE y/o retirar la función del baseline si queda demostrado que está obsoleta.

### Trigger helpers ejecutables por `authenticated`

`set_facturacion_updated_at` y `set_vendedor_observaciones_kardex` son funciones de trigger. Que un usuario autenticado pueda invocarlas como RPC no aporta una API válida.

**Clasificación: corregir.**

Plan: fijar `search_path` y revocar EXECUTE público/autenticado, conservando su uso por triggers.

El nombre `set_vendedor_observaciones_kardex` es legacy de presentación; no representa un rol técnico. La función obtiene el nombre del empleado asociado a una venta para completar observaciones.

### `_gre_supervisor()`

Inspección actual:

- `SECURITY DEFINER`;
- `search_path=public, pg_catalog` ya fijo;
- semánticamente valida empleado activo con `rol='admin'`;
- ejecutable por `authenticated`.

**Clasificación: revisar/renombrar en una futura migración.**

El nombre es legacy, pero la regla de autorización efectiva es `admin`. Debe determinarse si algún RPC/policy lo invoca antes de renombrar o revocar.

### `SECURITY DEFINER` ejecutables por `authenticated`

El advisor marca numerosas funciones de negocio. Esto no significa automáticamente una vulnerabilidad: varias son la API RPC intencional de Flutter.

**Clasificación: matriz obligatoria antes de cambiar.**

Para cada función se documentará:

- si Flutter/Edge la llama directamente;
- si valida `auth.uid()`;
- si exige empleado activo;
- roles permitidos (`admin`/`operador`);
- `search_path` fijo;
- si es API pública o helper interno;
- EXECUTE esperado para `anon`, `authenticated`, `service_role`.

Los helpers internos deben perder EXECUTE de `authenticated`; las RPC públicas conservarán únicamente el privilegio necesario.

### `pg_net` en `public`

**Clasificación: revisar antes de mover.**

La notificación transaccional de stock depende actualmente de `pg_net`. Mover la extensión de schema sin reconstruir dependencias puede romper alertas. Se evaluará en el entorno descartable y no se cambiará por el advisor solamente.

### Leaked password protection deshabilitada

**Clasificación: ajuste recomendado de Auth.**

No es una migración PostgreSQL. Debe habilitarse desde la configuración de Supabase Auth si el plan/proyecto lo permite, después de verificar impacto en creación/cambio de contraseñas.

## Performance

### FKs sin índice

El advisor reporta varias foreign keys sin índice, entre ellas relaciones de ventas, detalles, productos/proveedores, gastos, GRE, procesos tributarios e inventario.

**Clasificación: revisar por carga real.**

No se crearán todos los índices automáticamente. Prioridad inicial para medir:

- `detalle_ventas(producto_id)`
- `detalle_ventas(almacen_id)`
- `ventas(cliente_id)`
- `gastos(proveedor_id)`
- `productos(proveedor_id)`
- `inventario_almacen(almacen_id)`
- relaciones GRE usadas por búsquedas/join frecuentes.

### RLS initplan

`series_comprobantes.series_select_empleado` reevalúa una función Auth por fila.

**Clasificación: corregir.**

Plan: revisar la policy y cambiar llamadas repetibles a la forma `(select auth.<func>())`/equivalente seguro según la policy real, primero en entorno descartable.

### Índice duplicado en `inventario_almacen`

El advisor detecta dos índices UNIQUE equivalentes:

- `inventario_almacen_producto_id_almacen_id_key`
- `inventario_almacen_producto_id_almacen_id_key1`

**Clasificación: corregir después de reconstrucción.**

Se conservará exactamente uno. Antes de eliminar el duplicado se verificará qué constraint posee cada índice y qué nombre es referenciado por migraciones/`ON CONFLICT`.

### Índices sin uso

**Clasificación: no borrar automáticamente.**

Los contadores de uso dependen del tiempo desde reinicio y de la carga real. Índices asociados a tributación, reconciliación, resultado incierto, idempotencia o flujos poco frecuentes pueden ser críticos aunque aún tengan `idx_scan=0`.

## Orden de hardening propuesto

1. completar baseline/reconstrucción descartable;
2. generar matriz de RPC públicas/helpers internos;
3. fijar `search_path` de helpers necesarios;
4. revocar EXECUTE directo a trigger helpers y helpers internos;
5. demostrar que `increment_stock` es legacy y retirarlo/revocarlo;
6. corregir RLS initplan de `series_comprobantes`;
7. eliminar el índice duplicado de `inventario_almacen` conservando el constraint correcto;
8. medir FKs de alto tráfico antes de agregar índices;
9. reejecutar advisors y comparar resultados.

## Estado

**Inventario y clasificación inicial completados. Ningún advisor fue aplicado a producción en esta etapa.**
