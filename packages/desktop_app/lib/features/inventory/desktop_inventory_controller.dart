import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DesktopInventoryItem {
  const DesktopInventoryItem(this.catalogItem);

  final InventoryCatalogItem catalogItem;

  Producto get product => catalogItem.product;
  double get totalStock => catalogItem.totalStock.toDouble();

  String get codeLabel {
    final value = product.codigo?.trim() ?? '';
    return value.isEmpty ? '—' : value;
  }

  String get supplierLabel => catalogItem.brandName;

  String get saleTypeLabel {
    final base = catalogItem.commercialProfile.baseUnit;
    if (catalogItem.commercialProfile.presentations.length == 1) {
      return base.singularLabel;
    }
    return '${base.singularLabel} + presentaciones';
  }

  CommercialPresentation get basePresentation =>
      catalogItem.commercialProfile.baseUnit;
}

class _DesktopInventoryCatalogAdapter implements InventoryCatalogGateway {
  const _DesktopInventoryCatalogAdapter(this.repository);

  final AlmacenRepository repository;

  @override
  Future<void> synchronize({bool propagateError = false}) =>
      repository.sincronizarConSupabase(propagarError: propagateError);

  @override
  Future<List<Producto>> searchProducts(String query) =>
      repository.buscarProductos(query);

  @override
  Future<Map<int, String>> loadBrands() => repository.getMarcas();

  @override
  Future<List<InventoryWarehouseRecord>> loadWarehouses() async {
    final rows = await repository.getalmacenes();
    return rows
        .map((row) {
          final rawId = row['id'];
          final id = rawId is num
              ? rawId.toInt()
              : int.tryParse(rawId?.toString() ?? '');
          final name = row['nombre']?.toString().trim() ?? '';
          if (id == null || id <= 0 || name.isEmpty) {
            throw StateError(
              'El catálogo de almacenes contiene un registro inválido.',
            );
          }
          String? optionalText(Object? value) {
            final text = value?.toString().trim() ?? '';
            return text.isEmpty ? null : text;
          }

          return InventoryWarehouseRecord(
            id: id,
            name: name,
            active: row['activo'] != false,
            address: optionalText(row['direccion']),
            ubigeo: optionalText(row['ubigeo']),
            department: optionalText(row['departamento']),
            province: optionalText(row['provincia']),
            district: optionalText(row['distrito']),
            localCode: optionalText(row['cod_local']) ?? '0000',
            reference: optionalText(row['referencia']),
          );
        })
        .toList(growable: false);
  }

  @override
  Future<List<Producto>> loadInactiveProducts() async {
    final rows = await repository.obtenerProductosInactivos();
    return rows.map(ProductoMapper.decode).toList(growable: false);
  }
}

class _DesktopInventoryConnectivityAdapter
    implements InventoryConnectivityGateway {
  const _DesktopInventoryConnectivityAdapter();

  @override
  Future<bool> hasInternet() async => true;
}

class _DesktopStockMovementAdapter implements StockMovementGateway {
  const _DesktopStockMovementAdapter(this.repository);

  final AlmacenRepository repository;

  @override
  Future<StockMovementResult> register(
    RegisterStockMovementCommand command,
  ) async {
    final Map<String, dynamic> raw;
    if (command.isWaste) {
      raw = await InventarioService.registrarMerma(
        requestId: command.requestId,
        productoId: command.productId,
        almacenId: command.sourceWarehouseId,
        cantidad: command.quantity,
        motivo: command.reason,
        serialNumbers: command.serialNumbers,
      );
    } else {
      final destination = command.destinationWarehouseId;
      if (destination == null) {
        throw ArgumentError('El almacén de destino es obligatorio.');
      }
      raw = await InventarioService.trasladarStock(
        requestId: command.requestId,
        productoId: command.productId,
        origenId: command.sourceWarehouseId,
        destinoId: destination,
        cantidad: command.quantity,
        motivo: command.reason,
        serialNumbers: command.serialNumbers,
      );
    }
    await repository.sincronizarProductoLocal(command.productId);
    repository.sincronizarConSupabase();
    final rawId = raw['transferencia_id'];
    return StockMovementResult(
      transferId: rawId is num ? rawId.toInt() : int.tryParse('$rawId'),
      isTransfer: !command.isWaste,
    );
  }
}

class _DesktopMerchandiseEntryWriter implements MerchandiseEntryWriter {
  const _DesktopMerchandiseEntryWriter();

  @override
  Future<void> register(MerchandiseEntryCommand command) {
    return InventarioService.registrarIngresoMercaderia(
      requestId: command.requestId,
      productoId: command.productId,
      fecha: command.date,
      tipoIngreso: command.entryType,
      documento: command.document,
      proveedorId: command.supplierId,
      observaciones: command.observations,
      almacenes: command.warehouses
          .map(
            (row) => <String, dynamic>{
              'almacen_id': row.warehouseId,
              'cantidad_base': row.baseQuantity,
            },
          )
          .toList(growable: false),
      ingresoCosto: command.cost,
      ingresoPUnit: command.unitPrice,
      ingresoPCaja: command.boxPrice,
      ingresoPCComp: command.comparativeBoxPrice,
    );
  }
}

class _DesktopProductSyncAdapter implements InventoryProductSyncGateway {
  const _DesktopProductSyncAdapter(this.repository);

  final AlmacenRepository repository;

  @override
  Future<void> synchronizeProduct(int productId) =>
      repository.sincronizarProductoLocal(productId, propagarError: true);

  @override
  void synchronizeCatalogInBackground() {
    repository.sincronizarConSupabase();
  }
}

final desktopInventoryCatalogUseCaseProvider =
    Provider<InventoryCatalogUseCase>(
      (ref) => InventoryCatalogUseCase(
        gateway: _DesktopInventoryCatalogAdapter(
          ref.read(almacenRepositoryProvider),
        ),
        connectivity: const _DesktopInventoryConnectivityAdapter(),
      ),
    );

final desktopRegisterStockMovementUseCaseProvider =
    Provider<RegisterStockMovementUseCase>((ref) {
      return RegisterStockMovementUseCase(
        _DesktopStockMovementAdapter(ref.read(almacenRepositoryProvider)),
        authorizer: ref.read(operationAuthorizerProvider),
      );
    });

final desktopRegisterMerchandiseEntryUseCaseProvider =
    Provider<RegisterMerchandiseEntryUseCase>((ref) {
      final repository = ref.read(almacenRepositoryProvider);
      return RegisterMerchandiseEntryUseCase(
        writer: const _DesktopMerchandiseEntryWriter(),
        sync: _DesktopProductSyncAdapter(repository),
        authorizer: ref.read(operationAuthorizerProvider),
      );
    });

final desktopInventorySnapshotProvider =
    FutureProvider.autoDispose<InventoryCatalogSnapshot>((ref) {
      return ref.watch(desktopInventoryCatalogUseCaseProvider).loadInitial();
    });

final desktopInventoryProvider = FutureProvider.autoDispose
    .family<List<DesktopInventoryItem>, String>((ref, query) async {
      final snapshot = await ref.watch(desktopInventorySnapshotProvider.future);
      final filtered = ref
          .watch(desktopInventoryCatalogUseCaseProvider)
          .filterAndSort(products: snapshot.products, query: query.trim());
      return filtered.map(DesktopInventoryItem.new).toList(growable: false);
    });
