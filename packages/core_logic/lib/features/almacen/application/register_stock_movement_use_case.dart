import '../../../auth/application/operation_authorizer.dart';
import '../../../auth/domain/app_permission.dart';

class RegisterStockMovementCommand {
  const RegisterStockMovementCommand({
    required this.requestId,
    required this.productId,
    required this.quantity,
    required this.sourceWarehouseId,
    required this.destinationWarehouseId,
    required this.isWaste,
    required this.reason,
    this.serialNumbers = const <String>[],
  });

  final String requestId;
  final int productId;
  final double quantity;
  final int sourceWarehouseId;
  final int? destinationWarehouseId;
  final bool isWaste;
  final String reason;
  final List<String> serialNumbers;
}

class StockMovementResult {
  const StockMovementResult({
    required this.transferId,
    required this.isTransfer,
  });

  final int? transferId;
  final bool isTransfer;

  int? get transferenciaId => transferId;
  bool get esTraslado => isTransfer;
}

abstract interface class StockMovementGateway {
  Future<StockMovementResult> register(RegisterStockMovementCommand command);
}

class RegisterStockMovementUseCase {
  const RegisterStockMovementUseCase(
    this._gateway, {
    required OperationAuthorizer authorizer,
  }) : _authorizer = authorizer;

  final StockMovementGateway _gateway;
  final OperationAuthorizer _authorizer;

  Future<StockMovementResult> call(RegisterStockMovementCommand command) async {
    final quantity = command.quantity;
    if (!quantity.isFinite || quantity <= 0) {
      throw ArgumentError('La cantidad del movimiento debe ser positiva.');
    }
    if (!command.isWaste &&
        (command.destinationWarehouseId == null ||
            command.destinationWarehouseId == command.sourceWarehouseId)) {
      throw ArgumentError(
        'El traslado requiere un almacén de destino diferente.',
      );
    }
    if (command.isWaste && command.reason.trim().isEmpty) {
      throw ArgumentError('La merma requiere un motivo.');
    }
    final serials = command.serialNumbers.map((value) => value.trim()).toList();
    if (serials.any((value) => value.isEmpty) ||
        serials.toSet().length != serials.length) {
      throw ArgumentError('La selección de números de serie no es válida.');
    }
    await _authorizer.require({AppPermission.inventoryAdjust});
    return _gateway.register(command);
  }
}
