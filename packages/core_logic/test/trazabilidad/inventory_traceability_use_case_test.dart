import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lotes deben sumar exactamente la cantidad recibida', () async {
    final gateway = _TraceGateway(
      const ProductTraceabilityConfig(
        productId: 7,
        mode: ProductTraceabilityMode.lot,
        expiryRequired: true,
        revision: 1,
      ),
    );
    final useCase = InventoryTraceabilityUseCase(
      gateway: gateway,
      businessProfile: _BusinessProfiles(),
      authorizer: _Authorizer(),
    );

    await expectLater(
      useCase.registerReceipt(
        TraceableReceiptCommand(
          requestId: 'req-1',
          productId: 7,
          warehouseId: 1,
          totalBaseQuantity: 5,
          lots: [
            LotReceiptAllocation(
              lotCode: 'L-1',
              baseQuantity: 4,
              expiryDate: DateTime(2027, 1, 1),
            ),
          ],
        ),
      ),
      throwsArgumentError,
    );
    expect(gateway.registered, isFalse);
  });

  test('serie requiere una identificación única por unidad', () async {
    final gateway = _TraceGateway(
      const ProductTraceabilityConfig(
        productId: 9,
        mode: ProductTraceabilityMode.serial,
        expiryRequired: false,
        revision: 1,
      ),
    );
    final useCase = InventoryTraceabilityUseCase(
      gateway: gateway,
      businessProfile: _BusinessProfiles(),
      authorizer: _Authorizer(),
    );

    await expectLater(
      useCase.registerReceipt(
        const TraceableReceiptCommand(
          requestId: 'req-2',
          productId: 9,
          warehouseId: 1,
          totalBaseQuantity: 2,
          serials: [
            SerialReceiptAllocation('SN-1'),
            SerialReceiptAllocation('SN-1'),
          ],
        ),
      ),
      throwsArgumentError,
    );
    expect(gateway.registered, isFalse);
  });
}

class _TraceGateway implements InventoryTraceabilityGateway {
  _TraceGateway(this.config);
  ProductTraceabilityConfig config;
  bool registered = false;

  @override
  Future<ProductTraceabilityConfig> loadConfig(int productId) async => config;

  @override
  Future<ProductTraceabilityConfig> saveConfig({
    required int productId,
    required int expectedRevision,
    required ProductTraceabilityMode mode,
    required bool expiryRequired,
  }) async {
    config = ProductTraceabilityConfig(
      productId: productId,
      mode: mode,
      expiryRequired: expiryRequired,
      revision: expectedRevision + 1,
    );
    return config;
  }

  @override
  Future<List<LotStockRecord>> listLots({int? productId, int? warehouseId}) async => const [];

  @override
  Future<List<SerialStockRecord>> listSerials({int? productId, int? warehouseId}) async => const [];

  @override
  Future<void> registerReceipt(TraceableReceiptCommand command) async {
    registered = true;
  }
}

class _BusinessProfiles implements BusinessProfileGateway {
  @override
  Future<BusinessProfile> load({bool allowOffline = false}) async =>
      const BusinessProfile(
        businessId: '1',
        displayName: 'StOmni',
        capabilities: BusinessCapabilities(
          purchaseManagement: true,
          lotTracking: true,
          expiryTracking: true,
          variants: true,
          serialNumberTracking: true,
        ),
        revision: 1,
        supportsCapabilitySettings: true,
      );

  @override
  Future<BusinessProfile> updateCapabilities({
    required String businessId,
    required int expectedRevision,
    required BusinessCapabilities capabilities,
  }) async => BusinessProfile(
    businessId: businessId,
    displayName: 'StOmni',
    capabilities: capabilities,
    revision: expectedRevision + 1,
    supportsCapabilitySettings: true,
  );
}

class _Authorizer implements OperationAuthorizer {
  @override
  String? get currentAuthUserId => 'u1';

  @override
  Future<String> require(
    Set<AppPermission> permissions, {
    bool allowOffline = false,
  }) async => 'u1';
}
