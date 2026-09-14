import '../../../auth/application/operation_authorizer.dart';
import '../../../auth/domain/app_permission.dart';

class MerchandiseWarehouseAllocation {
  const MerchandiseWarehouseAllocation({
    required this.warehouseId,
    required this.baseQuantity,
  });

  final int warehouseId;
  final double baseQuantity;
}

abstract interface class MerchandiseEntryWriter {
  Future<void> register(MerchandiseEntryCommand command);
}

abstract interface class InventoryProductSyncGateway {
  Future<void> synchronizeProduct(int productId);
  void synchronizeCatalogInBackground();
}

class MerchandiseEntryCommand {
  final String requestId;
  final int productId;
  final DateTime date;
  final String entryType;
  final String document;
  final int? supplierId;
  final String observations;
  final List<MerchandiseWarehouseAllocation> warehouses;
  final double cost;
  final double unitPrice;
  final double boxPrice;
  final double comparativeBoxPrice;

  const MerchandiseEntryCommand({
    required this.requestId,
    required this.productId,
    required this.date,
    required this.entryType,
    required this.document,
    required this.supplierId,
    required this.observations,
    required this.warehouses,
    required this.cost,
    required this.unitPrice,
    required this.boxPrice,
    required this.comparativeBoxPrice,
  });
}

class RegisterMerchandiseEntryUseCase {
  final MerchandiseEntryWriter _writer;
  final InventoryProductSyncGateway _sync;
  final OperationAuthorizer _authorizer;

  const RegisterMerchandiseEntryUseCase({
    required MerchandiseEntryWriter writer,
    required InventoryProductSyncGateway sync,
    required OperationAuthorizer authorizer,
  }) : _writer = writer,
       _sync = sync,
       _authorizer = authorizer;

  Future<void> call(MerchandiseEntryCommand command) async {
    if (command.warehouses.isEmpty ||
        command.warehouses.any(
          (allocation) =>
              !allocation.baseQuantity.isFinite || allocation.baseQuantity <= 0,
        )) {
      throw ArgumentError('La distribución de mercadería contiene cantidades inválidas.');
    }
    final normalizedType = command.entryType.trim().toLowerCase();
    await _authorizer.require({
      normalizedType.contains('ajuste')
          ? AppPermission.inventoryAdjust
          : AppPermission.inventoryReceive,
    });
    await _writer.register(command);
    await _sync.synchronizeProduct(command.productId);
    _sync.synchronizeCatalogInBackground();
  }
}
