# FASE 0: MAPEO COMPLETO DEL PROYECTO
**Estado**: FINALIZADO  
**Fecha**: 2026-07-25  
**Objetivo**: Inventario técnico exhaustivo sin modificaciones

---

## 📊 ESTADÍSTICAS GENERALES

| Métrica | Valor |
|---------|-------|
| Archivos .dart | 94 |
| Tests | 2 (básicos) |
| Funciones Supabase Edge | 2 |
| Migraciones SQL | 1 (vacía) |
| RPC Identificadas | 6 |
| Módulos principales | 13 |
| Tamaño total (lib/) | ~1.2 MB |

---

## 📁 ESTRUCTURA DE DIRECTORIOS

```
lib/ (94 archivos)
├── main.dart (1)
│
├── auth/ (3 archivos)
│   ├── pages/
│   │   ├── login_page.dart
│   │   └── cambiar_password_page.dart
│   └── presentation/controllers/
│       └── auth_controller.dart
│
├── splash/ (1 archivo)
│   └── splash_screen.dart
│
├── home/ (4 archivos)
│   ├── home_page.dart
│   ├── home_notifier.dart
│   ├── home_controller.dart
│   └── widgets/dashboard_tab.dart
│
├── core/ (22 archivos)
│   ├── services/ (7)
│   │   ├── configuracion_service.dart
│   │   ├── finanzas_service.dart
│   │   ├── inventario_service.dart
│   │   ├── offline_service.dart
│   │   ├── pdf_generator_service.dart
│   │   ├── realtime_sync_service.dart
│   │   └── sheets_service.dart
│   ├── utils/ (9)
│   │   ├── app_formatters.dart
│   │   ├── auth_utils.dart
│   │   ├── error_mapper.dart
│   │   ├── movimiento_sheets_builder.dart
│   │   ├── navigation_utils.dart
│   │   ├── sheets_helper.dart
│   │   ├── stock_utils.dart
│   │   ├── ui_utils.dart
│   │   └── validation.dart
│   ├── theme/ (3)
│   │   ├── app_colors.dart
│   │   ├── app_styles.dart
│   │   └── app_widgets.dart
│   └── widgets/ (5)
│       ├── almacen_stock_input.dart
│       ├── app_text_field.dart
│       ├── document_form_kit.dart
│       ├── editar_precios_documento_page.dart
│       └── global_date_filter.dart
│
└── features/ (62 archivos)
    ├── almacen/ (10)
    │   ├── data/
    │   │   ├── almacen_repository.dart
    │   │   ├── local_db_service.dart
    │   ├── domain/
    │   │   └── producto.dart
    │   ├── pages/ (5)
    │   │   ├── almacen_page.dart
    │   │   ├── config_almacenes_page.dart
    │   │   ├── ingreso_mercaderia_page.dart
    │   │   ├── mover_stock_page.dart
    │   │   └── nuevo_producto_page.dart
    │   ├── presentation/controllers/ (2)
    │   │   ├── almacen_controller.dart
    │   │   └── nuevo_producto_controller.dart
    │   ├── utils/ (3)
    │   │   ├── almacen_excel_service.dart
    │   │   ├── stock_alert_pdf_service.dart
    │   │   └── stock_helper.dart
    │   └── widgets/
    │       └── product_image.dart
    │
    ├── ventas/ (7)
    │   ├── data/
    │   │   └── ventas_repository.dart
    │   ├── pages/ (4)
    │   │   ├── editar_precios_page.dart
    │   │   ├── seleccion_productos_page.dart
    │   │   ├── venta_page.dart
    │   │   └── ver_venta_page.dart
    │   ├── presentation/controllers/
    │   │   └── carrito_controller.dart
    │   └── usecases/
    │       └── procesar_venta_usecase.dart
    │
    ├── cotizaciones/ (5) [carpeta: Cotizar]
    │   ├── pages/ (5)
    │   │   ├── detalle_cotizacion_page.dart
    │   │   ├── editar_precios_cotizacion.dart
    │   │   ├── lista_cotizaciones_page.dart
    │   │   ├── nueva_cotizacion_page.dart
    │   │   └── ver_cotizacion_page.dart
    │
    ├── balance/ (3)
    │   ├── pages/
    │   │   └── balance_page.dart
    │   ├── utils/
    │   │   └── balance_service.dart
    │   └── widgets/
    │       └── balance_widgets.dart
    │
    ├── kardex/ (2)
    │   ├── pages/
    │   │   └── kardex_page.dart
    │   └── providers/
    │       └── kardex_provider.dart
    │
    ├── reportes/ (7)
    │   ├── pages/ (4)
    │   │   ├── detalle_balance_page.dart
    │   │   ├── exportar_inventario_pdf_page.dart
    │   │   ├── exportar_reportes_page.dart
    │   │   └── reportes_page.dart
    │   ├── providers/
    │   │   └── reportes_provider.dart
    │   └── utils/ (3)
    │       ├── detalle_pdf_service.dart
    │       ├── inventario_pdf_service.dart
    │       └── reporte_excel_service.dart
    │
    ├── clientes/ (2)
    │   ├── data/
    │   │   └── clientes_repository.dart
    │   └── pages/
    │       └── clientes_page.dart
    │
    ├── proveedores/ (2)
    │   ├── data/
    │   │   └── proveedores_repository.dart
    │   └── pages/
    │       └── gestion_proveedores_page.dart
    │
    ├── empleados/ (5)
    │   ├── data/
    │   │   └── empleados_repository.dart
    │   ├── pages/ (3)
    │   │   ├── gestion_empleados_page.dart
    │   │   ├── perfil_page.dart
    │   │   └── ver_pago_empleado_page.dart
    │   └── presentation/controllers/
    │       └── empleados_controller.dart
    │
    ├── deudas/ (3)
    │   ├── data/
    │   │   └── deudas_repository.dart
    │   └── pages/ (2)
    │       ├── deudas_page.dart
    │       └── detalle_deudas_actor_page.dart
    │
    ├── gastos/ (3)
    │   ├── data/
    │   │   └── gastos_repository.dart
    │   └── pages/ (2)
    │       ├── nuevo_gasto_page.dart
    │       └── ver_gasto_page.dart
    │
    ├── configuracion/ (1)
    │   └── pages/
    │       └── configuracion_negocio_page.dart
    │
    └── shared/ (4)
        ├── models/
        │   └── producto_busqueda.dart
        ├── providers/
        │   └── search_revision_provider.dart
        └── widgets/ (4)
            ├── product_card.dart
            ├── product_quantity_dialog.dart
            ├── product_search_widget.dart
            └── shimmer_detalle.dart
```

