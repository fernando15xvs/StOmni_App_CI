# MAPA DE DEPENDENCIAS Y FLUJOS CRÍTICOS

## 📊 MATRIZ DE DEPENDENCIAS ENTRE MÓDULOS

```
┌─────────────────────────────────────────────────────────────┐
│                        CORE (Servicios)                     │
│  ┌─────────────────┬────────────────┬──────────────────┐   │
│  │ inventario_srvc │ configuracion  │ realtime_sync    │   │
│  ├─────────────────┼────────────────┼──────────────────┤   │
│  │ offline_srvc    │ finanzas_srvc  │ sheets_srvc      │   │
│  │ pdf_generator   │ local_db_srvc  │                  │   │
│  └─────────────────┴────────────────┴──────────────────┘   │
└─────────────────────────────────────────────────────────────┘
         ↓                    ↓                    ↓
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│ ALMACÉN          │  │ VENTAS           │  │ REPORTES         │
│ ├─ Controller    │  │ ├─ Controller    │  │ ├─ Provider      │
│ ├─ Repository    │  │ ├─ Repository    │  │ ├─ Service       │
│ ├─ Pages (5)     │  │ ├─ UseCase       │  │ ├─ Pages (4)     │
│ ├─ Widgets       │  │ ├─ Pages (4)     │  │ └─ Utils (3)     │
│ └─ Utils (3)     │  │ └─ Carrito       │  └──────────────────┘
└──────────────────┘  └──────────────────┘
         ↓                    ↓
┌──────────────────┐  ┌──────────────────┐
│ KARDEX           │  │ BALANCE          │
│ ├─ Provider      │  │ ├─ Page          │
│ ├─ Page          │  │ ├─ Service       │
│ └─ Realtime      │  │ └─ Widgets       │
└──────────────────┘  └──────────────────┘
```

---

## 🔗 FLUJOS DE VENTA (CRÍTICOS)

### Flujo Completo de Venta

```
1. SELECCIÓN
   └─ SeleccionProductosV2 (page)
      ├─ ProductSearchWidget (búsqueda en SQLite local)
      │  ├─ Lee LocalDbService
      │  └─ Usa productSearchRevisionProvider para invalidar
      ├─ ProductQuantityDialog (input cajas/unidades)
      │  └─ Calcula usando StockUtils.calcularTotalPiezas()
      └─ CarritoController.actualizarProducto()

2. CARRITO
   └─ VentaPage (page)
      ├─ Muestra CarritoController.state
      ├─ Opcionalmente: EditarPreciosPage
      ├─ ClienteService.resolverCliente()
      │  └─ Busca o crea cliente en Supabase
      ├─ Selecciona forma de pago
      └─ Genera lista de pagos

3. PROCESAMIENTO (ATÓMICO)
   └─ ProcesarVentaUseCase.ejecutar()
      ├─ VentasRepository.processSaleRpc()
      │  └─ RPC: process_sale (Supabase)
      │     ├─ Inserta venta
      │     ├─ Inserta detalle_ventas
      │     ├─ Descuenta stock (ajustar_stock_y_kardex)
      │     ├─ Registra kardex
      │     ├─ Inserta pagos_venta
      │     └─ [TRANSACCIÓN ATÓMICA en BD]
      ├─ SheetsService.registrarMovimientosBatch() [async]
      │  └─ Registra en Google Sheets de forma asíncrona
      └─ CarritoController.limpiarCarrito()

4. POST-VENTA
   └─ Navegación a ver_venta_page
      ├─ Muestra comprobante
      └─ Opción de imprimir PDF
```

### Cálculo de Piezas a Descontar

```
Entrada del usuario:
  - cantidad_visual (lo que escribió)
  - tipo_unidad ("Caja" o "Und")
  - tipo_venta (SOLO_CAJAS, SOLO_UNIDADES, AMBOS)
  - cantidad_por_caja (pcs)

Lógica (StockUtils.calcularTotalPiezas):
  
  if tipo_venta == SOLO_CAJAS:
    piezas_a_descontar = cantidad_visual
    (NO se multiplica, se guarda como cajas)
  
  else if tipo_venta == SOLO_UNIDADES:
    piezas_a_descontar = cantidad_visual
  
  else if tipo_venta == AMBOS:
    if tipo_unidad == "Caja":
      piezas_a_descontar = cantidad_visual * pcs
    else:
      piezas_a_descontar = cantidad_visual

Salida:
  piezas_a_descontar (integer para descontar en BD)
```

