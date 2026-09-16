import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProductUnitProfile', () {
    test('modela botella, pack y caja sin reglas específicas del sector', () {
      final bottle = CommercialPresentation.base(
        code: 'botella',
        singularLabel: 'Botella',
        pluralLabel: 'Botellas',
      );
      final profile = ProductUnitProfile(
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

      expect(
        profile.toBaseQuantity(presentationCode: 'pack_6', quantity: 3),
        18,
      );
      expect(
        profile.toBaseQuantity(presentationCode: 'caja_24', quantity: 2),
        48,
      );
      expect(profile.formatBaseQuantity(30), '1 Caja y 1 Pack');
    });

    test('modela peso fraccionario', () {
      final kg = CommercialPresentation.base(
        code: 'kg',
        singularLabel: 'kg',
        pluralLabel: 'kg',
        allowsFractionalSale: true,
      );
      final profile = ProductUnitProfile(
        baseUnit: kg,
        presentations: [
          kg,
          CommercialPresentation(
            code: 'saco_50',
            singularLabel: 'Saco',
            pluralLabel: 'Sacos',
            baseQuantity: 50,
          ),
        ],
      );

      expect(
        profile.toBaseQuantity(presentationCode: 'kg', quantity: 1.75),
        1.75,
      );
      expect(
        profile.toBaseQuantity(presentationCode: 'saco_50', quantity: 2),
        100,
      );
      expect(profile.formatBaseQuantity(1.75), '1.75 kg');
    });

    test('modela longitud y rollos', () {
      final meter = CommercialPresentation.base(
        code: 'metro',
        singularLabel: 'Metro',
        pluralLabel: 'Metros',
        allowsFractionalSale: true,
      );
      final profile = ProductUnitProfile(
        baseUnit: meter,
        presentations: [
          meter,
          CommercialPresentation(
            code: 'rollo_100',
            singularLabel: 'Rollo',
            pluralLabel: 'Rollos',
            baseQuantity: 100,
          ),
        ],
      );

      expect(
        profile.toBaseQuantity(presentationCode: 'metro', quantity: 2.5),
        2.5,
      );
      expect(
        profile.toBaseQuantity(presentationCode: 'rollo_100', quantity: 3),
        300,
      );
    });

    test('presentaciones discretas rechazan cantidades fraccionarias', () {
      final unit = CommercialPresentation.base(
        code: 'unidad',
        singularLabel: 'Unidad',
        pluralLabel: 'Unidades',
      );

      expect(() => unit.toBaseQuantity(1.5), throwsArgumentError);
    });

    test('rechaza códigos duplicados', () {
      final unit = CommercialPresentation.base(
        code: 'unidad',
        singularLabel: 'Unidad',
        pluralLabel: 'Unidades',
      );

      expect(
        () => ProductUnitProfile(
          baseUnit: unit,
          presentations: [
            unit,
            CommercialPresentation(
              code: 'UNIDAD',
              singularLabel: 'Pieza',
              pluralLabel: 'Piezas',
              baseQuantity: 1,
            ),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('adaptador legacy de StockUtils', () {
    test('traduce caja + unidades al perfil genérico', () {
      final profile = StockUtils.legacyUnitProfile(
        SaleUnitType.cajaUnidades,
        unitsPerPackage: 12,
      );

      expect(profile.baseUnit.code, 'unidad');
      expect(profile.find('caja')?.baseQuantity, 12);
      expect(profile.toBaseQuantity(presentationCode: 'caja', quantity: 2), 24);
      expect(profile.formatBaseQuantity(27), '2 Cajas y 3 Unidades');
    });

    test('mantiene paquete como unidad base histórica', () {
      final profile = StockUtils.legacyUnitProfile(
        SaleUnitType.paquete,
        unitsPerPackage: 10,
      );

      expect(profile.baseUnit.code, 'paquete');
      expect(profile.presentations, hasLength(1));
      expect(profile.formatBaseQuantity(2), '2 Paquetes');
    });
  });
}