---

## 🗄️ DEPENDENCIAS PRINCIPALES

### pubspec.yaml (versiones relevantes)
- **flutter_riverpod**: 2.6.1 → Gestión de estado
- **supabase_flutter**: 2.12.4 → Backend
- **sqflite**: 2.4.2+1 → Base de datos local
- **shared_preferences**: 2.5.4 → Caché básica
- **connectivity_plus**: 7.0.0 → Detección de internet
- **flutter_dotenv**: 6.0.1 → Variables de entorno
- **pdf**: 3.10.8 → Generación de PDF
- **printing**: 5.11.1 → Impresión
- **image_picker**: 1.1.0 → Selección de imágenes
- **intl**: 0.20.2 → Localización
- **csv**: 6.0.0 → Manejo de CSV
- **excel**: 4.0.6 → Archivos Excel
- **fl_chart**: 0.66.0 → Gráficos
- **shimmer**: 3.0.0 → Esqueletos de carga
- **cached_network_image**: 3.4.1 → Caché de imágenes

---

## 🗄️ BASE DE DATOS LOCAL (SQLite)

### LocalDbService
- **Archivo**: ferreteria_cache_v4.db
- **Versión actual**: 5
- **Tablas**:
  1. `productos` - Productos con inventario anidado
  2. `almacenes` - Almacenes disponibles
  3. `proveedores` - Proveedores (marcas)
- **Índices** (v5):
  - idx_productos_nombre
  - idx_productos_codigo_barras
  - idx_productos_activo

---

