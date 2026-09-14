import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import '../../support/test_operation_policy.dart';

void main() {
  test('producto rechaza importes no finitos y equivalencias inválidas antes de efectos', () async {
    final data = _NoEffects();
    final useCase = SaveProductUseCase(inventory: data, productAdmin: data,
      uuid: const Uuid(), authorizer: TestOperationAuthorizer());
    for (final command in [_command(price: double.nan), _command(price: double.infinity), _command(pcs: 0)]) {
      await expectLater(useCase.execute(command), throwsA(isA<UserFacingException>()));
    }
    expect(data.effects, 0);
  });

  test('operador no crea productos aunque invoque directamente el caso de uso', () async {
    final data = _NoEffects();
    final useCase = SaveProductUseCase(inventory: data, productAdmin: data,
      uuid: const Uuid(), authorizer: TestOperationAuthorizer(role: 'operador'));
    await expectLater(useCase.execute(_command()), throwsA(isA<UserFacingException>()));
    expect(data.effects, 0);
  });
}

SaveProductCommand _command({double price = 10, int pcs = 1}) => SaveProductCommand(
  requestId: 'request-1', productId: null, code: 'P1', name: 'Producto',
  unitPrice: price, packageBasePrice: 0, purchasePrice: 0, unitsPerPackage: pcs,
  saleUnitType: SaleUnitType.unidad, minimumStock: 0, supplierId: null,
  allowWithoutStock: false, newImageBytes: null, existingImageUrl: null,
  warehouseIds: const [1], boxesByWarehouse: const {}, baseUnitsByWarehouse: const {},
);

class _NoEffects implements ProductInventoryWriteGateway, ProductAdminGateway {
  int effects = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    effects++;
    throw StateError('No debe acceder a datos antes de validar/autorización.');
  }
}