---

## 📦 FLUJO DE SINCRONIZACIÓN LOCAL ↔ REMOTA

### Carga Inicial (Almacén)

```
1. AlmacenPage → AlmacenController.build()
2. AlmacenNotifier._cargarDatosIniciales()
   ├─ OfflineService.hayInternet() → boolean
   ├─ if (hayInternet):
   │  └─ AlmacenRepository.sincronizarConSupabase()
   │     ├─ Descarga almacenes
   │     ├─ Descarga proveedores (marcas)
   │     ├─ Descarga productos (paginados: limit=1000)
   │     ├─ Inserta todo en SQLite (REEMPLAZA tabla)
   │     └─ Retorna lista de productos
   └─ Lee de SQLite local
3. AlmacenNotifier usa productSearchRevisionProvider para invalidar búsquedas
4. Realtime listener activo:
   ├─ Escucha cambios en tabla productos
   ├─ Debouncer: acumula cambios en Set
   ├─ Emite InventoryRealtimeEvent después de delay
   └─ AlmacenNotifier recibe y hace recargarLocalSilencioso()
```

### Escritura de Datos

```
Ingreso de Stock:
  IngresoMercaderiaPage
  → InventarioService.ajustarStock() (RPC)
  → RPC: ajustar_stock_y_kardex
     ├─ UPDATE inventario_almacen (increment)
     ├─ INSERT kardex
     ├─ [ATÓMICO]
     └─ Realtime dispara cambio
  → AlmacenNotifier recibe evento
  → recargarLocalSilencioso()
  → SQLite actualizado

Traslado de Stock:
  MoverStockPage
  → InventarioService.trasladarStock() (RPC)
  → RPC: trasladar_stock
     ├─ UPDATE origen (decrement)
     ├─ UPDATE destino (increment)
     ├─ INSERT kardex (2 movimientos)
     ├─ [ATÓMICO]
     └─ Realtime dispara 2 cambios
  → Debouncer acumula
  → AlmacenNotifier recibe evento
  → recargarLocalSilencioso()
  → SQLite actualizado
```

---

## 🔒 FLUJO DE AUTENTICACIÓN

```
SplashScreen (3 seg)
  → Supabase.instance.client.auth.currentUser
  
  if (usuario autenticado):
    ├─ SplashScreen._navegarSiguientePantalla()
    ├─ Obtener rol desde empleados tabla
    ├─ Guardar en rolUsuarioActual (global)
    ├─ ConfiguracionService.cargarNegocio() (ya en main.dart)
    └─ NavegAr a HomePage
    
  else:
    └─ Navegar a LoginPage

LoginPage
  → AuthController.signIn(email, password)
  ├─ Supabase.auth.signInWithPassword()
  ├─ Doble validación:
  │  ├─ user != null
  │  └─ empleados.select().eq(auth_id, user.id) → debe existir
  ├─ Guardar rol en rolUsuarioActual
  ├─ Cambio obligatorio si force_password_change == true
  │  └─ AuthController.cambiarPassword()
  ├─ ConfiguracionService.cargarNegocio()
  └─ Navegar a HomePage

LogOut:
  → Supabase.auth.signOut()
  → Navegar a LoginPage
  → Limpiar datos locales (¿se hace?)
```

---

## 📡 REALTIME Y SINCRONIZACIÓN

### RealtimeInventorySyncService