## 🔌 RPC DE SUPABASE IDENTIFICADAS

| RPC | Ubicación | Parámetros principales | Propósito |
|-----|-----------|------------------------|-----------|
| `ajustar_stock_y_kardex` | InventarioService | producto_id, almacen_id, delta, tipo_movimiento | Ajusta stock + registra kardex atómicamente |
| `trasladar_stock` | InventarioService | producto_id, origen_id, destino_id, cantidad | Traslado entre almacenes |
| `crear_producto_con_stock` | AlmacenRepository | producto_data, stock_inicial | Crea producto con inventario inicial |
| `process_sale` | VentasRepository | cliente_id, total, detalles, pagos | Procesa venta completa |
| `increment_stock` | VentasRepository | producto_id, almacen_id, delta | Incrementa stock (anulaciones) |
| `get_dashboard_summary` | DashboardTab | fecha_inicio, fecha_fin | Resumen del dashboard |

---

## 🔧 FUNCIONES EDGE DE SUPABASE

| Función | Lenguaje | Ubicación | Propósito |
|---------|----------|-----------|-----------|
| create_employee | TypeScript | supabase/functions/create_employee/ | Crear empleado con validación de admin |
| delete_employee | TypeScript | supabase/functions/delete_employee/ | Eliminar empleado con validaciones |

---

## 🏗️ ARQUITECTURA DE ESTADO (Riverpod)

### Providers Principales

#### AsyncNotifiers
- **almacenControllerProvider** → AlmacenNotifier - Gestiona productos, almacenes, búsqueda
- **realtimeSyncServiceProvider** → RealtimeInventorySyncService - Escucha cambios en tiempo real

#### StateNotifiers
- **kardexProvider** → KardexNotifier - Kardex con paginación
- **reportesProvider** → ReportesNotifier - Reportes con caché y silent sync
- **authControllerProvider** → AuthController - Autenticación

#### Notifiers
- **carritoProvider** → CarritoController - Carrito de ventas

#### StateProviders (simples)
- **productSearchRevisionProvider** - Contador para invalidar búsquedas
- **homeTabProvider** - Pestaña activa
- **reportesInventarioRevisionProvider** - Revisión de inventario
- **reportesFinancierosRevisionProvider** - Revisión financiera

#### Providers simples
- **supabaseProvider** - Cliente Supabase
- **localDbServiceProvider** - Servicio SQLite
- **almacenRepositoryProvider** - Repositorio de almacén
- **ventasRepositoryProvider** - Repositorio de ventas
- **finanzasServiceProvider** - Servicio de finanzas

#### ValueNotifiers (globales)
- **homeRefreshNotifier** (home_notifier.dart) - Disparador manual de reconstrucción

#### Variables globales
- **rolUsuarioActual** - Rol del usuario actual (vendedor, admin, etc.)

---

## 📦 REPOSITORIOS Y SERVICIOS

### Repositorios (Data Access Layer)
1. **AlmacenRepository** → Productos, almacenes, sincronización local
2. **VentasRepository** → RPC process_sale, anulaciones, obtener ventas
3. **ClientesRepository** → CRUD de clientes
4. **ProveedoresRepository** → CRUD de proveedores
5. **DeudasRepository** → CRUD de deudas
6. **EmpleadosRepository** → CRUD de empleados
7. **GastosRepository** → CRUD de gastos
8. **LocalDbService** → SQLite (caché local)

### Servicios (Core)
1. **InventarioService** - RPC para ajustes de stock y traslados
2. **RealtimeInventorySyncService** - Sincronización con Realtime
3. **OfflineService** - Caché de catálogo y ventas offline
4. **ConfiguracionService** - Carga configuración del negocio
5. **FinanzasService** - Cálculos financieros
6. **PdfGeneratorService** - Generación de PDFs
7. **SheetsService** - Integración Google Sheets

---

## 📄 PÁGINAS PRINCIPALES

### Dashboard (Home)
- **HomePage** (pestana 0) - Dashboard tab
- **BalancePage** (pestana 1) - Balance de caja y ventas
- **AlmacenPage** (pestana 2) - Inventario
- **MoverStockPage** (pestana 3) - Traslados

