import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ProductUnitProfile profile() {
    final unit = CommercialPresentation.base(
      code: 'unidad',
      singularLabel: 'Unidad',
      pluralLabel: 'Unidades',
    );
    return ProductUnitProfile(
      baseUnit: unit,
      presentations: [
        unit,
        CommercialPresentation(
          code: 'caja_12',
          singularLabel: 'Caja',
          pluralLabel: 'Cajas',
          baseQuantity: 12,
        ),
      ],
    );
  }

  test('capabilities restringe presentaciones sin conocer categorías', () {
    final capabilities = ProductCapabilities(
      allowedPresentationCodes: const ['unidad'],
    );

    expect(capabilities.supportsPresentation('unidad'), isTrue);
    expect(capabilities.supportsPresentation('caja_12'), isFalse);
    expect(capabilities.allowedPresentations(profile()), hasLength(1));
    expect(capabilities.isCompatibleWith(profile()), isTrue);
  });

  test('policy prioriza producto sobre categoría y defaults', () {
    final defaults = ProductCapabilities(tracksInventory: true);
    final category = ProductCapabilities(tracksLots: true);
    final product = ProductCapabilities(tracksSerialNumbers: true);
    final policy = ProductCapabilityPolicy(
      defaults: defaults,
      categoryOverrides: {'Alimentos Frescos': category},
      productOverrides: {99: product},
    );

    expect(
      policy.resolve(productId: 1, category: ' alimentos   frescos '),
      same(category),
    );
    expect(
      policy.resolve(productId: 99, category: 'Alimentos Frescos'),
      same(product),
    );
    expect(policy.resolve(productId: 2, category: 'otra'), same(defaults));
  });

  test('perfil legacy conserva las presentaciones existentes', () {
    final capabilities = ProductCapabilities.legacy(
      commercialProfile: profile(),
      allowSaleWithoutStock: true,
    );

    expect(capabilities.allowSaleWithoutStock, isTrue);
    expect(capabilities.supportsPresentation('unidad'), isTrue);
    expect(capabilities.supportsPresentation('caja_12'), isTrue);
  });
}
