import 'package:flutter_test/flutter_test.dart';

import 'package:core_logic/core_logic.dart';

void main() {
  test('PendingSale conserva snapshot crítico ida y vuelta', () {
    final sale = PendingSale(
      requestId: 'req-typed-1',
      fecha: '2026-08-20T10:00:00-05:00',
      esCredito: true,
      totalAPagar: 120,
      montoAbono: 20,
      montoDeuda: 100,
      concepto: 'prueba',
      cotizacionId: 3,
      vendedorId: 8,
      authUserId: 'auth-user-8',
      tipoComprobante: 'ticket_interno',
      subtotalBruto: 130,
      descuentoGlobalPorcentaje: 7.692307,
      descuentoGlobalMonto: 10,
      motivoDescuento: 'cliente frecuente',
      descuentoAutorizadoPor: 8,
      cliente: const SaleCustomer(
        ruc: '12345678',
        nombre: 'Cliente Prueba',
        direccion: 'Lima',
      ),
      pagos: const [SalePayment(metodo: 'Efectivo', monto: 20)],
      detalles: SaleCart(const [
        SaleCartLine(productId: 5, quantity: 2, subtotal: 130, commercialUnit: 'unidad'),
      ]),
    );

    final restored = PendingSaleMapper.decode(PendingSaleMapper.encode(sale));

    expect(restored.requestId, sale.requestId);
    expect(restored.esCredito, isTrue);
    expect(restored.montoDeuda, 100);
    expect(restored.vendedorId, 8);
    expect(restored.authUserId, 'auth-user-8');
    expect(restored.cliente.nombre, 'Cliente Prueba');
    expect(restored.pagos.single.metodo, 'Efectivo');
    expect(restored.detalles.lines.single.productId, 5);
  });

  test('fromMap tolera campos opcionales históricos ausentes', () {
    final restored = PendingSaleMapper.decode({
      'request_id': 'legacy',
      'fecha': '2026-08-20T10:00:00-05:00',
      'tipo_comprobante': 'ticket_interno',
      'cliente': {'nombre': 'Cliente'},
      'detalles': <Map<String, dynamic>>[],
    });

    expect(restored.requestId, 'legacy');
    expect(restored.totalAPagar, 0);
    expect(restored.authUserId, isNull);
    expect(restored.pagos, isEmpty);
    expect(restored.cliente.ruc, isEmpty);
  });

  test('fromMap normaliza tipo de comprobante histórico', () {
    final restored = PendingSaleMapper.decode({
      'request_id': 'legacy-case',
      'fecha': '2026-08-20T10:00:00-05:00',
      'tipo_comprobante': '  TICKET_INTERNO  ',
      'cliente': const <String, dynamic>{},
      'detalles': const <Map<String, dynamic>>[],
    });

    expect(restored.tipoComprobante, 'ticket_interno');
    expect(PendingSaleMapper.encode(restored)['tipo_comprobante'], 'ticket_interno');
  });

  test('usaEfectivo detecta pago efectivo positivo', () {
    final sale = PendingSaleMapper.decode({
      'request_id': 'cash',
      'fecha': '2026-08-20T10:00:00-05:00',
      'tipo_comprobante': 'ticket_interno',
      'cliente': const <String, dynamic>{},
      'pagos': [
        {'metodo': ' Efectivo ', 'monto': 10.0},
      ],
      'detalles': const <Map<String, dynamic>>[],
    });

    expect(sale.usaEfectivo, isTrue);
  });

  test('usaEfectivo ignora efectivo en cero y pagos no efectivos', () {
    final sale = PendingSaleMapper.decode({
      'request_id': 'cash-zero',
      'fecha': '2026-08-20T10:00:00-05:00',
      'tipo_comprobante': 'ticket_interno',
      'cliente': const <String, dynamic>{},
      'pagos': [
        {'metodo': 'Efectivo', 'monto': 0.0},
        {'metodo': 'Yape', 'monto': 20.0},
      ],
      'detalles': const <Map<String, dynamic>>[],
    });

    expect(sale.usaEfectivo, isFalse);
  });
}
