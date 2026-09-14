import '../../../utils/stock_utils.dart';
import '../../catalogo/domain/catalog_item_type.dart';
import 'product_unit_configuration.dart';

class Producto {
  final int id;
  final String? codigo;
  final String nombre;
  final String? codigoBarras;
  final String? descripcion;
  final double precioUnidad;
  final double? precioCaja;
  final double precioCompra;
  final String? unidadMedida;
  final int? cantidadPorCaja;
  final String? tipoVenta;
  final String? categoria;
  final int? proveedorId;
  final bool permitirSinStock;
  final CatalogItemType itemType;
  final String? imagenPath;
  final double pesoKg;
  final String unidadGre;
  final double stockMinimo;
  final List<InventarioAlmacen> inventario;
  final ProductUnitConfiguration? unitConfiguration;

  bool get esServicio => itemType.isService;
  bool get esInventariable => itemType.isInventoriable;
  bool get esBundle => itemType.isBundle;

  SaleUnitType get legacySaleType {
    final explicit = tipoVenta?.trim() ?? '';
    if (explicit.isNotEmpty) return StockUtils.getTipoVentaFromString(explicit);
    final unit = (unidadMedida ?? '').toLowerCase();
    if (unit.contains('paquete')) return SaleUnitType.paquete;
    if (unit.contains('caja')) {
      return (cantidadPorCaja ?? 1) > 1
          ? SaleUnitType.ambos
          : SaleUnitType.caja;
    }
    return SaleUnitType.unidad;
  }

  Producto({
    required this.id,
    this.codigo,
    required this.nombre,
    this.codigoBarras,
    this.descripcion,
    required this.precioUnidad,
    this.precioCaja,
    required this.precioCompra,
    this.unidadMedida,
    this.cantidadPorCaja,
    this.tipoVenta,
    this.categoria,
    this.proveedorId,
    required this.permitirSinStock,
    this.itemType = CatalogItemType.stockProduct,
    this.imagenPath,
    this.pesoKg = 0,
    this.unidadGre = 'NIU',
    this.stockMinimo = 0,
    Iterable<InventarioAlmacen> inventario = const [],
    this.unitConfiguration,
  }) : inventario = List<InventarioAlmacen>.unmodifiable(inventario);
}

/// Cantidad visible en la unidad base comercial. El mapper de infraestructura
/// convierte el entero almacenado usando la escala del perfil antes de crear
/// este objeto.
class InventarioAlmacen {
  const InventarioAlmacen({required this.almacenId, required this.cantidad});

  final int almacenId;
  final double cantidad;
}