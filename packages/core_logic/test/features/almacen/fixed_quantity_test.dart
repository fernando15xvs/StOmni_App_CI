import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'FixedQuantity conserva precisión decimal sin comparar doubles libres',
    () {
      final value = FixedQuantity.fromDouble(1.25, scale: 2);
      expect(value.minorUnits, 125);
      expect(value.value, 1.25);
      expect(value.format(), '1.25');
      expect(value.add(FixedQuantity.fromDouble(0.75, scale: 2)).format(), '2');
    },
  );

  test('FixedQuantity rechaza más decimales que los declarados', () {
    expect(
      () => FixedQuantity.fromDouble(1.251, scale: 2),
      throwsArgumentError,
    );
  });

  test('perfil decimal valida kg y saco sin introducir enums por sector', () {
    final kg = CommercialPresentation.base(
      code: 'kg',
      singularLabel: 'kg',
      pluralLabel: 'kg',
      quantityPrecision: 3,
    );
    final profile = ProductUnitProfile(
      baseUnit: kg,
      presentations: [
        kg,
        CommercialPresentation(
          code: 'saco_25',
          singularLabel: 'Saco',
          pluralLabel: 'Sacos',
          baseQuantity: 25,
        ),
      ],
    );

    PresentationPolicy.validate(profile);
    expect(PresentationPolicy.baseQuantity(profile, 'kg', 1.375), 1.375);
    expect(PresentationPolicy.baseQuantity(profile, 'saco_25', 2), 50);
    expect(
      () => PresentationPolicy.baseQuantity(profile, 'kg', 1.3755),
      throwsArgumentError,
    );
    expect(
      () => IntegerPresentationPolicy.validate(profile),
      throwsArgumentError,
    );
  });

  test(
    'configuración convierte cantidad visible a unidades menores y vuelve',
    () {
      final kg = CommercialPresentation.base(
        code: 'kg',
        singularLabel: 'kg',
        pluralLabel: 'kg',
        quantityPrecision: 3,
      );
      final configuration = ProductUnitConfiguration(
        revision: 4,
        profile: ProductUnitProfile(
          baseUnit: kg,
          presentations: [
            kg,
            CommercialPresentation(
              code: 'saco_25',
              singularLabel: 'Saco',
              pluralLabel: 'Sacos',
              baseQuantity: 25,
              quantityPrecision: 1,
            ),
          ],
        ),
      );

      expect(configuration.storageScale, 1000);
      expect(configuration.toStoredBaseQuantity(10.5), 10500);
      expect(configuration.fromStoredBaseQuantity(10500), 10.5);
      expect(configuration.storedQuantityFor('saco_25', 1.5), 37500);
      expect(
        () => configuration.toStoredBaseQuantity(0.0005),
        throwsArgumentError,
      );
    },
  );

  test('codec v2 conserva precisión y sigue decodificando perfiles v1', () {
    final kg = CommercialPresentation.base(
      code: 'kg',
      singularLabel: 'kg',
      pluralLabel: 'kg',
      quantityPrecision: 3,
    );
    final decimal = ProductUnitProfile(baseUnit: kg, presentations: [kg]);
    final encoded = ProductUnitConfigurationMapper.encodeProfile(decimal);
    expect(encoded['schema_version'], 2);
    final restored = ProductUnitConfigurationMapper.decodeProfile(encoded);
    expect(restored.baseUnit.quantityPrecision, 3);

    final legacy = ProductUnitConfigurationMapper.decodeProfile({
      'schema_version': 1,
      'base_code': 'unidad',
      'presentations': [
        {
          'code': 'unidad',
          'singular': 'Unidad',
          'plural': 'Unidades',
          'factor': 1,
          'fractional': false,
        },
      ],
    });
    expect(legacy.baseUnit.quantityPrecision, 0);
    expect(() => IntegerPresentationPolicy.validate(legacy), returnsNormally);
  });
}
