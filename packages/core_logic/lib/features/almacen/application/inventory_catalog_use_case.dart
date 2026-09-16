import '../../../utils/stock_utils.dart';
import '../domain/commercial_presentation.dart';
import '../domain/producto.dart';

class InventoryWarehouseRecord {
  const InventoryWarehouseRecord({
    required this.id,
    required this.name,
    required this.active,
    this.address,
    this.ubigeo,
    this.department,
    this.province,
    this.district,
    this.localCode = '0000',
    this.reference,
  });

  final int id;
  final String name;
  final bool active;
  final String? address;
  final String? ubigeo;
  final String? department;
  final String? province;
  final String? district;
  final String localCode;
  final String? reference;
}

class InventoryCatalogItem {
  const InventoryCatalogItem({
    required this.product,
    required this.totalStock,
    required this.brandName,
    required this.searchText,
    required this.mainPrice,
    required this.active,
  });

  final Producto product;
  final double totalStock;
  final String brandName;
  final String searchText;
  final double mainPrice;
  final bool active;

  ProductUnitProfile get commercialProfile {
    final configured = product.unitConfiguration;
    if (configured != null) return configured.profile;
    return StockUtils.legacyUnitProfile(
      product.legacySaleType,
      unitsPerPackage: product.cantidadPorCaja ?? 1,
    );
  }

  String get formattedStock => commercialProfile.formatBaseQuantity(totalStock);
}

abstract interface class InventoryCatalogGateway {
  Future<void> synchronize({bool propagateError = false});
  Future<List<Producto>> searchProducts(String query);
  Future<Map<int, String>> loadBrands();
  Future<List<InventoryWarehouseRecord>> loadWarehouses();
  Future<List<Producto>> loadInactiveProducts();
}

abstract interface class InventoryConnectivityGateway {
  Future<bool> hasInternet();
}

enum InventorySortField { name, stock, price }

class InventoryCatalogSnapshot {
  final List<InventoryCatalogItem> products;
  final List<InventoryWarehouseRecord> warehouses;
  final Map<int, String> brands;
  final bool offline;

  const InventoryCatalogSnapshot({
    required this.products,
    required this.warehouses,
    required this.brands,
    required this.offline,
  });
}

class InventoryCatalogUseCase {
  final InventoryCatalogGateway _gateway;
  final InventoryConnectivityGateway _connectivity;

  const InventoryCatalogUseCase({
    required InventoryCatalogGateway gateway,
    required InventoryConnectivityGateway connectivity,
  }) : _gateway = gateway,
       _connectivity = connectivity;

  Future<InventoryCatalogSnapshot> loadInitial() async {
    final hasInternet = await _connectivity.hasInternet();
    var remoteAvailable = hasInternet;
    if (hasInternet) {
      try {
        await _gateway.synchronize(propagateError: true);
      } catch (_) {
        remoteAvailable = false;
      }
    }
    var brands = <int, String>{};
    var warehouses = <InventoryWarehouseRecord>[];
    try {
      brands = await _gateway.loadBrands();
    } catch (_) {}
    try {
      warehouses = await _gateway.loadWarehouses();
    } catch (_) {}
    final products = await reloadLocalProducts(brands: brands);
    return InventoryCatalogSnapshot(
      products: products,
      warehouses: warehouses,
      brands: brands,
      offline: !remoteAvailable,
    );
  }

  Future<InventoryCatalogSnapshot> forceOnlineRefresh() async {
    await _gateway.synchronize(propagateError: true);
    final brands = await _gateway.loadBrands();
    final warehouses = await _gateway.loadWarehouses();
    final products = await reloadLocalProducts(brands: brands);
    return InventoryCatalogSnapshot(
      products: products,
      warehouses: warehouses,
      brands: brands,
      offline: false,
    );
  }

  Future<List<InventoryCatalogItem>> reloadLocalProducts({
    required Map<int, String> brands,
  }) async {
    final products = await _gateway.searchProducts('');
    return products
        .map((product) => _enrichProduct(product, brands, active: true))
        .toList(growable: false);
  }

  Future<List<InventoryCatalogItem>> loadInactiveProducts() async {
    final results = await Future.wait<Object>([
      _gateway.loadInactiveProducts(),
      _gateway.loadBrands(),
    ]);
    final products = results[0] as List<Producto>;
    final brands = results[1] as Map<int, String>;
    return products
        .map((product) => _enrichProduct(product, brands, active: false))
        .toList(growable: false);
  }

  List<InventoryCatalogItem> filterAndSort({
    required List<InventoryCatalogItem> products,
    String query = '',
    bool lowStockOnly = false,
    InventorySortField sortBy = InventorySortField.name,
    bool ascending = true,
  }) {
    var filtered = List<InventoryCatalogItem>.from(products);
    final normalizedQuery = query.toLowerCase();
    if (normalizedQuery.isNotEmpty) {
      filtered = filtered
          .where((product) => product.searchText.contains(normalizedQuery))
          .toList();
    }
    if (lowStockOnly) {
      filtered = filtered
          .where((product) => product.totalStock <= product.product.stockMinimo)
          .toList();
    }

    int compare(InventoryCatalogItem a, InventoryCatalogItem b) {
      switch (sortBy) {
        case InventorySortField.stock:
          return a.totalStock.compareTo(b.totalStock);
        case InventorySortField.price:
          return a.mainPrice.compareTo(b.mainPrice);
        case InventorySortField.name:
          return a.product.nombre.toLowerCase().compareTo(
            b.product.nombre.toLowerCase(),
          );
      }
    }

    filtered.sort((a, b) => ascending ? compare(a, b) : compare(b, a));
    return filtered;
  }

  InventoryCatalogItem _enrichProduct(
    Producto product,
    Map<int, String> brands, {
    required bool active,
  }) {
    final brand = brands[product.proveedorId] ?? '';
    final code = product.codigo?.trim() ?? '';
    final barcode = product.codigoBarras?.trim() ?? '';
    final name = product.nombre.trim();
    return InventoryCatalogItem(
      product: product,
      totalStock: product.inventario.fold<double>(
        0,
        (sum, entry) => sum + entry.cantidad,
      ),
      brandName: brand.isEmpty ? 'Genérico' : brand,
      searchText: [
        code,
        barcode,
        name,
        brand,
      ].where((text) => text.isNotEmpty).join(' ').toLowerCase(),
      mainPrice: _mainPrice(product),
      active: active,
    );
  }

  double _mainPrice(Producto product) {
    final type = product.legacySaleType;
    final packageBase = (product.precioCaja ?? 0) > 0
        ? product.precioCaja!
        : product.precioUnidad;
    if (product.unitConfiguration != null) {
      final baseCode = product.unitConfiguration!.profile.baseUnit.code;
      final basePresentation = product.unitConfiguration!.profile.find(
        baseCode,
      )!;
      return product.precioUnidad > 0
          ? product.precioUnidad
          : (basePresentation.baseQuantity > 0
                ? packageBase / basePresentation.baseQuantity
                : packageBase);
    }
    if (type == SaleUnitType.paquete || type == SaleUnitType.caja) {
      return packageBase * (product.cantidadPorCaja ?? 1);
    }
    return product.precioUnidad > 0 ? product.precioUnidad : packageBase;
  }
}
