# AUDITORÍA MAESTRA - ferreteria_app

## Estado
Documento maestro preliminar basado en evidencia verificada. No modifica lógica de la aplicación.

## Alcance confirmado hasta ahora
- Fase 0 completada: mapa general del proyecto.
- Bloque 1 revisado: lógica de stock.
- Código inspeccionado: `stock_utils.dart`, `stock_helper.dart`, `almacen_stock_input.dart`, `product_quantity_dialog.dart`, `stock_utils_test.dart`.
- Dependencias cruzadas verificadas: ingreso de mercadería, traslados, ventas y uso compartido de `StockUtils`.

## Problemas confirmados

### 1. Código muerto o legado
- `convertToUnits()` en `lib/core/utils/stock_utils.dart`.
- `convertirACantidadReal()` en `lib/core/utils/stock_utils.dart`.
- `calcularSaldoMixto()` en `lib/core/utils/stock_utils.dart`.
- `getTipoVenta()` en `lib/core/utils/stock_utils.dart`.
- `lib/features/almacen/utils/stock_helper.dart` solo re-exporta `stock_utils.dart`.

Riesgo actual: bajo. No se observó uso productivo confirmado de estas rutas.

### 2. Pruebas desactualizadas
- `test/stock_utils_test.dart` sigue usando `convertToUnits()`, que está deprecado.
- La cobertura actual no valida la lógica vigente de `calcularTotalPiezas()` ni `getTipoVentaFromMap()`.

Riesgo actual: medio. Puede ocultar regresiones en cálculos de stock.

### 3. Restricción de stock con comportamiento sensible
- `ProductQuantityDialog` usa `aplicarRestriccionStock` para truncar cantidades al stock disponible.
- El comportamiento es correcto según la implementación actual, pero el parámetro no está documentado con suficiente claridad para los callers.

Riesgo actual: medio. No hay bug confirmado, pero sí riesgo de uso inconsistente.

## Código reutilizable detectado
- `StockUtils.calcularTotalPiezas()` ya centraliza la conversión de cajas y unidades.
- `StockUtils.getTipoVentaFromMap()` ya centraliza la lectura del tipo de venta.
- `AlmacenStockInput` y `ProductQuantityDialog` cumplen roles distintos y no muestran duplicación dañina en el bloque revisado.

## Plan de solución seguro

### Prioridad 1: limpieza controlada
- [x] Retirar métodos deprecados que no tienen uso productivo confirmado.
- [x] Eliminar `stock_helper.dart` si se mantiene la referencia directa a `stock_utils.dart`.
- [x] Actualizar tests para cubrir funciones actuales.

### Prioridad 2: endurecer la lógica de stock
- [x] Documentar el uso esperado de `aplicarRestriccionStock`.
- [x] Añadir pruebas para stock insuficiente, tipo de venta y conversiones mixtas.

### Prioridad 3: continuar auditoría por bloques
- [x] Ventas atómicas (Anulación segura implementada).
- [ ] Inventario y RPC.
- [x] SQLite, offline y Realtime (Race conditions resueltas).
- [ ] Home, auth y roles.

## Pruebas necesarias
- `StockUtils.calcularTotalPiezas()` con `unidad`, `caja` y `ambos`.
- `StockUtils.getTipoVentaFromMap()` con datos viejos y nuevos.
- `ProductQuantityDialog` con stock insuficiente y restricción activa.
- Validación de que los tests dejan de depender de métodos deprecados.

## Criterio para marcar código como muerto
Solo se debe eliminar si se confirma:
- Sin uso en producción.
- Sin referencia en widgets, providers, callbacks, streams o navegación.
- Sin dependencia indirecta en módulos de inventario, ventas o reportes.

## Próximo bloque recomendado
Bloque 2: venta atómica.

## Nota
Este documento es acumulativo y debe actualizarse a medida que se verifiquen nuevos bloques. No asume problemas no revisados todavía.
