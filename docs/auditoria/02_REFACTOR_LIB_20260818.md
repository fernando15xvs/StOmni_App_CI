# Auditoría y refactor de `lib/` — 2026-08-18

## Estado

- Rama de trabajo: `refactor/lib-architecture-20260818`
- Rama base: `main`
- Alcance de esta fase: arquitectura Flutter, dependencias, caché local, Realtime y compatibilidad de plataforma.
- No se modificaron RPC, migraciones SQL ni Edge Functions en esta fase.

## Objetivo

Reducir acoplamientos entre features y corregir problemas detectados durante el recorrido de `lib/` sin reescribir módulos críticos ni cambiar deliberadamente las reglas de negocio.

## Cambios aplicados

### 1. `supabaseProvider` deja de pertenecer a Almacén

Antes, `supabaseProvider` estaba declarado dentro de `features/almacen/data/almacen_repository.dart`. Esto obligaba a Ventas, Clientes, Deudas, Gastos, Empleados y Facturación a importar la feature de Almacén únicamente para obtener el cliente Supabase.

Se creó:

`lib/core/providers/supabase_provider.dart`

Los repositorios migrados usan ahora ese provider común. Se dejó temporalmente una exportación de compatibilidad desde `almacen_repository.dart` porque `ver_venta_page.dart` todavía lo consume desde la ruta antigua. Esa compatibilidad debe eliminarse cuando se refactorice `VerVentaPage`.

### 2. Roles técnicos centralizados

Se creó:

`lib/core/constants/app_roles.dart`

La fuente de verdad Flutter queda limitada a:

- `admin`
- `operador`

`AuthController`, Almacén y Kardex usan esta normalización. Almacén ya no acepta el valor legado `administrador` como rol técnico válido.

### 3. Inicialización SQLite separada por plataforma

`main.dart` importaba directamente `dart:io` y `sqflite_common_ffi`, mezclando el bootstrap general con inicialización exclusiva de Windows/Linux.

Se crearon implementaciones condicionales en:

- `core/database/database_initializer.dart`
- `core/database/database_initializer_io.dart`
- `core/database/database_initializer_stub.dart`

Esto elimina dos imports de plataforma del punto de entrada. No implica por sí solo que toda la aplicación esté lista para Web; otros plugins y archivos aún deben verificarse específicamente para Web.

### 4. `AppTime` ya no depende de `dart:io`

`AppTime` solo utilizaba `dart:io` para `HttpDate.parse`. Se reemplazó por un parser local del formato RFC-1123 de la cabecera HTTP `Date`.

Si la sincronización HTTP falla, la aplicación conserva el comportamiento seguro de fallback al reloj local y `isSynced` queda en `false`.

### 5. Import incorrecto en `InventarioService`

Se corrigió la ruta a `AppTime` desde `core/services/inventario_service.dart`.

La ruta anterior subía niveles fuera de `lib/core` innecesariamente; ahora utiliza `../utils/app_time.dart`.

### 6. Corrección de caché/búsqueda de inventario

Se detectó un problema de lógica entre `AlmacenRepository.buscarProductosRapido()` y `LocalDbService.buscarProductosRapido()`:

- La búsqueda rápida devuelve una lista vacía cuando el texto está vacío.
- Almacén utilizaba precisamente esa lista vacía para decidir si SQLite estaba vacío.
- Al abrir el buscador podía interpretarse que no había caché y ejecutarse una sincronización completa aunque el catálogo ya existiera.
- La rama destinada a una sincronización silenciosa cada 10 minutos quedaba prácticamente anulada.

Se agregó `LocalDbService.tieneProductosEnCache()` y ahora la existencia del catálogo se verifica explícitamente.

También se guarda correctamente `ultima_sincronizacion_productos` después de una sincronización completa exitosa.

### 7. Productos inactivos en SQLite

Se endureció el filtrado local:

- `getProductosOnline()` solo devuelve productos activos.
- `buscarProductos()` solo devuelve productos activos.
- `sincronizarProductoLocal()` consulta el producto como activo; si fue desactivado remotamente, lo elimina del caché local en vez de volver a insertarlo por un evento Realtime tardío.