```
Conexión:
  ├─ Provider global (KeepAlive)
  ├─ AppLifecycleListener registrado
  ├─ Escucha PostgresChangeEvent.all
  ├─ Tabla: public.productos
  └─ Debouncer activo

Evento Realtime:
  1. Callback recibe payload
  2. Extrae product_id
  3. _queueProductoParaSync(id)
     ├─ Agrega a Set<int> _productosAfectados
     ├─ Cancela timer anterior
     ├─ Inicia nuevo timer (500ms)
  4. Timer expira:
     ├─ _eventController.add(InventoryRealtimeEvent)
     ├─ AlmacenNotifier escucha
     ├─ Hace recargarLocalSilencioso()
     └─ Invalida productSearchRevisionProvider

Recuperación (App Resume):
  ├─ AppLifecycleListener.onResume()
  ├─ _ejecutarRecuperacion()
  ├─ Lee cambios desde última sincronización
  └─ Emite evento si hay cambios
```

### Posibles Condiciones de Carrera

```
⚠️ Race 1: Edición Local vs Realtime
  - Usuario edita stock en entrada
  - Simultáneamente Realtime trae cambio
  - ¿Cuál gana? Probablemente Realtime (sobrescribe)

⚠️ Race 2: Venta vs Ingreso
  - Usuario vende mientras otro está ingresando
  - RPC should be atomic, pero SQLite local podría estar desactualizado

⚠️ Race 3: Búsqueda vs Invalidación
  - Usuario busca mientras productSearchRevisionProvider cambia
  - Búsqueda se reinicia
```

---

## 💾 OFFLINE Y VENTAS PENDIENTES

### Caché de Catálogo

```
OfflineService.guardarCatalogo()
  ├─ Recibe lista completa de productos
  ├─ jsonEncode() → String
  ├─ SharedPreferences.setString(_keyCatalogo)
  └─ Se llama después de sincronización exitosa

OfflineService.obtenerCatalogoCache()
  ├─ Lee desde SharedPreferences
  ├─ jsonDecode() → List
  ├─ Si corrupción → retorna []
  └─ Usado si no hay internet
```

### Cola de Ventas Offline

```
Cuando no hay internet:
  1. ProcesarVentaUseCase FALLA en RPC
  2. OfflineService.guardarVentaOffline(datos)
     ├─ Obtiene vendingasPendientes actuales
     ├─ Agrega nueva
     ├─ jsonEncode() → String
     ├─ SharedPreferences.setString(_keyVentasPendientes)
     └─ Venta guardada localmente

Cuando vuelve internet:
  1. ¿Quién detecta y sincroniza?
     ├─ ¿HomeRefreshNotifier disparado?
     ├─ ¿Detección manual de conectividad?
     ├─ ¿Tiempo de polling?
  2. OfflineService.obtenerVentasOffline()
     └─ Retorna ventas pendientes
  3. Reintentar cada venta
  4. Si éxito → OfflineService.limpiarVentasOffline()
```

---

## 🔐 MATRIZ DE ROLES Y PERMISOS

```
Roles detectados en código:
  - admin
  - vendedor (default)
  - inventario (¿?)
  - visualizador (¿?)

Validación:
  ├─ En cliente: rolUsuarioActual (string)
  ├─ En servidor: ?
  ├─ RLS: ?
  ├─ Restricciones funcionales: ¿Solo visual o real?
  └─ Edge Functions: create_employee, delete_employee
```

---

## 🚀 RPC Y ATOMICIDAD

### Garantías de Atomicidad

```
✅ RPC: ajustar_stock_y_kardex
   ├─ UPDATE inventario_almacen
   ├─ INSERT kardex
   └─ [TRANSACCIÓN EN BD]

✅ RPC: trasladar_stock
   ├─ UPDATE almacén origen
   ├─ UPDATE almacén destino
   ├─ INSERT kardex (entrada)
   ├─ INSERT kardex (salida)
   └─ [TRANSACCIÓN EN BD]

✅ RPC: process_sale
   ├─ INSERT venta
   ├─ INSERT detalle_ventas
   ├─ Llama ajustar_stock_y_kardex (o similar)
   ├─ INSERT pagos_venta
   └─ [¿TRANSACCIÓN EN BD?]

❓ RPC: crear_producto_con_stock
   ├─ INSERT productos
   ├─ INSERT inventario_almacen
   └─ [¿TRANSACCIÓN EN BD?]

❓ RPC: increment_stock
   └─ UPDATE inventario_almacen
     [Riesgo de race condition en anulaciones]

❓ RPC: get_dashboard_summary
   └─ SELECT (read-only, sin riesgo)
```

