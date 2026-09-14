/// Reglas puras para filtrar y ordenar el catálogo visible durante una venta.
///
/// Mantiene `Map<String, dynamic>` solo como puente de compatibilidad hasta la
/// fase de tipado de límites. No depende de Flutter, Riverpod ni repositorios.
class SaleProductSelection {
  const SaleProductSelection._();

  static List<Map<String, dynamic>> filterAndSortLegacy({
    required Iterable<Map<String, dynamic>> products,
    required Map<int, String> brandByProviderId,
    required String query,
    required Set<int> selectedProductIds,
  }) {
    final normalizedQuery = query.trim().toLowerCase();

    final result = products.where((product) {
      if (normalizedQuery.isEmpty) return true;

      final providerId = (product['proveedor_id'] as num?)?.toInt();
      final searchable = <String>[
        product['nombre']?.toString() ?? '',
        product['codigo']?.toString() ?? '',
        product['codigo_barras']?.toString() ?? '',
        brandByProviderId[providerId] ?? '',
      ];

      return searchable.any(
        (value) => value.toLowerCase().contains(normalizedQuery),
      );
    }).toList(growable: false);

    result.sort((a, b) {
      final aId = (a['id'] as num?)?.toInt();
      final bId = (b['id'] as num?)?.toInt();
      final aSelected = aId != null && selectedProductIds.contains(aId);
      final bSelected = bId != null && selectedProductIds.contains(bId);

      if (aSelected != bSelected) return aSelected ? -1 : 1;

      final aName = (a['nombre'] ?? '').toString().toLowerCase();
      final bName = (b['nombre'] ?? '').toString().toLowerCase();
      final byName = aName.compareTo(bName);
      if (byName != 0) return byName;

      return (aId ?? 0).compareTo(bId ?? 0);
    });

    return result;
  }
}
