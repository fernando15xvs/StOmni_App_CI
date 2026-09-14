import 'package:core_logic/auth/application/operation_authorizer.dart';
import 'package:core_logic/auth/domain/app_permission.dart';
import 'package:core_logic/business/application/business_profile_gateway.dart';
import 'package:core_logic/business/domain/business_profile.dart';
import 'package:core_logic/features/compras/application/purchase_order_use_case.dart';
import 'package:core_logic/features/compras/domain/purchase_order.dart';
import 'package:flutter_test/flutter_test.dart';

class _Gateway implements PurchaseOrderGateway {
  PurchaseOrderRecord? record;
  int createCalls = 0;
  int receiveCalls = 0;

  @override
  Future<List<PurchaseOrderRecord>> list({PurchaseOrderStatus? status, int limit = 100}) async =>
      record == null ? const [] : [record!];

  @override
  Future<PurchaseOrderRecord> create(PurchaseOrderDraft draft) async {
    createCalls++;
    return record!;
  }

  @override
  Future<PurchaseOrderRecord> receive(ReceivePurchaseOrderCommand command) async {
    receiveCalls++;
    return record!;
  }

  @override
  Future<PurchaseOrderRecord> cancel(int purchaseOrderId, {required String reason}) async => record!;
}

class _Business implements BusinessProfileGateway {
  _Business({this.enabled = true});
  bool enabled;

  @override
  Future<BusinessProfile> load({bool allowOffline = false}) async => BusinessProfile(
        businessId: '1',
        displayName: 'StOmni',
        capabilities: BusinessCapabilities(purchaseManagement: enabled),
        revision: 1,
        supportsCapabilitySettings: true,
      );

  @override
  Future<BusinessProfile> updateCapabilities({
    required String businessId,
    required int expectedRevision,
    required BusinessCapabilities capabilities,
  }) async => throw UnimplementedError();
}

class _Authorizer implements OperationAuthorizer {
  Set<AppPermission> lastRequired = const {};
  @override
  String? currentAuthUserId = 'u1';

  @override
  Future<String> require(Set<AppPermission> permissions, {bool allowOffline = false}) async {
    lastRequired = permissions;
    return currentAuthUserId!;
  }
}

PurchaseOrderRecord _record() => PurchaseOrderRecord(
      id: 1,
      requestId: 'r1',
      supplierId: 2,
      supplierName: 'Proveedor',
      warehouseId: 3,
      warehouseName: 'Principal',
      status: PurchaseOrderStatus.ordered,
      orderedAt: DateTime(2026, 9, 5),
      expectedAt: null,
      notes: '',
      lines: const [
        PurchaseOrderLine(
          id: 10,
          productId: 20,
          productName: 'Producto',
          orderedBaseQuantity: 2.5,
          receivedBaseQuantity: 0,
          unitCost: 4,
        ),
      ],
    );

void main() {
  test('crear exige capacidad y purchases.manage', () async {
    final gateway = _Gateway()..record = _record();
    final authorizer = _Authorizer();
    final useCase = PurchaseOrderUseCase(
      gateway: gateway,
      businessProfile: _Business(),
      authorizer: authorizer,
    );

    await useCase.create(PurchaseOrderDraft(
      requestId: 'r1',
      supplierId: 2,
      warehouseId: 3,
      orderedAt: DateTime(2026, 9, 5),
      lines: const [
        PurchaseOrderLineDraft(productId: 20, baseQuantity: 2.5, unitCost: 4),
      ],
    ));

    expect(gateway.createCalls, 1);
    expect(authorizer.lastRequired, {AppPermission.purchasesManage});
  });

  test('recepción exige compras e ingreso de inventario', () async {
    final gateway = _Gateway()..record = _record();
    final authorizer = _Authorizer();
    final useCase = PurchaseOrderUseCase(
      gateway: gateway,
      businessProfile: _Business(),
      authorizer: authorizer,
    );

    await useCase.receive(ReceivePurchaseOrderCommand(
      requestId: 'receipt-1',
      purchaseOrderId: 1,
      receivedAt: DateTime(2026, 9, 5),
      lines: [
        PurchaseReceiptLine(purchaseOrderLineId: 10, baseQuantity: 1.25),
      ],
    ));

    expect(gateway.receiveCalls, 1);
    expect(authorizer.lastRequired, {
      AppPermission.purchasesManage,
      AppPermission.inventoryReceive,
    });
  });

  test('capacidad apagada bloquea antes del gateway', () async {
    final gateway = _Gateway()..record = _record();
    final useCase = PurchaseOrderUseCase(
      gateway: gateway,
      businessProfile: _Business(enabled: false),
      authorizer: _Authorizer(),
    );

    await expectLater(
      useCase.list(),
      throwsA(isA<Exception>()),
    );
  });

  test('rechaza productos duplicados en la misma orden', () async {
    final useCase = PurchaseOrderUseCase(
      gateway: _Gateway()..record = _record(),
      businessProfile: _Business(),
      authorizer: _Authorizer(),
    );
    await expectLater(
      useCase.create(PurchaseOrderDraft(
        requestId: 'r2',
        supplierId: 2,
        warehouseId: 3,
        orderedAt: DateTime(2026, 9, 5),
        lines: const [
          PurchaseOrderLineDraft(productId: 20, baseQuantity: 1, unitCost: 4),
          PurchaseOrderLineDraft(productId: 20, baseQuantity: 2, unitCost: 4),
        ],
      )),
      throwsArgumentError,
    );
  });
}
