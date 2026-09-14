import 'package:mobile_app/platform/connectivity/connectivity_status_service.dart';
import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

int _requiredRecordId(Map<String, dynamic> record, {required String source}) {
  final raw = record['id'];
  if (raw is num) return raw.toInt();
  final parsed = int.tryParse(raw?.toString() ?? '');
  if (parsed != null) return parsed;
  throw StateError('$source contiene un registro sin id válido.');
}

String _requiredRecordName(Map<String, dynamic> record, {required String source}) {
  final name = record['nombre']?.toString().trim() ?? '';
  if (name.isEmpty) {
    throw StateError('$source contiene un registro sin nombre válido.');
  }
  return name;
}

String? _optionalRecordText(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

class _InventoryCatalogAdapter implements InventoryCatalogGateway {
  const _InventoryCatalogAdapter(this._repository);
  final AlmacenRepository _repository;

  @override
  Future<void> synchronize({bool propagateError = false}) =>
      _repository.sincronizarConSupabase(propagarError: propagateError);

  @override
  Future<List<Producto>> searchProducts(String query) =>
      _repository.buscarProductos(query);

  @override
  Future<Map<int, String>> loadBrands() => _repository.getMarcas();

  @override
  Future<List<InventoryWarehouseRecord>> loadWarehouses() async {
    final raw = await _repository.getalmacenes();
    return raw
        .map(
          (record) => InventoryWarehouseRecord(
            id: _requiredRecordId(record, source: 'almacenes'),
            name: _requiredRecordName(record, source: 'almacenes'),
            active: record['activo'] != false,
            address: _optionalRecordText(record['direccion']),
            ubigeo: _optionalRecordText(record['ubigeo']),
            department: _optionalRecordText(record['departamento']),
            province: _optionalRecordText(record['provincia']),
            district: _optionalRecordText(record['distrito']),
            localCode: _optionalRecordText(record['cod_local']) ?? '0000',
            reference: _optionalRecordText(record['referencia']),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<List<Producto>> loadInactiveProducts() async {
    final raw = await _repository.obtenerProductosInactivos();
    return raw.map(ProductoMapper.decode).toList(growable: false);
  }
}

class _InventoryConnectivityAdapter implements InventoryConnectivityGateway {
  const _InventoryConnectivityAdapter();
  @override
  Future<bool> hasInternet() => ConnectivityStatusService.hasInternet();
}

class _ProductSearchAdapter implements ProductSearchGateway {
  const _ProductSearchAdapter(this._repository);
  final AlmacenRepository _repository;

  @override
  Future<List<ProductoBusqueda>> search(
    String query, {
    bool includeInactive = false,
  }) => _repository.buscarProductosRapido(
    query,
    incluirInactivos: includeInactive,
  );
}

class _StockMovementAdapter implements StockMovementGateway {
  const _StockMovementAdapter(this._repository);
  final AlmacenRepository _repository;

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
    await _repository.sincronizarProductoLocal(command.productId);
    _repository.sincronizarConSupabase();
    final rawTransferId = raw['transferencia_id'];
    final transferId = rawTransferId is num
        ? rawTransferId.toInt()
        : int.tryParse(rawTransferId?.toString() ?? '');
    return StockMovementResult(
      transferId: transferId,
      isTransfer: !command.isWaste,
    );
  }
}

class _MerchandiseEntryWriterAdapter implements MerchandiseEntryWriter {
  const _MerchandiseEntryWriterAdapter();

  @override
  Future<void> register(MerchandiseEntryCommand command) async {
    await InventarioService.registrarIngresoMercaderia(
      requestId: command.requestId,
      productoId: command.productId,
      fecha: command.date,
      tipoIngreso: command.entryType,
      documento: command.document,
      proveedorId: command.supplierId,
      observaciones: command.observations,
      almacenes: command.warehouses
          .map(
            (allocation) => <String, dynamic>{
              'almacen_id': allocation.warehouseId,
              'cantidad_base': allocation.baseQuantity,
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

class _MerchandiseEntryCatalogAdapter
    implements MerchandiseEntryCatalogGateway {
  const _MerchandiseEntryCatalogAdapter(
    this._inventoryRepository,
    this._suppliersRepository,
  );

  final AlmacenRepository _inventoryRepository;
  final ProveedoresRepository _suppliersRepository;

  @override
  Future<MerchandiseEntryCatalog> load() async {
    final results = await Future.wait<dynamic>([
      _inventoryRepository.obtenerAlmacenesDirecto(),
      _suppliersRepository.obtenerProveedoresActivos(),
    ]);
    return MerchandiseEntryCatalog(
      warehouses: _warehouseOptions(results[0]),
      activeSuppliers: _supplierOptions(results[1]),
    );
  }

  static List<ProductWarehouseOption> _warehouseOptions(dynamic raw) {
    return _records(raw, source: 'almacenes')
        .map(
          (record) => ProductWarehouseOption(
            id: _requiredRecordId(record, source: 'almacenes'),
            name: _requiredRecordName(record, source: 'almacenes'),
          ),
        )
        .toList(growable: false);
  }

  static List<ProductSupplierOption> _supplierOptions(dynamic raw) {
    return _records(raw, source: 'proveedores activos')
        .map(
          (record) => ProductSupplierOption(
            id: _requiredRecordId(record, source: 'proveedores activos'),
            name: _requiredRecordName(record, source: 'proveedores activos'),
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
    return raw.map((item) {
      if (item is Map<String, dynamic>) return item;
      if (item is Map) return Map<String, dynamic>.from(item);
      throw StateError('$source contiene un registro inválido.');
    }).toList(growable: false);
  }
}

class _InventoryProductSyncAdapter implements InventoryProductSyncGateway {
  const _InventoryProductSyncAdapter(this._repository);
  final AlmacenRepository _repository;

  @override
  Future<void> synchronizeProduct(int productId) =>
      _repository.sincronizarProductoLocal(productId);

  @override
  void synchronizeCatalogInBackground() {
    _repository.sincronizarConSupabase();
  }
}

class _ProductLifecycleAdapter implements ProductLifecycleGateway {
  const _ProductLifecycleAdapter(this._repository);
  final AlmacenRepository _repository;

  @override
  Future<ProductDeletionEvaluation> evaluateDeletion(int productId) async {
    final raw = await _repository.evaluarEliminacionProducto(productId);
    final rawCount = raw['movimientos_apertura'];
    final count = rawCount is num
        ? rawCount.toInt()
        : int.tryParse(rawCount?.toString() ?? '') ?? 0;
    return ProductDeletionEvaluation(
      openingMovementCount: count,
      canUpdateOpening: raw['puede_actualizar_apertura'] == true,
    );
  }

  @override
  Future<void> deactivate(int productId) =>
      _repository.desactivarProducto(productId);

  @override
  Future<void> deletePermanently(int productId) async {
    await _repository.eliminarProductoDefinitivamente(productId);
  }

  @override
  Future<void> reactivate(int productId) =>
      _repository.reactivarProducto(productId);
}

class _WarehouseAdminAdapter implements WarehouseAdminGateway {
  const _WarehouseAdminAdapter(this._repository);
  final AlmacenAdminRepository _repository;

  @override
  Future<List<WarehouseAdminRecord>> listWarehouses() async {
    final raw = await _repository.listarAlmacenes();
    return raw
        .map(
          (record) => WarehouseAdminRecord(
            id: _requiredRecordId(record, source: 'almacenes administrables'),
            name: _requiredRecordName(record, source: 'almacenes administrables'),
            active: record['activo'] == true,
            address: _optionalRecordText(record['direccion']),
            ubigeo: _optionalRecordText(record['ubigeo']),
            department: _optionalRecordText(record['departamento']),
            province: _optionalRecordText(record['provincia']),
            district: _optionalRecordText(record['distrito']),
            localCode: _optionalRecordText(record['cod_local']) ?? '0000',
            reference: _optionalRecordText(record['referencia']),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> save({
    int? id,
    required String name,
    required String address,
    required String ubigeo,
    required String department,
    required String province,
    required String district,
    required String localCode,
    required String reference,
  }) => _repository.guardar(
    id: id,
    nombre: name,
    direccion: address,
    ubigeo: ubigeo,
    departamento: department,
    provincia: province,
    distrito: district,
    codLocal: localCode,
    referencia: reference,
  );

  @override
  Future<void> deactivate(int id) => _repository.desactivar(id);
  @override
  Future<void> reactivate(int id) => _repository.reactivar(id);
}

final inventoryCatalogUseCaseProvider = Provider<InventoryCatalogUseCase>((ref) {
  return InventoryCatalogUseCase(
    gateway: _InventoryCatalogAdapter(ref.read(almacenRepositoryProvider)),
    connectivity: const _InventoryConnectivityAdapter(),
  );
});

final searchProductsUseCaseProvider = Provider<SearchProductsUseCase>((ref) {
  return SearchProductsUseCase(
    _ProductSearchAdapter(ref.read(almacenRepositoryProvider)),
  );
});

final registerStockMovementUseCaseProvider =
    Provider<RegisterStockMovementUseCase>((ref) {
      return RegisterStockMovementUseCase(
        _StockMovementAdapter(ref.read(almacenRepositoryProvider)),
        authorizer: ref.read(operationAuthorizerProvider),
      );
    });

final registerMerchandiseEntryUseCaseProvider =
    Provider<RegisterMerchandiseEntryUseCase>((ref) {
      final repository = ref.read(almacenRepositoryProvider);
      return RegisterMerchandiseEntryUseCase(
        writer: const _MerchandiseEntryWriterAdapter(),
        sync: _InventoryProductSyncAdapter(repository),
        authorizer: ref.read(operationAuthorizerProvider),
      );
    });

final loadMerchandiseEntryCatalogUseCaseProvider =
    Provider<LoadMerchandiseEntryCatalogUseCase>((ref) {
      return LoadMerchandiseEntryCatalogUseCase(
        _MerchandiseEntryCatalogAdapter(
          ref.read(almacenRepositoryProvider),
          ref.read(proveedoresRepositoryProvider),
        ),
      );
    });

final productLifecycleUseCaseProvider = Provider<ProductLifecycleUseCase>((ref) {
  return ProductLifecycleUseCase(
    _ProductLifecycleAdapter(ref.read(almacenRepositoryProvider)),
  );
});

final warehouseAdminUseCaseProvider = Provider<WarehouseAdminUseCase>((ref) {
  return WarehouseAdminUseCase(
    _WarehouseAdminAdapter(ref.read(almacenAdminRepositoryProvider)),
  );
});
