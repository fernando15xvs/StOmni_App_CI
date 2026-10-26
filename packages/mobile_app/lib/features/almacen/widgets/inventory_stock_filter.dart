/// Presentation-only inventory filters; server-side inventory policy
/// and the catalog search/sorting are left unchanged.
enum InventoryStockFilter {
  all('Todos'),
  available('Con stock'),
  empty('Sin stock');

  const InventoryStockFilter(this.label);
  final String label;
}

class InventoryStockFiltering {
  const InventoryStockFiltering._();

  static List<Map<String, dynamic>> apply(
    List<Map<String, dynamic>> products,
    InventoryStockFilter filter,
  ) {
    if (filter == InventoryStockFilter.all) return products;
    return products
        .where((product) {
          final stock = product['_totalStock'];
          // Missing or invalid stock must not be interpreted as zero.
          if (stock is! num) return false;
          if (filter == InventoryStockFilter.available) return stock > 0;
          return stock <= 0;
        })
        .toList(growable: false);
  }
}
