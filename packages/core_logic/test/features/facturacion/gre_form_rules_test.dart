import 'package:flutter_test/flutter_test.dart';
import 'package:core_logic/core_logic.dart';

void main() {
  group('GreFormRules', () {
    test('convierte timestamptz UTC a hora de pared de Lima', () {
      final value = GreFormRules.desdeSupabaseALima(
        '2026-08-19T00:49:02.000Z',
      );

      expect(value, DateTime.utc(2026, 8, 18, 19, 49, 2));
    });

    test('reabrir y volver a guardar no suma cinco horas', () {
      const persisted = '2026-08-19T00:49:02.000Z';

      final firstLoad = GreFormRules.desdeSupabaseALima(persisted)!;
      final firstSaveIso = AppTime.toIsoLima(firstLoad);
      final persistedAgain = DateTime.parse(firstSaveIso).toUtc();
      final secondLoad = GreFormRules.desdeSupabaseALima(
        persistedAgain.toIso8601String(),
      );

      expect(firstSaveIso, '2026-08-18T19:49:02-05:00');
      expect(persistedAgain, DateTime.utc(2026, 8, 19, 0, 49, 2));
      expect(secondLoad, firstLoad);
    });

    test('valor de fecha inválido devuelve null', () {
      expect(GreFormRules.desdeSupabaseALima(null), isNull);
      expect(GreFormRules.desdeSupabaseALima(''), isNull);
      expect(GreFormRules.desdeSupabaseALima('no-es-fecha'), isNull);
    });

    test('mantiene minuto exacto sin modificarlo', () {
      final value = DateTime(2026, 8, 18, 15, 30);
      expect(GreFormRules.redondearHaciaArribaAlMinuto(value), value);
    });

    test('redondea segundos hacia el minuto siguiente', () {
      final value = DateTime(2026, 8, 18, 15, 30, 48);
      expect(
        GreFormRules.redondearHaciaArribaAlMinuto(value),
        DateTime(2026, 8, 18, 15, 31),
      );
    });

    test('redondeo UTC conserva UTC y no depende de la zona del dispositivo', () {
      final value = DateTime.utc(2026, 8, 19, 18, 0, 48);
      final rounded = GreFormRules.redondearHaciaArribaAlMinuto(value);

      expect(rounded, DateTime.utc(2026, 8, 19, 18, 1));
      expect(rounded.isUtc, isTrue);
    });

    test('inicio mínimo agrega un minuto completo', () {
      final ahora = DateTime(2026, 8, 18, 15, 30, 48);
      expect(
        GreFormRules.inicioTrasladoMinimo(ahora),
        DateTime(2026, 8, 18, 15, 32),
      );
    });

    test('inicio mínimo UTC sigue siendo comparable con fecha GRE fake UTC', () {
      final ahora = DateTime.utc(2026, 8, 19, 18, 0);
      final minimo = GreFormRules.inicioTrasladoMinimo(ahora);
      final traslado = DateTime.utc(2026, 8, 19, 20, 0);

      expect(minimo, DateTime.utc(2026, 8, 19, 18, 1));
      expect(minimo.isUtc, isTrue);
      expect(traslado.isBefore(minimo), isFalse);
    });

    test('GRE transportista tiene flujo transportista', () {
      expect(
        GreFormRules.flujoTransporte(
          tipoGuia: 'transportista',
          modalidadTransporte: '02',
          indTransbordo: true,
        ),
        'transportista',
      );
    });

    test('transbordo prevalece en GRE remitente', () {
      expect(
        GreFormRules.flujoTransporte(
          tipoGuia: 'remitente',
          modalidadTransporte: '02',
          indTransbordo: true,
        ),
        'transbordo',
      );
    });

    test('modalidad 01 es pública y 02 privada', () {
      expect(
        GreFormRules.flujoTransporte(
          tipoGuia: 'remitente',
          modalidadTransporte: '01',
          indTransbordo: false,
        ),
        'publico',
      );
      expect(
        GreFormRules.flujoTransporte(
          tipoGuia: 'remitente',
          modalidadTransporte: '02',
          indTransbordo: false,
        ),
        'privado',
      );
    });

    test('ubigeo exige exactamente seis dígitos', () {
      expect(GreFormRules.ubigeoValido('150105'), isTrue);
      expect(GreFormRules.ubigeoValido(' 150105 '), isTrue);
      expect(GreFormRules.ubigeoValido('15010'), isFalse);
      expect(GreFormRules.ubigeoValido('ABC105'), isFalse);
    });
  });
}
