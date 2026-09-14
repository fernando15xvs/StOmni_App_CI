import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GreDestinatarioData.fromLookup', () {
    test('normaliza DNI con nombre, dirección y ubigeo', () {
      final result = GreDestinatarioData.fromLookup(
        tipo: 'dni',
        data: {
          'nombre_completo': 'JUAN PEREZ',
          'data': {
            'direccion': ' AV. LIMA 123 ',
            'ubigeo': '150101',
          },
        },
      );

      expect(result.tipoDocumentoSunat, '1');
      expect(result.nombre, 'JUAN PEREZ');
      expect(result.direccion, 'AV. LIMA 123');
      expect(result.ubigeo, '150101');
    });

    test('normaliza RUC usando razon social y ubigeo alternativo', () {
      final result = GreDestinatarioData.fromLookup(
        tipo: 'ruc',
        data: {
          'razon_social': 'EMPRESA SAC',
          'data': {
            'direccion': 'JR. PRUEBA 456',
            'ubigeo_sunat': '130101',
          },
        },
      );

      expect(result.tipoDocumentoSunat, '6');
      expect(result.nombre, 'EMPRESA SAC');
      expect(result.direccion, 'JR. PRUEBA 456');
      expect(result.ubigeo, '130101');
    });

    test('acepta codigo_ubigeo como tercer formato', () {
      final result = GreDestinatarioData.fromLookup(
        tipo: 'ruc',
        data: {
          'razon_social': 'EMPRESA SAC',
          'data': {'codigo_ubigeo': '010701'},
        },
      );

      expect(result.ubigeo, '010701');
    });

    test('descarta ubigeo inválido sin afectar otros datos', () {
      final result = GreDestinatarioData.fromLookup(
        tipo: 'dni',
        data: {
          'nombre_completo': 'ANA PEREZ',
          'data': {
            'direccion': 'CALLE 1',
            'ubigeo': 'ABC123',
          },
        },
      );

      expect(result.nombre, 'ANA PEREZ');
      expect(result.direccion, 'CALLE 1');
      expect(result.ubigeo, isEmpty);
    });

    test('tolera payload interno ausente', () {
      final result = GreDestinatarioData.fromLookup(
        tipo: 'ruc',
        data: {'razon_social': 'SIN DIRECCION SAC'},
      );

      expect(result.nombre, 'SIN DIRECCION SAC');
      expect(result.direccion, isEmpty);
      expect(result.ubigeo, isEmpty);
    });
  });

  group('GreDestinatarioPolicy.debeActualizarLlegada', () {
    test('actualiza llegada si todavía copia al destinatario anterior', () {
      final result = GreDestinatarioPolicy.debeActualizarLlegada(
        direccionDestinatarioAnterior: 'AV. A 100',
        ubigeoDestinatarioAnterior: '150101',
        direccionLlegadaActual: 'AV. A 100',
        ubigeoLlegadaActual: '150101',
        usaAgenciaDestino: false,
      );

      expect(result, isTrue);
    });

    test('conserva llegada si fue modificada manualmente', () {
      final result = GreDestinatarioPolicy.debeActualizarLlegada(
        direccionDestinatarioAnterior: 'AV. A 100',
        ubigeoDestinatarioAnterior: '150101',
        direccionLlegadaActual: 'JR. DESTINO MANUAL 200',
        ubigeoLlegadaActual: '130101',
        usaAgenciaDestino: false,
      );

      expect(result, isFalse);
    });

    test('conserva llegada cuando existe agencia de destino', () {
      final result = GreDestinatarioPolicy.debeActualizarLlegada(
        direccionDestinatarioAnterior: 'AV. A 100',
        ubigeoDestinatarioAnterior: '150101',
        direccionLlegadaActual: 'AGENCIA DESTINO',
        ubigeoLlegadaActual: '140101',
        usaAgenciaDestino: true,
      );

      expect(result, isFalse);
    });

    test('trata campos vacíos iniciales como llegada vinculada', () {
      final result = GreDestinatarioPolicy.debeActualizarLlegada(
        direccionDestinatarioAnterior: '',
        ubigeoDestinatarioAnterior: '',
        direccionLlegadaActual: '',
        ubigeoLlegadaActual: '',
        usaAgenciaDestino: false,
      );

      expect(result, isTrue);
    });
  });
}
