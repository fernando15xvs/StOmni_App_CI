import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeConnectivity implements InventoryConnectivityGateway {
  _FakeConnectivity(this.online);

  bool online;

  @override
  Future<bool> hasInternet() async => online;
}

class _FakeCatalogGateway implements InventoryCatalogGateway {
  bool failSync = false;
  int syncCalls = 0;
  List<Producto> products = const [];
  Map<int, String> brands = const {};
  List<InventoryWarehouseRecord> warehouses = const [];
  List<Producto> inactiveProducts = const [];

  @override
  Future<void> synchronize({bool propagateError = false}) async {
    syncCalls++;
    if (failSync) throw StateError('offline');
  }

  @override
  Future<List<Producto>> searchProducts(String query) async => products;

  @override
  Future<Map<int, String>> loadBrands() async => brands;

  @override
  Future<List<InventoryWarehouseRecord>> loadWarehouses() async => warehouses;

  @override
  Future<List<Producto>> loadInactiveProducts() async => inactiveProducts;
}

class _FakeStockMovementGateway implements StockMovementGateway {
  StockMovementResult response = const StockMovementResult(
    transferId: null,
    isTransfer: false,
  );
  RegisterStockMovementCommand? received;

  @override
  Future<StockMovementResult> register(
    RegisterStockMovementCommand command,
  ) async {
    received = command;
    return response;
  }
}

class _FakeEntryWriter implements MerchandiseEntryWriter {
  final List<String> events;
  MerchandiseEntryCommand? received;

  _FakeEntryWriter(this.events);

  @override
  Future<void> register(MerchandiseEntryCommand command) async {
    received = command;
    events.add('register');
  }
}

class _FakeSyncGateway implements InventoryProductSyncGateway {
  final List<String> events;
  int? productId;

  _FakeSyncGateway(this.events);

  @override
  Future<void> synchronizeProduct(int productId) async {
    this.productId = productId;
    events.add('product-sync');
  }

  @override
  void synchronizeCatalogInBackground() {
    events.add('catalog-sync');
  }
}

class _FakeAuthorizer implements OperationAuthorizer {
  @override
  String? currentAuthUserId = 'user-1';
  Set<AppPermission> lastRequired = const <AppPermission>{};

  @override
  Future<String> require(
    Set<AppPermission> permissions, {
    bool allowOffline = false,
  }) async {
    lastRequired = Set<AppPermission>.from(permissions);
    return currentAuthUserId!;
  }
}

class _FakeLifecycleGateway implements ProductLifecycleGateway {
  final List<String> calls = [];

  @override
  Future<ProductDeletionEvaluation> evaluateDeletion(int productId) async {
    calls.add('evaluate:$productId');
    return const ProductDeletionEvaluation(
      openingMovementCount: 1,
      canUpdateOpening: true,
    );
  }

  @override
  Future<void> deactivate(int productId) async {
    calls.add('deactivate:$productId');
  }

  @override
  Future<void> deletePermanently(int productId) async {
    calls.add('delete:$productId');
  }

  @override
  Future<void> reactivate(int productId) async {
    calls.add('reactivate:$productId');
  }
}

Producto _product({
  required int id,
  required String name,
  required double price,
  required double stock,
  double minimumStock = 0,
  int? supplierId,
  ProductUnitConfiguration? unitConfiguration,
}) {
  return Producto(
    id: id,
    codigo: 'P$id',
    nombre: name,
    precioUnidad: price,
    precioCompra: price / 2,
    tipoVenta: 'UNIDAD',
    proveedorId: supplierId,
    permitirSinStock: false,
    stockMinimo: minimumStock,
    inventario: [InventarioAlmacen(almacenId: 1, cantidad: stock)],
    unitConfiguration: unitConfiguration,
  );
}