### Almacén (Feature)
- **almacen_page.dart** (57.41 KB) - Listado con búsqueda y filtros
- **nuevo_producto_page.dart** - Crear/editar productos
- **ingreso_mercaderia_page.dart** - Ingresar stock
- **mover_stock_page.dart** - Traslados entre almacenes
- **config_almacenes_page.dart** - Configuración

### Ventas (Feature)
- **seleccion_productos_page.dart** - Buscar y agregar al carrito
- **venta_page.dart** - Carrito, cliente, formas de pago
- **editar_precios_page.dart** - Ajustar precios antes de vender
- **ver_venta_page.dart** - Detalle de venta

### Cotizaciones (Feature)
- **lista_cotizaciones_page.dart** - Listado
- **nueva_cotizacion_page.dart** - Crear cotización
- **ver_cotizacion_page.dart** - Detalle
- **editar_precios_cotizacion.dart** - Ajustar precios

### Reportes (Feature)
- **reportes_page.dart** (48.12 KB) - Reportes principales
- **detalle_balance_page.dart** - Balance detallado
- **exportar_reportes_page.dart** - Exportar a PDF/Excel
- **exportar_inventario_pdf_page.dart** - Inventario PDF

### Otros (Feature)
- **gestion_empleados_page.dart** (55.9 KB) - CRUD empleados
- **clientes_page.dart** - Listado de clientes
- **gestion_proveedores_page.dart** - Listado de proveedores
- **deudas_page.dart** - Gestión de deudas
- **kardex_page.dart** - Historial de movimientos
- **nuevo_gasto_page.dart** - Registrar gastos

### Autenticación
- **login_page.dart** - Login
- **cambiar_password_page.dart** - Cambio obligatorio de contraseña

---

## 🧪 TESTS EXISTENTES

### 1. stock_utils_test.dart
- Test de `convertToUnits()` - ⚠️ Método existe pero está deprecado
- Test de `calcularPrecioUnitario()`
- Referencias a métodos deprecados en StockUtils

### 2. app_formatters_test.dart
- Test de `AppFormatters.currency()` - Formato de moneda peruana
- Test de `AppFormatters.toDouble()` y `toInt()`

**Observación**: Tests muy básicos, no cubren lógica crítica

---

## 🔄 FLUJO DE SINCRONIZACIÓN OFFLINE

```
┌─────────────────────────────────────────────┐
│ OfflineService                              │
│  ├─ Catálogo: SharedPreferences (JSON)      │
│  └─ Ventas Pendientes: SharedPreferences    │
└─────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────┐
│ LocalDbService (SQLite)                     │
│  ├─ Productos (completos con inventario)    │
│  ├─ Almacenes                               │
│  └─ Proveedores                             │
└─────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────┐
│ Supabase + Realtime                         │
│  ├─ RPC (ajustar_stock_y_kardex, etc.)      │
│  └─ Realtime (PostgresChanges)              │
└─────────────────────────────────────────────┘
         ↓
┌─────────────────────────────────────────────┐
│ Servicios Externos                          │
│  ├─ Google Sheets (MovimientosBatch)        │
│  └─ PDFs (generados localmente)             │
└─────────────────────────────────────────────┘
```

---

## 🎯 FLUJO DE APLICACIÓN

### 1. Entrada (Splash)
```
main.dart
  → Supabase.initialize()
  → ConfiguracionService.cargarNegocio()
  → initializeDateFormatting('es')
  → ProviderScope(MyApp())
  → SplashScreen (3 seg)
    ├─ Si sesión existe → HomePage
    └─ Si no → LoginPage
```

### 2. Autenticación
```
LoginPage
  → AuthController.signIn()
    ├─ Supabase Auth.signInWithPassword()
    ├─ Doble validación: empleados tabla
    ├─ Guardar rol en rolUsuarioActual
    ├─ Cambio de contraseña obligatorio (si aplica)
    └─ ConfiguracionService.cargarNegocio()
  → HomePage
```

