import 'app_formatters.dart';
import 'stock_utils.dart';

class PriceVisualItem {
  final String label;
  final double value;
  final bool destacado;

  const PriceVisualItem({
    required this.label,
    required this.value,
    this.destacado = true,
  });
}

class PriceVisualUtils {
  /// Devuelve el precio de la presentación comercial de una línea de venta.
  /// Prioriza subtotal/cantidad porque respeta descuentos y precios editados.
  static double getPrecioComercialLinea({
    required double precioUnitarioBase,
    double? precioUnitarioComercial,
    double? subtotal,
    required int cantidadVisual,
    required int pcs,
    required String tipoVentaProducto,
    required String tipoUnidad,
  }) {
    if (cantidadVisual > 0 && subtotal != null) {
      return subtotal / cantidadVisual;
    }
    if (precioUnitarioComercial != null && precioUnitarioComercial > 0) {
      return precioUnitarioComercial;
    }

    final unidad = StockUtils.normalizarTipoUnidad(tipoUnidad);
    final tipo = StockUtils.getTipoVentaFromString(tipoVentaProducto);
    final equivalencia = pcs > 0 ? pcs : 1;

    if (unidad == 'caja') {
      if (tipo == SaleUnitType.caja) return precioUnitarioBase;
      return precioUnitarioBase * equivalencia;
    }

    return precioUnitarioBase;
  }

  static double getPrecioBaseEmpaque(Map<String, dynamic> producto) {
    final precioUnidad = AppFormatters.toDouble(producto['precio_unidad']);
    final precioCaja = AppFormatters.toDouble(producto['precio_caja']);
    return precioCaja > 0 ? precioCaja : precioUnidad;
  }

  static double getPrecioEmpaqueCompleto(Map<String, dynamic> producto) {
    final pcs = AppFormatters.toInt(producto['cantidad_por_caja']);
    return StockUtils.calcularPrecioEmpaqueCompleto(
      precioBaseEmpaque: getPrecioBaseEmpaque(producto),
      pcs: pcs,
    );
  }

  /// Precio principal para ordenar el inventario.
  /// En PAQUETE es el precio completo del paquete.
  /// En las modalidades mixtas es el precio suelto del paquete o unidad.
  static double getPrecioPrincipalInventario(Map<String, dynamic> producto) {
    final tipo = StockUtils.getTipoVentaFromMap(producto);
    final precioUnidad = AppFormatters.toDouble(producto['precio_unidad']);

    if (tipo == SaleUnitType.paquete || tipo == SaleUnitType.caja) {
      return getPrecioEmpaqueCompleto(producto);
    }

    if (precioUnidad > 0) return precioUnidad;
    return getPrecioBaseEmpaque(producto);
  }

  static List<PriceVisualItem> getInventoryPriceItems(
    Map<String, dynamic> producto,
  ) {
    final tipo = StockUtils.getTipoVentaFromMap(producto);
    final precioUnidad = AppFormatters.toDouble(producto['precio_unidad']);
    final precioBaseEmpaque = getPrecioBaseEmpaque(producto);
    final precioCompleto = getPrecioEmpaqueCompleto(producto);

    switch (tipo) {
      case SaleUnitType.paquete:
      case SaleUnitType.caja:
        return [
          PriceVisualItem(label: 'Precio por pieza', value: precioBaseEmpaque),
          PriceVisualItem(
            label: 'Precio paquete completo',
            value: precioCompleto,
          ),
        ];

      case SaleUnitType.cajaPaquetes:
        return [
          PriceVisualItem(label: 'Precio paquete', value: precioUnidad),
          PriceVisualItem(
            label: 'Precio paquete en caja',
            value: precioBaseEmpaque,
          ),
          PriceVisualItem(label: 'Precio caja completa', value: precioCompleto),
        ];

      case SaleUnitType.cajaUnidades:
        return [
          PriceVisualItem(label: 'Precio unidad', value: precioUnidad),
          PriceVisualItem(
            label: 'Precio unidad en caja',
            value: precioBaseEmpaque,
          ),
          PriceVisualItem(label: 'Precio caja completa', value: precioCompleto),
        ];

      case SaleUnitType.unidad:
        return [PriceVisualItem(label: 'Precio unitario', value: precioUnidad)];
    }
  }
}
