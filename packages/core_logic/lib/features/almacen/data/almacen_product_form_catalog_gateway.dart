import '../application/product_form_catalog.dart';
import 'almacen_repository.dart';

class AlmacenProductFormCatalogGateway implements ProductFormCatalogGateway {
  const AlmacenProductFormCatalogGateway(this._repository);

  final AlmacenRepository _repository;

  @override
  Future<ProductFormCatalog> load() async {
    final results = await Future.wait<dynamic>([
      _repository.obtenerAlmacenesDirecto(),
      _repository.obtenerProveedoresDirecto(),
    ]);

    return ProductFormCatalog(
      warehouses: _mapWarehouses(results[0]),
      suppliers: _mapSuppliers(results[1]),
    );
  }

  static List<ProductWarehouseOption> _mapWarehouses(dynamic raw) {
    return _records(raw, source: 'almacenes')
        .map(
          (record) => ProductWarehouseOption(
            id: _requiredId(record, source: 'almacenes'),
            name: _requiredName(record, source: 'almacenes'),
          ),
        )
        .toList(growable: false);
  }

  static List<ProductSupplierOption> _mapSuppliers(dynamic raw) {
    return _records(raw, source: 'proveedores')
        .map(
          (record) => ProductSupplierOption(
            id: _requiredId(record, source: 'proveedores'),
            name: _requiredName(record, source: 'proveedores'),
          ),
        )
        .toList(growable: false);
  }

  static List<Map<String, dynamic>> _records(
    dynamic raw, {
    required String source,
  }) {
    if (raw is! List) {
      throw StateError('$source devolvió una respuesta inválida.');
    }

    return raw
        .map((item) {
          if (item is Map<String, dynamic>) return item;
          if (item is Map) return Map<String, dynamic>.from(item);
          throw StateError('$source contiene un registro inválido.');
        })
        .toList(growable: false);
  }

  static int _requiredId(
    Map<String, dynamic> record, {
    required String source,
  }) {
    final raw = record['id'];
    if (raw is num) return raw.toInt();
    final parsed = int.tryParse(raw?.toString() ?? '');
    if (parsed != null) return parsed;
    throw StateError('$source contiene un registro sin id válido.');
  }

  static String _requiredName(
    Map<String, dynamic> record, {
    required String source,
  }) {
    final name = record['nombre']?.toString().trim() ?? '';
    if (name.isEmpty) {
      throw StateError('$source contiene un registro sin nombre válido.');
    }
    return name;
  }
}