---

## 📊 CONSUMO DE DATOS

### Sincronización Manual

```
AlmacenRepository.sincronizarConSupabase()
  └─ while (hasMore):
     ├─ Descarga batch de 1000 productos
     ├─ Incluye inventario_almacen (join)
     ├─ Paginación: offset, limit 1000
     └─ INSERT/UPSERT en SQLite
```

### Búsqueda de Productos

```
AlmacenPage / SeleccionProductosV2
  → ProductSearchWidget
  ├─ Busca en productos tabla SQLite
  ├─ Filtro: nombre LIKE query (case-insensitive)
  ├─ Retorna lista para mostrar
  └─ Invalidación: productSearchRevisionProvider
```

### Reportes

```
ReportesPage / ReportesNotifier
  ├─ Carga reportes financieros
  ├─ Carga inventario por revisión
  ├─ Silent sync: carga en background
  ├─ Caché local: no recargar si params iguales
  └─ Paginación: ¿existe?
```

---

## 🎨 COMPONENTES COMPARTIDOS

### Widgets Reutilizados

```
core/widgets/:
  ├─ almacen_stock_input.dart → Input cajas/unidades
  ├─ app_text_field.dart → Campo de texto estilizado
  ├─ document_form_kit.dart → Formulario genérico
  ├─ editar_precios_documento_page.dart → Editor de precios
  └─ global_date_filter.dart → Filtro de fecha

features/shared/widgets/:
  ├─ product_card.dart → Card de producto
  ├─ product_quantity_dialog.dart → Input cantidad
  ├─ product_search_widget.dart → Búsqueda con autocomplete
  └─ shimmer_detalle.dart → Esqueleto de carga

Potencial duplicación:
  ├─ ¿product_card y product_search_widget comparten lógica?
  ├─ ¿Múltiples formas de editar precios?
  └─ ¿Múltiples formularios CRUD?
```

---

## 📝 ÁREAS DE ALTO RIESGO IDENTIFICADAS

### 1. Conversión de Cajas/Unidades
- **Ubicaciones**: stock_utils, procesar_venta_usecase, almacen_repository
- **Riesgo**: Inconsistencia en cálculos
- **Métodos deprecados**: convertToUnits, convertirACantidadReal, calcularSaldoMixto

### 2. Race Conditions en Realtime
- **Ubicación**: RealtimeInventorySyncService (debouncer)
- **Riesgo**: Cambios simultáneos local + remoto
- **Síntomas**: Stock mostrado incorrecto temporalmente

### 3. Atomicidad de Ventas
- **Ubicación**: ProcesarVentaUseCase + process_sale RPC
- **Riesgo**: Venta registrada sin stock descontado
- **Síntomas**: Stock negativo, ventas duplicadas si reintento

### 4. Memory Leaks
- **Ubicaciones**: 
  - Controllers no liberados
  - Streams sin cerrar
  - Listeners en Realtime
- **Síntomas**: Lentitud después de usar la app

### 5. Errores Silenciosos
- **Ubicaciones**: try/catch bloques con solo debugPrint
- **Riesgo**: Errores no comunicados al usuario
- **Síntomas**: Operaciones no completadas silenciosamente

### 6. Validación de Roles
- **Ubicación**: rolUsuarioActual (variable global)
- **Riesgo**: Validación solo visual, no enforced en servidor
- **Síntomas**: Acceso a funciones restringidas si se hackea cliente

---

## 🔍 MÉTODOS SIN PRUEBAS (CRÍTICOS)

```
❌ No testeado:
  - StockUtils.calcularTotalPiezas()
  - StockUtils.formatStock()
  - StockUtils.getTipoVentaFromMap()
  
  - InventarioService.ajustarStock()
  - InventarioService.trasladarStock()
  
  - ProcesarVentaUseCase.ejecutar()
  - VentasRepository.processSaleRpc()
  
  - OfflineService (caché y sync)
  - RealtimeInventorySyncService (debouncer)
  
  - Conversiones de fecha (TimeZone)
  - Cálculos financieros
```

---