void main() {
  group('InventoryCatalogUseCase', () {
    test('sincroniza, carga snapshot tipado y enriquece productos', () async {
      final gateway = _FakeCatalogGateway()
        ..products = [
          _product(id: 1, name: 'Taladro', price: 35, stock: 7, supplierId: 9),
        ]
        ..brands = {9: 'Marca Uno'}
        ..warehouses = const [
          InventoryWarehouseRecord(id: 1, name: 'Principal', active: true),
        ];
      final useCase = InventoryCatalogUseCase(
        gateway: gateway,
        connectivity: _FakeConnectivity(true),
      );

      final snapshot = await useCase.loadInitial();

      expect(gateway.syncCalls, 1);
      expect(snapshot.offline, isFalse);
      expect(snapshot.warehouses.single.name, 'Principal');
      expect(snapshot.products.single.totalStock, 7);
      expect(snapshot.products.single.brandName, 'Marca Uno');
      expect(snapshot.products.single.searchText, contains('taladro'));
      expect(snapshot.products.single.mainPrice, 35);
      expect(snapshot.products.single.product.id, 1);
    });

    test('mantiene snapshot local y marca offline si falla sync', () async {
      final gateway = _FakeCatalogGateway()
        ..failSync = true
        ..products = [_product(id: 1, name: 'Producto', price: 10, stock: 2)];
      final useCase = InventoryCatalogUseCase(
        gateway: gateway,
        connectivity: _FakeConnectivity(true),
      );

      final snapshot = await useCase.loadInitial();

      expect(snapshot.offline, isTrue);
      expect(snapshot.products, hasLength(1));
    });

    test('usa precio y stock de la unidad base configurada', () async {
      final bottle = CommercialPresentation.base(
        code: 'botella',
        singularLabel: 'Botella',
        pluralLabel: 'Botellas',
      );
      final configuration = ProductUnitConfiguration(
        revision: 1,
        profile: ProductUnitProfile(
          baseUnit: bottle,
          presentations: [
            bottle,
            CommercialPresentation(
              code: 'pack_6',
              singularLabel: 'Pack',
              pluralLabel: 'Packs',
              baseQuantity: 6,
            ),
          ],
        ),
      );
      final gateway = _FakeCatalogGateway()
        ..products = [
          _product(
            id: 1,
            name: 'Agua',
            price: 2,
            stock: 13,
            unitConfiguration: configuration,
          ),
        ];
      final useCase = InventoryCatalogUseCase(
        gateway: gateway,
        connectivity: _FakeConnectivity(false),
      );

      final item = (await useCase.reloadLocalProducts(brands: const {})).single;

      expect(item.mainPrice, 2);
      expect(item.formattedStock, '2 Packs y 1 Botella');
    });

    test('filtra stock bajo y ordena por precio con items tipados', () async {
      final gateway = _FakeCatalogGateway()
        ..products = [
          _product(id: 1, name: 'B', price: 20, stock: 1, minimumStock: 2),
          _product(id: 2, name: 'A', price: 10, stock: 8, minimumStock: 2),
        ];
      final useCase = InventoryCatalogUseCase(
        gateway: gateway,
        connectivity: _FakeConnectivity(false),
      );
      final enriched = await useCase.reloadLocalProducts(brands: const {});

      final lowStock = useCase.filterAndSort(
        products: enriched,
        lowStockOnly: true,
        sortBy: InventorySortField.price,
      );
      final byPrice = useCase.filterAndSort(
        products: enriched,
        sortBy: InventorySortField.price,
      );

      expect(lowStock.map((e) => e.product.id), [1]);
      expect(byPrice.map((e) => e.product.id), [2, 1]);
    });
  });

  test('RegisterStockMovementUseCase conserva resultado tipado', () async {
    final gateway = _FakeStockMovementGateway()
      ..response = const StockMovementResult(transferId: 44, isTransfer: true);
    final authorizer = _FakeAuthorizer();
    final useCase = RegisterStockMovementUseCase(
      gateway,
      authorizer: authorizer,
    );

    final result = await useCase(
      const RegisterStockMovementCommand(
        requestId: 'req-1',
        productId: 7,
        quantity: 3,
        sourceWarehouseId: 1,
        destinationWarehouseId: 2,
        isWaste: false,
        reason: 'Reposición',
      ),
    );

    expect(result.transferId, 44);
    expect(result.isTransfer, isTrue);
    expect(result.transferenciaId, 44);
    expect(result.esTraslado, isTrue);
    expect(gateway.received?.productId, 7);
    expect(authorizer.lastRequired, {AppPermission.inventoryAdjust});
  });

  test(
    'RegisterMerchandiseEntryUseCase conserva orden de persistencia y sync',
    () async {
      final events = <String>[];
      final writer = _FakeEntryWriter(events);
      final sync = _FakeSyncGateway(events);
      final authorizer = _FakeAuthorizer();
      final useCase = RegisterMerchandiseEntryUseCase(
        writer: writer,
        sync: sync,
        authorizer: authorizer,
      );
      final command = MerchandiseEntryCommand(
        requestId: 'entry-1',
        productId: 5,
        date: DateTime(2026, 8, 30),
        entryType: 'Compra',
        document: 'F001-1',
        supplierId: 2,
        observations: '',
        warehouses: const [
          MerchandiseWarehouseAllocation(warehouseId: 1, baseQuantity: 4),
        ],
        cost: 5,
        unitPrice: 8,
        boxPrice: 7,
        comparativeBoxPrice: 70,
      );

      await useCase(command);

      expect(events, ['register', 'product-sync', 'catalog-sync']);
      expect(sync.productId, 5);
      expect(writer.received, same(command));
      expect(writer.received!.warehouses.single.warehouseId, 1);
      expect(authorizer.lastRequired, {AppPermission.inventoryReceive});
    },
  );

  group('ProductLifecycleUseCase', () {
    test(
      'bloquea desactivación y borrado permanente en modo offline',
      () async {
        final gateway = _FakeLifecycleGateway();
        final useCase = ProductLifecycleUseCase(gateway);

        expect(
          () => useCase.deactivate(1, offline: true),
          throwsA(isA<ProductLifecycleOfflineException>()),
        );
        expect(
          () => useCase.deletePermanently(1, offline: true),
          throwsA(isA<ProductLifecycleOfflineException>()),
        );
        expect(gateway.calls, isEmpty);
      },
    );

    test(
      'delega operaciones permitidas al gateway con evaluación tipada',
      () async {
        final gateway = _FakeLifecycleGateway();
        final useCase = ProductLifecycleUseCase(gateway);

        final evaluation = await useCase.evaluateDeletion(3);
        await useCase.deactivate(3, offline: false);
        await useCase.deletePermanently(3, offline: false);
        await useCase.reactivate(3);

        expect(evaluation.openingMovementCount, 1);
        expect(evaluation.canUpdateOpening, isTrue);
        expect(gateway.calls, [
          'evaluate:3',
          'deactivate:3',
          'delete:3',
          'reactivate:3',
        ]);
      },
    );
  });
}