Esto evita que un producto desactivado reaparezca en el catálogo por desfase entre Supabase Realtime y SQLite.

### 8. Realtime financiero duplicado eliminado de Balance

`BalancePage` abría un canal Realtime propio para:

- `pagos_venta`
- `pagos_gasto`
- `pagos_empleados`

`RealtimeFinancialSyncService` ya escucha esas mismas tablas. Se eliminó el canal duplicado de la página y Balance consume ahora `financialRealtimeEventStreamProvider`.

### 9. Inyección de Supabase en repositorios

Se migraron hacia el provider común, entre otros:

- Almacén
- Ventas
- Clientes
- Proveedores
- Gastos
- Deudas
- Empleados
- Balance
- Documentos electrónicos
- Notas de crédito
- Procesos tributarios
- Guías de remisión
- Kardex

El objetivo es que las features no dependan unas de otras solo para conseguir una conexión Supabase y facilitar pruebas futuras con clientes inyectados.

### 10. Logging de OneSignal

El nivel `verbose` de OneSignal queda habilitado únicamente en `kDebugMode`, evitando logs detallados innecesarios en builds de producción.

### 11. Prueba de roles técnicos

Se agregó `test/app_roles_test.dart` para verificar que únicamente `admin` y `operador` se normalizan como roles válidos y que nombres legados como `administrador`, `vendedor` o `almacenero` son rechazados.

## Hallazgos que NO se refactorizaron todavía

Estos cambios tienen valor, pero son demasiado amplios para mezclarlos con esta primera rama sin una cobertura de pruebas mayor.

### Alta prioridad — dirección de dependencias de `core`

`core` todavía conoce features concretas:

- `core/services/offline_service.dart` importa el use case de Ventas.
- `core/services/realtime_sync_service.dart` importa `AlmacenRepository`.

La dirección deseable es `features -> core`, no `core -> features`. Una segunda fase debe extraer interfaces/puertos o mover estos coordinadores a una capa de aplicación.

### Alta prioridad — cola offline de ventas

Las ventas pendientes se guardan en `SharedPreferences`. Para datos transaccionales sería más robusto utilizar SQLite con estados explícitos, índice por `request_id`, número de intentos y último error.

No se migró ahora para no alterar el formato de ventas pendientes que ya puedan existir en dispositivos.

### Alta prioridad — acceso Supabase desde UI

Todavía existen páginas/widgets que consultan Supabase directamente. Ejemplos relevantes:

- `home/widgets/dashboard_tab.dart`
- `features/ventas/pages/venta_page.dart`
- `features/ventas/pages/ver_venta_page.dart`
- `features/facturacion/pages/nueva_guia_remision_page.dart`
- `features/facturacion/pages/gestion_transporte_page.dart`
- `features/proveedores/pages/gestion_proveedores_page.dart`
- `features/empleados/pages/perfil_page.dart`
- `features/empleados/pages/nuevo_pago_empleado_page.dart`
- `core/widgets/document_form_kit.dart`

Estas consultas deben moverse gradualmente a repositorios/controllers/providers. No se recomienda hacerlo en un único commit masivo.

### Alta prioridad — archivos demasiado grandes

Los principales hotspots detectados en el árbol actual incluyen aproximadamente:

| Archivo | Tamaño aproximado |
|---|---:|
| `features/facturacion/pages/nueva_guia_remision_page.dart` | 78 KB |
| `features/facturacion/pages/gestion_transporte_page.dart` | 50 KB |
| `core/services/pdf_generator_service.dart` | 49 KB |
| `features/almacen/pages/almacen_page.dart` | 47 KB |
| `home/widgets/dashboard_tab.dart` | 44 KB |
| `features/almacen/pages/nuevo_producto_page.dart` | 41 KB |
| `features/almacen/pages/mover_stock_page.dart` | 31 KB |
| `features/facturacion/pages/ver_guia_remision_page.dart` | 31 KB |

El objetivo de una segunda fase debe ser extraer widgets, form state/controllers, mappers y servicios; no dividir archivos únicamente por cantidad de líneas.

