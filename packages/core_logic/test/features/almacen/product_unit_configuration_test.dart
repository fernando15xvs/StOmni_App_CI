import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/test_operation_policy.dart';

void main() {
  ProductUnitProfile profile() {
    final bottle = CommercialPresentation.base(
      code: 'botella',
      singularLabel: 'Botella',
      pluralLabel: 'Botellas',
    );
    return ProductUnitProfile(
      baseUnit: bottle,
      presentations: [
        bottle,
        CommercialPresentation(
          code: 'pack_6',
          singularLabel: 'Pack',
          pluralLabel: 'Packs',
          baseQuantity: 6,
        ),
        CommercialPresentation(
          code: 'caja_24',
          singularLabel: 'Caja',
          pluralLabel: 'Cajas',
          baseQuantity: 24,
        ),
      ],
    );
  }

  test('convierte presentaciones enteras sin depender del rubro', () {
    final value = profile();
    expect(IntegerPresentationPolicy.baseQuantity(value, 'caja_24', 2), 48);
    expect(value.formatBaseQuantity(30), '1 Caja y 1 Pack');
    expect(
      () => IntegerPresentationPolicy.baseQuantity(
        value,
        'caja_24',
        IntegerPresentationPolicy.maxQuantity.toDouble(),
      ),
      throwsArgumentError,
    );
  });

  test('rechaza perfiles fraccionarios hasta migrar todo el inventario', () {
    final kg = CommercialPresentation.base(
      code: 'kg',
      singularLabel: 'kg',
      pluralLabel: 'kg',
      allowsFractionalSale: true,
    );
    final value = ProductUnitProfile(baseUnit: kg, presentations: [kg]);
    expect(
      () => IntegerPresentationPolicy.validate(value),
      throwsArgumentError,
    );
  });

  test('rechaza etiquetas con caracteres de control', () {
    final base = CommercialPresentation.base(
      code: 'unidad',
      singularLabel: 'Unidad\ninyectada',
      pluralLabel: 'Unidades',
    );
    final value = ProductUnitProfile(baseUnit: base, presentations: [base]);

    expect(
      () => IntegerPresentationPolicy.validate(value),
      throwsArgumentError,
    );
  });

  test('codec conserva revisión, etiquetas y equivalencias', () {
    final original = ProductUnitConfiguration(revision: 7, profile: profile());
    final decoded = ProductUnitConfigurationMapper.decodeNullable(
      ProductUnitConfigurationMapper.encode(original),
    )!;
    expect(decoded.revision, 7);
    expect(decoded.profile.find('pack_6')!.baseQuantity, 6);
    expect(decoded.profile.find('caja_24')!.pluralLabel, 'Cajas');
    expect(
      () => decoded.profile.presentations.add(decoded.profile.baseUnit),
      throwsUnsupportedError,
    );
  });

  test('precios y línea persistible usan el perfil versionado', () {
    final configuration = ProductUnitConfiguration(
      revision: 3,
      profile: profile(),
    );
    final product = SaleProductSnapshot(
      name: 'Agua',
      saleType: SaleUnitType.cajaUnidades,
      unitsPerPackage: 24,
      defaultUnitPrice: 2,
      defaultPackageBasePrice: 2,
      unitConfiguration: configuration,
    );
    final priced = const PriceSaleLineUseCase().execute(
      SaleCartLine(
        productId: 5,
        warehouseId: 2,
        product: product,
        quantity: 2,
        commercialUnit: 'pack_6',
        subtotal: 0,
      ),
      commercialUnitPrice: 11,
    );
    expect(priced.recordedBaseQuantity, 12);
    expect(priced.baseUnitPrice, closeTo(11 / 6, 0.000001));
    final persisted = LegacySaleLineMapper.map(priced);
    expect(persisted.baseQuantity, 12);
    expect(persisted.presentationRevision, 3);
    expect(persisted.commercialUnitLabel, 'Pack');
    expect(persisted.unitCode, 'pack_6');
  });

  test(
    'snapshot de carrito conserva la configuración para la cola offline',
    () {
      final configuration = ProductUnitConfiguration(
        revision: 2,
        profile: profile(),
      );
      final cart = SaleCart([
        SaleCartLine(
          productId: 8,
          warehouseId: 1,
          quantity: 1,
          commercialUnit: 'caja_24',
          subtotal: 40,
          product: SaleProductSnapshot(
            name: 'Agua',
            unitConfiguration: configuration,
          ),
        ),
      ]);
      final restored = SaleCartMapper.decode(SaleCartMapper.encode(cart));
      expect(restored.lines.single.product.unitConfiguration!.revision, 2);
      expect(restored.lines.single.commercialUnit, 'caja_24');
    },
  );

  test('codec de producto mantiene configuración e inventario inmutables', () {
    final original = Producto(
      id: 9,
      nombre: 'Agua',
      precioUnidad: 2,
      precioCompra: 1,
      permitirSinStock: false,
      inventario: const [InventarioAlmacen(almacenId: 3, cantidad: 30)],
      unitConfiguration: ProductUnitConfiguration(
        revision: 5,
        profile: profile(),
      ),
    );

    final restored = ProductoMapper.decode(ProductoMapper.encode(original));

    expect(restored.unitConfiguration!.revision, 5);
    expect(
      restored.unitConfiguration!.profile.find('caja_24')!.baseQuantity,
      24,
    );
    expect(restored.inventario.single.cantidad, 30);
    expect(
      () => restored.inventario.add(
        const InventarioAlmacen(almacenId: 4, cantidad: 1),
      ),
      throwsUnsupportedError,
    );
  });

  test(
    'guardado exige permiso y revisión, y bloquea cambiar la base',
    () async {
      final gateway = _Gateway(
        ProductUnitConfiguration(revision: 2, profile: profile()),
      );
      final current = ProductUnitSettings(
        supported: true,
        configuration: gateway.value,
      );
      final denied = SaveProductUnitConfigurationUseCase(
        gateway: gateway,
        authorizer: TestOperationAuthorizer(role: 'operador'),
      );
      await expectLater(
        denied.execute(productId: 1, current: current, profile: profile()),
        throwsA(isA<UserFacingException>()),
      );
      expect(gateway.writes, 0);

      final changedBase = CommercialPresentation.base(
        code: 'unidad',
        singularLabel: 'Unidad',
        pluralLabel: 'Unidades',
      );
      final useCase = SaveProductUnitConfigurationUseCase(
        gateway: gateway,
        authorizer: TestOperationAuthorizer(),
      );
      await expectLater(
        useCase.execute(
          productId: 1,
          current: current,
          profile: ProductUnitProfile(
            baseUnit: changedBase,
            presentations: [changedBase],
          ),
        ),
        throwsA(isA<UserFacingException>()),
      );
      expect(gateway.writes, 0);
    },
  );
}

class _Gateway implements ProductUnitConfigurationGateway {
  _Gateway(this.value);
  ProductUnitConfiguration value;
  int writes = 0;
  @override
  Future<ProductUnitSettings> load(int productId) async =>
      ProductUnitSettings(supported: true, configuration: value);
  @override
  Future<ProductUnitConfiguration> save({
    required int productId,
    required int expectedRevision,
    required ProductUnitProfile profile,
  }) async {
    if (expectedRevision != value.revision)
      throw StateError('Revisión obsoleta');
    writes++;
    return value = ProductUnitConfiguration(
      revision: expectedRevision + 1,
      profile: profile,
    );
  }
}
