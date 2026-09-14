import 'package:flutter_test/flutter_test.dart';
import 'package:core_logic/core_logic.dart';

void main() {
  test('genera un PDF de cierre sin acceder a datos remotos', () async {
    final bytes = await CajaCierrePdfRenderer.generar(
      {
        'fecha_apertura': '2026-08-19T08:00:00-05:00',
        'fecha_cierre': '2026-08-19T18:00:00-05:00',
        'monto_apertura': 100.0,
        'monto_cierre_esperado': 250.0,
        'monto_cierre_real': 250.0,
        'observaciones': 'Prueba',
      },
      [
        {
          'tipo': 'ingreso',
          'monto': 150.0,
          'descripcion': 'Venta efectivo',
          'fecha': '2026-08-19T10:00:00-05:00',
        },
      ],
    );

    expect(bytes.length, greaterThan(100));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });
}