### Media prioridad — consulta de DNI/RUC duplicada

La Edge Function `get-persona` se invoca desde varios puntos: Clientes, formularios compartidos, Proveedores y pantallas de transporte/GRE. Conviene crear una única abstracción (`PersonaLookupRepository` o servicio equivalente) para estandarizar validación, errores, timeouts y parsing.

### Media prioridad — `FacturacionService` en `core`

`core/services/facturacion_service.dart` es específico del dominio tributario. Conceptualmente debería estar dentro de `features/facturacion` (por ejemplo `application/` o `data/remote/`). Se mantiene donde está para evitar una migración masiva de imports en esta rama.

### Media prioridad — `Map<String, dynamic>`

Hay gran cantidad de mapas dinámicos entre UI, use cases y repositorios. En operaciones críticas (venta, comprobante, nota de crédito, GRE, pagos) conviene migrar gradualmente a DTOs/modelos tipados con `fromMap/toMap`.

### Media prioridad — nombre `Cotizar`

La carpeta `features/Cotizar` utiliza mayúscula mientras el resto sigue nombres minúsculos. Debe normalizarse a `cotizaciones` en una rama dedicada porque el cambio de casing puede ser problemático entre Windows, Linux y Git.

### Media prioridad — estado global mixto

La aplicación utiliza Riverpod pero conserva `homeRefreshNotifier` como `ValueNotifier` global. Puede migrarse a un provider de revisión/invalidation para mantener una sola estrategia de estado.

### Media prioridad — cobertura de pruebas

Después de esta rama `test/` contiene cuatro archivos de pruebas unitarias:

- `app_formatters_test.dart`
- `price_visual_utils_test.dart`
- `stock_utils_test.dart`
- `app_roles_test.dart`

La cobertura sigue siendo insuficiente para los flujos críticos. Antes de dividir GRE, Ventas, Facturación o el flujo offline se recomienda añadir pruebas de:

- `process_sale_v3` desde la capa Flutter con cliente simulado/integración controlada.
- cálculo y conversión de unidades de venta.
- cola offline e idempotencia por `request_id`.
- sincronización de producto activo/inactivo en caché.
- estados tributarios inciertos.
- validaciones de GRE.

## Arquitectura objetivo incremental

No se recomienda reescribir el proyecto. La evolución propuesta es:

```text
lib/
├── app/
│   ├── app.dart
│   ├── bootstrap.dart
│   └── router.dart
├── core/
│   ├── constants/
│   ├── database/
│   ├── network/
│   ├── providers/
│   ├── theme/
│   ├── utils/
│   └── widgets/
└── features/
    └── <feature>/
        ├── data/
        ├── domain/
        ├── application/
        └── presentation/
```

La migración debe ser por feature y con pruebas, no una reorganización masiva de carpetas.

## Validación antes de merge

Este repositorio no tiene actualmente un workflow en `.github/workflows` para ejecutar análisis de Flutter automáticamente. El conector GitHub permite revisar y modificar el código, pero no ejecuta el SDK Flutter local del proyecto.

Antes de fusionar esta rama con `main` ejecutar en un entorno con Flutter:

```bash
flutter pub get
flutter analyze
flutter test
```

Y, por los cambios de bootstrap/plataforma:

```bash
flutter build apk --debug
flutter build web
```

`flutter build web` debe considerarse una verificación independiente: esta rama elimina blockers concretos de `dart:io` en `main.dart` y `AppTime`, pero no certifica todavía que todos los plugins y todos los archivos de `lib/` soporten Web.

## Criterio de merge

Fusionar solamente si:

1. `flutter analyze` no presenta errores.
2. Los tests existentes pasan.
3. Login funciona con `admin` y `operador`.
4. Inventario abre desde caché sin sincronizaciones completas repetitivas.
5. Crear/editar/desactivar producto conserva el comportamiento esperado.
6. Venta y sincronización offline siguen funcionando.
7. Balance se actualiza mediante el Realtime financiero global.
8. Facturación/GRE siguen abriendo y consultando sus repositorios normalmente.

