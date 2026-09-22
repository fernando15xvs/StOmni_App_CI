import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StockUtils canonical sale contract', () {
    test('converts standard and mixed quantities', () {
      expect(
        StockUtils.calcularTotalPiezas(
          cajas: 2,
          unidades: 0,
          tipoVenta: SaleUnitType.caja,
          pcs: 12,
        ),
        2,
      );
      expect(
        StockUtils.calcularTotalPiezas(
          cajas: 2,
          unidades: 3,
          tipoVenta: SaleUnitType.cajaUnidades,
          pcs: 12,
        ),
        27,
      );
    });

    test('round-trips the five canonical database codes', () {
      const expected = <String, SaleUnitType>{
        'UNIDAD': SaleUnitType.unidad,
        'CAJA': SaleUnitType.caja,
        'PAQUETE': SaleUnitType.paquete,
        'CAJA_PAQUETES': SaleUnitType.cajaPaquetes,
        'CAJA_UNIDADES': SaleUnitType.cajaUnidades,
      };
      for (final entry in expected.entries) {
        expect(StockUtils.getTipoVentaFromString(entry.key), entry.value);
        expect(StockUtils.toDatabaseValue(entry.value), entry.key);
      }
    });

    test('rejects obsolete aliases and missing values', () {
      for (final value in const [
        'SOLO_CAJAS',
        'SOLO_UNIDADES',
        'AMBOS',
        'CAJA_UNIDAD',
        'CAJAS_UNIDADES',
        'PAQUETES',
        'unidad',
      ]) {
        expect(
          () => StockUtils.getTipoVentaFromString(value),
          throwsFormatException,
          reason: value,
        );
      }
      expect(
        () => StockUtils.getTipoVentaFromMap(const {}),
        throwsFormatException,
      );
    });

    test('formats canonical mixed stock', () {
      expect(
        StockUtils.formatStock(27, 12, SaleUnitType.cajaUnidades),
        '2 Cajas y 3 Unidades',
      );
      expect(
        StockUtils.formatStock(29, 12, SaleUnitType.cajaPaquetes),
        '2 Cajas y 5 Paquetes',
      );
    });
  });
}