### 3. Ciclo de Ventas
```
HomePage (pestana 1: Balance)
  → [FAB] SeleccionProductosV2
    → ProductSearchWidget (búsqueda en SQLite)
    → ProductQuantityDialog (cajas/unidades)
    → CarritoController.actualizarProducto()
  → VentaPage (carrito)
    → ClienteService.resolverCliente()
    → EditarPreciosPage (opcional)
    → ProcesarVentaUseCase.ejecutar()
      ├─ VentasRepository.processSaleRpc()
      ├─ RPC: process_sale
      ├─ SheetsService.registrarMovimientosBatch() (async)
      └─ CarritoController.limpiarCarrito()
```

### 4. Gestión de Inventario
```
HomePage (pestana 2: Almacén)
  → AlmacenPage
    ├─ AlmacenController (AsyncNotifier)
    │   ├─ Sincronizar con Supabase
    │   └─ Escuchar Realtime
    ├─ Búsqueda: ProductSearchWidget
    └─ Acciones:
      ├─ NuevoProductoPage
      ├─ IngresoMercaderiaPage
      ├─ MoverStockPage
      └─ ConfigAlmacenesPage
```

---

## ⚠️ HALLAZGOS INICIALES DE ARQUITECTURA

### 1. **Mezcla de patrones**
- Algunos módulos: data/domain/presentation
- Otros: pages/widgets directos
- Inconsistencia en estructura de carpetas

### 2. **Estado Global Problemático**
- `rolUsuarioActual` (variable global string)
- `homeRefreshNotifier` (ValueNotifier global)
- Mezclado con Riverpod (confusión)

### 3. **Tests Deficientes**
- Solo 2 archivos de tests
- Muy básicos (no cubren lógica crítica)
- Métodos deprecados siendo testeados

### 4. **Métodos Deprecados pero Usados**
- `convertToUnits()` en stock_utils_test.dart
- `convertirACantidadReal()` marcado como deprecated
- `calcularSaldoMixto()` marcado como deprecated

### 5. **Archivos Muy Grandes**
- almacen_page.dart (57.41 KB)
- gestion_empleados_page.dart (55.9 KB)
- reportes_page.dart (48.12 KB)
- Indicadores de múltiples responsabilidades

### 6. **Sincronización Compleja**
- Offline + SQLite + Realtime
- Debouncer para acumular cambios
- "Silent sync" en reportes
- Posibles race conditions

### 7. **Conversión de Unidades/Cajas**
- Múltiples implementaciones de la lógica
- Métodos deprecados aún presentes
- Riesgo de inconsistencias

---

## 📝 NOTAS PARA AUDITORÍA SIGUIENTE

### Información a recopilar en Fase 1-4:
- [ ] Leer completamente almacen_page.dart (57 KB)
- [ ] Leer completamente gestion_empleados_page.dart (55 KB)
- [ ] Leer completamente reportes_page.dart (48 KB)
- [ ] Revisar uso de `rolUsuarioActual` en todo el código
- [ ] Mapear todas las referencias a Realtime
- [ ] Mapear todas las llamadas a RPC
- [ ] Revisar sincronización offline completa
- [ ] Revisar conversión de cajas/unidades en 3+ ubicaciones
- [ ] Identificar posibles memory leaks en controllers
- [ ] Revisar borrado físico vs soft delete
- [ ] Revisar manejo de errores silenciosos

### Modelos para explorar:
- Producto, InventarioAlmacen
- Venta, Detalle Venta, Pago Venta
- Empleado, Cliente, Proveedor
- Deuda, Gasto, Kardex

### Seguridad a revisar:
- RLS en tablas públicas
- Validación de roles
- Secretos en código
- Inyección SQL
- CORS en Edge Functions

---

## ✅ CONCLUSIÓN FASE 0

Se ha completado el mapeo exhaustivo del proyecto:
- ✅ 94 archivos Dart inventariados
- ✅ 6 RPC identificadas
- ✅ Estructura de dependencias mapeada
- ✅ Patrones arquitectónicos identificados
- ✅ Hallazgos iniciales documentados
- ✅ Rutas de información para auditoría posterior

**Siguiente paso**: Validación y aprobación de mapeo antes de continuar con FASE 1.

