import 'package:flutter_test/flutter_test.dart';
import 'package:core_logic/core_logic.dart';

void main() {
  group('GreTransporteCatalogRules', () {
    test('valida documentos y placa', () {
      expect(GreTransporteCatalogRules.dniValido('12345678'), isTrue);
      expect(GreTransporteCatalogRules.dniValido('123'), isFalse);
      expect(GreTransporteCatalogRules.rucValido('20123456789'), isTrue);
      expect(GreTransporteCatalogRules.rucValido('201234'), isFalse);
      expect(GreTransporteCatalogRules.placaValida('ABC-123'), isTrue);
      expect(GreTransporteCatalogRules.placaValida('A1'), isFalse);
    });

    test('exige datos reales del transporte privado', () {
      expect(
        GreTransporteCatalogRules.conductorValido(
          dni: '12345678',
          nombres: 'Luis',
          apellidos: 'Aguilar',
          licencia: 'Q12345678',
        ),
        isTrue,
      );
      expect(
        GreTransporteCatalogRules.vehiculoValido(
          placa: 'ABC-123',
          marca: 'Toyota',
          constancia: 'TUC-001',
        ),
        isTrue,
      );
      expect(
        GreTransporteCatalogRules.vehiculoValido(
          placa: 'ABC-123',
          marca: '',
          constancia: 'TUC-001',
        ),
        isFalse,
      );
    });

    test('agencia exige ubigeo y al menos un uso', () {
      expect(
        GreTransporteCatalogRules.agenciaValida(
          nombre: 'Agencia Lima',
          direccion: 'Av. Principal 123',
          ubigeo: '150101',
          permiteOrigen: true,
          permiteDestino: false,
        ),
        isTrue,
      );
      expect(
        GreTransporteCatalogRules.agenciaValida(
          nombre: 'Agencia Lima',
          direccion: 'Av. Principal 123',
          ubigeo: '150101',
          permiteOrigen: false,
          permiteDestino: false,
        ),
        isFalse,
      );
    });

    test('separa nombre legado solo cuando no hay apellidos', () {
      final parsed = GreTransporteCatalogRules.separarNombreLegacy(
        'JUAN CARLOS PEREZ LOPEZ',
        '',
      );
      expect(parsed.nombres, 'JUAN CARLOS');
      expect(parsed.apellidos, 'PEREZ LOPEZ');

      final intacto = GreTransporteCatalogRules.separarNombreLegacy(
        'JUAN CARLOS',
        'PEREZ LOPEZ',
      );
      expect(intacto.nombres, 'JUAN CARLOS');
      expect(intacto.apellidos, 'PEREZ LOPEZ');
    });
  });
}
