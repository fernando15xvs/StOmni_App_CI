# AUDITORÍA INCREMENTAL - ferreteria_app

## BLOQUE 1 — Lógica de Stock

**Archivos analizados:**
- lib/core/utils/stock_utils.dart
- lib/features/almacen/utils/stock_helper.dart  
- lib/core/widgets/almacen_stock_input.dart
- lib/features/shared/widgets/product_quantity_dialog.dart
- test/stock_utils_test.dart

**Dependencias consultadas:**
- ingreso_mercaderia_page.dart
- mover_stock_page.dart
- procesar_venta_usecase.dart

---

## 1. Hallazgos Prioritarios

| ID | Severidad | Símbolo / Archivo | Problema | Evidencia | Riesgo | Recomendación |
|-----|-----------|------------------|----------|-----------|--------|----------------|
| H1 | BAJO | `convertToUnits()` en stock_utils.dart | Método deprecado sin uso | Definido línea 68, no llamado en código; solo en tests deprecados | Confusión de API | Marcar como @Deprecated más explícitamente o eliminar |
| H2 | BAJO | `convertirACantidadReal()` en stock_utils.dart | Método deprecado sin uso | Definido línea 91, no hay referencias | Confusión de API | Eliminar o mover a archivo de legado |
| H3 | BAJO | `calcularSaldoMixto()` en stock_utils.dart | Método deprecado sin uso | Definido línea 148, no hay referencias; comentario dice "backend maneja ahora" | Deuda técnica | Eliminar; backend RPC lo reemplazó |
| H4 | MEDIO | `aplicarRestriccionStock` en ProductQuantityDialog | Parámetro sin documentación clara | Línea 20: `this.aplicarRestriccionStock = true;` pero lógica de restricción (líneas 112-126) tiene ramas complejas | Si es false, se permite vender sin stock; si es true, se trunca al disponible | Documentar cuándo pedir cada valor y validar en callers |
| H5 | BAJO | stock_helper.dart | Archivo solo para export (re-exportación) | 3 líneas: solo exporta stock_utils.dart | Ruta de importación confusa | Eliminar archivo; cambiar imports directos a stock_utils.dart |
| H6 | BAJO | Tests con métodos deprecados | stock_utils_test.dart llama `convertToUnits()` | Test línea 7 usa método marcado @Deprecated | Tests no validan lógica actual | Reescribir tests con funciones nuevas (calcularTotalPiezas, getTipoVentaFromMap) |

---

## 2. Código Posiblemente Muerto

| Símbolo | Archivo | Referencias encontradas | Certeza | Recomendación |
|---------|---------|-------------------------|---------|----------------|
| convertToUnits() | stock_utils.dart | 0 en código productivo, 1 en test deprecado | Muy Alta | Eliminar o mover a sección legado |
| convertirACantidadReal() | stock_utils.dart | 0 en todo el proyecto | Muy Alta | Eliminar |
| calcularSaldoMixto() | stock_utils.dart | 0 en todo el proyecto; comentario dice @Deprecated | Muy Alta | Eliminar |
| getTipoVenta() | stock_utils.dart | 0 en código; @Deprecated remite a getTipoVentaFromMap | Alta | Eliminar; función fue reemplazada |
| stock_helper.dart | features/almacen/utils/ | 0 usos directos; solo export | Muy Alta | Eliminar archivo completo |

---

## 3. Código Duplicado o Reutilizable

**No se encontró duplicación problemática en este bloque.**

- `AlmacenStockInput` y `ProductQuantityDialog` tienen responsabilidades claras:
  - Input estático para mostrar cajas/sueltas por almacén
  - Dialog modal para seleccionar cantidad desde carrito
- Ambas reutilizan `StockUtils.calcularTotalPiezas()` → OK
- Ambas usan `TipoVentaEnum` → OK

---

## 4. Mejoras Propuestas

| Mejora | Clasificación | Objetivo | Archivos | Riesgo | Prueba necesaria |
|--------|---------------|----------|----------|--------|------------------|
| Eliminar métodos deprecados | Corrección urgente | Limpiar API pública | stock_utils.dart | Bajo (no se usan) | Grep en todo el proyecto |
| Eliminar stock_helper.dart | Corrección urgente | Simplificar importes | Cambiar imports | Muy bajo | Verificar compilación |
| Reescribir stock_utils_test.dart | Mejora segura | Validar funciones actuales | test/stock_utils_test.dart | Bajo | Ejecutar tests |
| Documentar `aplicarRestriccionStock` | Mejora segura | Claridad de comportamiento | product_quantity_dialog.dart | Muy bajo | Revisión de código |

---

## 5. Pruebas Necesarias

**Críticas (sin cobertura actual):**
- `StockUtils.calcularTotalPiezas()` con todas las combinaciones de `SaleUnitType`
- `StockUtils.getTipoVentaFromMap()` con productos sin `tipo_venta`
- `ProductQuantityDialog._confirmar()` con `aplicarRestriccionStock=true` y stock insuficiente

**Reescribir:**
- `stock_utils_test.dart` líneas 7-8: Cambiar de `convertToUnits()` a `calcularTotalPiezas()`

---

## 6. Resultado

**Estado del bloque:** ✅ **Riesgo Bajo**

Hallazgos:
- 3 métodos deprecados sin uso (seguro eliminar)
- 1 archivo innecesario (stock_helper.dart)
- Tests usan métodos deprecados (requiere reescritura)
- Lógica de restricción de stock compleja pero funcional

**Archivos pendientes directamente relacionados:**
- `lib/features/almacen/pages/nuevo_producto_page.dart` (usa getTipoVentaFromMap, línea 136)
- `lib/features/almacen/presentation/controllers/nuevo_producto_controller.dart` (calcula piezas, línea 207)

---

