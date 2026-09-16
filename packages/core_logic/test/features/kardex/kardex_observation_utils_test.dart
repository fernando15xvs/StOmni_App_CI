import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KardexObservationUtils', () {
    test('identifica una venta pendiente como crédito', () {
      expect(
        KardexObservationUtils.esVentaCredito({
          'estado': 'pendiente',
          'saldo': 0,
        }),
        isTrue,
      );
    });

    test(
      'identifica saldo pendiente como crédito aunque el estado sea distinto',
      () {
        expect(
          KardexObservationUtils.esVentaCredito({
            'estado': 'pagado',
            'saldo': 25.50,
          }),
          isTrue,
        );
      },
    );

    test('venta pagada sin saldo no se etiqueta como crédito', () {
      expect(
        KardexObservationUtils.esVentaCredito({'estado': 'pagado', 'saldo': 0}),
        isFalse,
      );
    });

    test('agrega Crédito solo a observaciones de venta y sin duplicarlo', () {
      expect(
        KardexObservationUtils.etiquetarCredito('Venta #123', esCredito: true),
        'Venta #123 · Crédito',
      );
      expect(
        KardexObservationUtils.etiquetarCredito(
          'Venta #123 · Crédito',
          esCredito: true,
        ),
        'Venta #123 · Crédito',
      );
      expect(
        KardexObservationUtils.etiquetarCredito(
          'Traslado #123',
          esCredito: true,
        ),
        'Traslado #123',
      );
    });
  });
}
