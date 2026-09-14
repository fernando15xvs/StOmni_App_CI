import '../../shared/models/producto_busqueda.dart';

abstract interface class ProductSearchGateway {
  Future<List<ProductoBusqueda>> search(
    String query, {
    bool includeInactive = false,
  });
}

class SearchProductsUseCase {
  final ProductSearchGateway _gateway;

  const SearchProductsUseCase(this._gateway);

  Future<List<ProductoBusqueda>> call(
    String query, {
    bool includeInactive = false,
  }) {
    return _gateway.search(query, includeInactive: includeInactive);
  }
}
