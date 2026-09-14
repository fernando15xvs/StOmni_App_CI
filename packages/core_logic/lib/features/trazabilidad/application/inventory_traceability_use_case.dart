import '../../../auth/application/operation_authorizer.dart';
import '../../../auth/domain/app_permission.dart';
import '../../../business/application/business_profile_gateway.dart';
import '../../../errors/user_facing_exception.dart';
import '../domain/inventory_traceability.dart';

abstract interface class InventoryTraceabilityGateway {
  Future<ProductTraceabilityConfig> loadConfig(int productId);
  Future<ProductTraceabilityConfig> saveConfig({
    required int productId,
    required int expectedRevision,
    required ProductTraceabilityMode mode,
    required bool expiryRequired,
  });
  Future<List<LotStockRecord>> listLots({int? productId, int? warehouseId});
  Future<List<SerialStockRecord>> listSerials({int? productId, int? warehouseId});
  Future<void> registerReceipt(TraceableReceiptCommand command);
}

class InventoryTraceabilityUseCase {
  const InventoryTraceabilityUseCase({
    required InventoryTraceabilityGateway gateway,
    required BusinessProfileGateway businessProfile,
    required OperationAuthorizer authorizer,
  }) : _gateway = gateway,
       _businessProfile = businessProfile,
       _authorizer = authorizer;

  final InventoryTraceabilityGateway _gateway;
  final BusinessProfileGateway _businessProfile;
  final OperationAuthorizer _authorizer;

  /// La configuración puede prepararse antes de activar la capacidad del
  /// negocio. La activación sólo controla operaciones que mueven stock.
  Future<ProductTraceabilityConfig> loadConfig(int productId) async {
    if (productId <= 0) throw ArgumentError('Producto inválido.');
    await _authorizer.require({AppPermission.productsUpdate});
    return _gateway.loadConfig(productId);
  }

  Future<ProductTraceabilityConfig> saveConfig({
    required int productId,
    required int expectedRevision,
    required ProductTraceabilityMode mode,
    required bool expiryRequired,
  }) async {
    if (productId <= 0 || expectedRevision < 0) {
      throw ArgumentError('Producto o revisión inválidos.');
    }
    if (mode != ProductTraceabilityMode.lot && expiryRequired) {
      throw ArgumentError('El vencimiento sólo puede exigirse con seguimiento por lote.');
    }
    final user = await _authorizer.require({AppPermission.productsUpdate});
    final result = await _gateway.saveConfig(
      productId: productId,
      expectedRevision: expectedRevision,
      mode: mode,
      expiryRequired: expiryRequired,
    );
    _checkSession(user);
    return result;
  }

  Future<List<LotStockRecord>> listLots({int? productId, int? warehouseId}) async {
    await _requireOperationalCapability();
    return _gateway.listLots(productId: productId, warehouseId: warehouseId);
  }

  Future<List<SerialStockRecord>> listSerials({int? productId, int? warehouseId}) async {
    await _requireOperationalCapability();
    return _gateway.listSerials(productId: productId, warehouseId: warehouseId);
  }

  Future<void> registerReceipt(TraceableReceiptCommand command) async {
    if (command.requestId.trim().isEmpty || command.productId <= 0 ||
        command.warehouseId <= 0 || !command.totalBaseQuantity.isFinite ||
        command.totalBaseQuantity <= 0) {
      throw ArgumentError('Recepción trazable inválida.');
    }
    final profile = await _businessProfile.load();
    final config = await _gateway.loadConfig(command.productId);
    switch (config.mode) {
      case ProductTraceabilityMode.none:
        throw const UserFacingException('El producto no usa trazabilidad.');
      case ProductTraceabilityMode.lot:
        if (!profile.capabilities.lotTracking) {
          throw const UserFacingException('El seguimiento por lote no está habilitado.');
        }
        if (config.expiryRequired && !profile.capabilities.expiryTracking) {
          throw const UserFacingException('El seguimiento de vencimientos no está habilitado.');
        }
        _validateLots(command, config);
        break;
      case ProductTraceabilityMode.serial:
        if (!profile.capabilities.serialNumberTracking) {
          throw const UserFacingException('El seguimiento por serie no está habilitado.');
        }
        _validateSerials(command);
        break;
    }
    final user = await _authorizer.require({AppPermission.inventoryReceive});
    await _gateway.registerReceipt(command);
    _checkSession(user);
  }

  Future<String> _requireOperationalCapability() async {
    final profile = await _businessProfile.load();
    if (!profile.capabilities.lotTracking &&
        !profile.capabilities.serialNumberTracking &&
        !profile.capabilities.expiryTracking) {
      throw const UserFacingException(
        'La trazabilidad aún no está habilitada para este negocio.',
      );
    }
    return _authorizer.require({AppPermission.inventoryReceive});
  }

  void _validateLots(
    TraceableReceiptCommand command,
    ProductTraceabilityConfig config,
  ) {
    if (command.lots.isEmpty || command.serials.isNotEmpty) {
      throw ArgumentError('La recepción por lote requiere distribuciones de lote.');
    }
    final seen = <String>{};
    var sum = 0.0;
    for (final lot in command.lots) {
      final code = lot.lotCode.trim();
      if (code.isEmpty || !seen.add(code.toLowerCase()) ||
          !lot.baseQuantity.isFinite || lot.baseQuantity <= 0) {
        throw ArgumentError('La recepción contiene un lote inválido o repetido.');
      }
      if (config.expiryRequired && lot.expiryDate == null) {
        throw ArgumentError('Todos los lotes requieren fecha de vencimiento.');
      }
      sum += lot.baseQuantity;
    }
    if ((sum - command.totalBaseQuantity).abs() > 0.000001) {
      throw ArgumentError('La suma de lotes no coincide con la cantidad recibida.');
    }
  }

  void _validateSerials(TraceableReceiptCommand command) {
    if (command.serials.isEmpty || command.lots.isNotEmpty ||
        command.totalBaseQuantity != command.totalBaseQuantity.roundToDouble() ||
        command.serials.length != command.totalBaseQuantity.round()) {
      throw ArgumentError('La recepción seriada requiere una serie por unidad.');
    }
    final seen = <String>{};
    for (final serial in command.serials) {
      final value = serial.serialNumber.trim();
      if (value.isEmpty || !seen.add(value.toLowerCase())) {
        throw ArgumentError('La recepción contiene una serie inválida o repetida.');
      }
    }
  }

  void _checkSession(String user) {
    if (_authorizer.currentAuthUserId != user) {
      throw const UserFacingException('La sesión cambió durante la operación.');
    }
  }
}
