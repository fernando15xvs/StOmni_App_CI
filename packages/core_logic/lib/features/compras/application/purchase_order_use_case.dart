import '../../../auth/application/operation_authorizer.dart';
import '../../../auth/domain/app_permission.dart';
import '../../../business/application/business_profile_gateway.dart';
import '../../../errors/user_facing_exception.dart';
import '../domain/purchase_order.dart';

abstract interface class PurchaseOrderGateway {
  Future<List<PurchaseOrderRecord>> list({
    PurchaseOrderStatus? status,
    int limit = 100,
  });
  Future<PurchaseOrderRecord> create(PurchaseOrderDraft draft);
  Future<PurchaseOrderRecord> receive(ReceivePurchaseOrderCommand command);
  Future<PurchaseOrderRecord> cancel(
    int purchaseOrderId, {
    required String reason,
  });
}

class PurchaseOrderUseCase {
  const PurchaseOrderUseCase({
    required PurchaseOrderGateway gateway,
    required BusinessProfileGateway businessProfile,
    required OperationAuthorizer authorizer,
  }) : _gateway = gateway,
       _businessProfile = businessProfile,
       _authorizer = authorizer;

  final PurchaseOrderGateway _gateway;
  final BusinessProfileGateway _businessProfile;
  final OperationAuthorizer _authorizer;

  Future<List<PurchaseOrderRecord>> list({
    PurchaseOrderStatus? status,
    int limit = 100,
  }) async {
    await _requireCapabilityAndPermission();
    return _gateway.list(status: status, limit: limit.clamp(1, 200));
  }

  Future<PurchaseOrderRecord> create(PurchaseOrderDraft draft) async {
    _validateDraft(draft);
    final user = await _requireCapabilityAndPermission();
    final result = await _gateway.create(draft);
    _checkSession(user);
    return result;
  }

  Future<PurchaseOrderRecord> receive(
    ReceivePurchaseOrderCommand command,
  ) async {
    if (command.requestId.trim().isEmpty || command.purchaseOrderId <= 0) {
      throw ArgumentError('La recepción no tiene una identificación válida.');
    }
    if (command.lines.isEmpty ||
        command.lines.any(
          (line) =>
              line.purchaseOrderLineId <= 0 ||
              !line.baseQuantity.isFinite ||
              line.baseQuantity <= 0,
        )) {
      throw ArgumentError('La recepción contiene cantidades inválidas.');
    }
    final ids = command.lines.map((line) => line.purchaseOrderLineId).toSet();
    if (ids.length != command.lines.length) {
      throw ArgumentError(
        'Una línea de compra no puede recibirse dos veces en la misma operación.',
      );
    }
    final user = await _requireCapabilityAndPermission(receiving: true);
    final result = await _gateway.receive(command);
    _checkSession(user);
    return result;
  }

  Future<PurchaseOrderRecord> cancel(
    int purchaseOrderId, {
    required String reason,
  }) async {
    if (purchaseOrderId <= 0 || reason.trim().isEmpty) {
      throw ArgumentError('Indica una orden y el motivo de anulación.');
    }
    final user = await _requireCapabilityAndPermission();
    final result = await _gateway.cancel(
      purchaseOrderId,
      reason: reason.trim(),
    );
    _checkSession(user);
    return result;
  }

  Future<String> _requireCapabilityAndPermission({
    bool receiving = false,
  }) async {
    final profile = await _businessProfile.load();
    if (!profile.capabilities.purchaseManagement) {
      throw const UserFacingException(
        'La gestión de compras no está habilitada para este negocio.',
      );
    }
    return _authorizer.require({
      AppPermission.purchasesManage,
      if (receiving) AppPermission.inventoryReceive,
    });
  }

  void _checkSession(String user) {
    if (_authorizer.currentAuthUserId != user) {
      throw const UserFacingException(
        'La sesión cambió durante la operación de compra.',
      );
    }
  }

  void _validateDraft(PurchaseOrderDraft draft) {
    if (draft.requestId.trim().isEmpty ||
        draft.supplierId <= 0 ||
        draft.warehouseId <= 0) {
      throw ArgumentError(
        'La orden de compra no tiene proveedor, almacén o identificador válido.',
      );
    }
    if (draft.expectedAt != null &&
        draft.expectedAt!.isBefore(draft.orderedAt)) {
      throw ArgumentError(
        'La fecha esperada no puede ser anterior a la fecha de la orden.',
      );
    }
    if (draft.lines.isEmpty) {
      throw ArgumentError('Agrega al menos un producto a la orden de compra.');
    }
    final products = <int>{};
    for (final line in draft.lines) {
      if (line.productId <= 0 ||
          !line.baseQuantity.isFinite ||
          line.baseQuantity <= 0 ||
          !line.unitCost.isFinite ||
          line.unitCost < 0) {
        throw ArgumentError('La orden contiene una línea inválida.');
      }
      if (!products.add(line.productId)) {
        throw ArgumentError(
          'Un producto no puede repetirse en la misma orden.',
        );
      }
    }
  }
}
