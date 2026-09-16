import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ProcesarVentaCommand', () {
    test('normaliza ticket legacy y conserva modelos tipados', () {
      final command = ProcesarVentaCommand(
        requestId: 'req-1',
        customer: const SaleCustomer(
          ruc: '12345678',
          nombre: 'Cliente',
          direccion: 'Lima',
        ),
        esCredito: false,
        totalAPagar: 25,
        montoAbono: 25,
        payments: const [SalePayment(metodo: 'Efectivo', monto: 25)],
        cart: SaleCartMapper.decode([
          {'id': 1, 'cantidad': 2, 'subtotal': 25, 'tipo_unidad': 'unidad'},
        ]),
        fecha: DateTime(2026, 8, 30),
        tipoComprobante: ' TICKET ',
      );

      expect(command.tipoComprobanteNormalizado, 'ticket_interno');
      expect(command.customer.nombre, 'Cliente');
      expect(command.payments.single.monto, 25);
      expect(command.cart.lineCount, 1);
      expect(command.cart.lines.single.productId, 1);
    });

    test('reconstruye comando desde una venta pendiente', () {
      final pending = PendingSale(
        requestId: 'offline-1',
        fecha: '2026-08-30T12:00:00',
        esCredito: true,
        totalAPagar: 100,
        montoAbono: 20,
        montoDeuda: 80,
        concepto: 'Venta offline',
        tipoComprobante: 'ticket_interno',
        subtotalBruto: 110,
        descuentoGlobalPorcentaje: 9.0909,
        descuentoGlobalMonto: 10,
        motivoDescuento: 'Promoción',
        cliente: const SaleCustomer(
          ruc: '87654321',
          nombre: 'Cliente Offline',
          direccion: '',
        ),
        pagos: const [SalePayment(metodo: 'Efectivo', monto: 20)],
        detalles: SaleCartMapper.decode([
          {'id': 7, 'cantidad': 1, 'subtotal': 110, 'tipo_unidad': 'caja'},
        ]),
        vendedorId: 4,
        authUserId: 'auth-1',
      );

      final fecha = DateTime(2026, 8, 30, 12);
      final command = ProcesarVentaCommand.fromPendingSale(
        pending,
        fecha: fecha,
      );

      expect(command.requestId, 'offline-1');
      expect(command.fecha, fecha);
      expect(command.esCredito, isTrue);
      expect(command.totalAPagar, 100);
      expect(command.montoAbono, 20);
      expect(command.customer.nombre, 'Cliente Offline');
      expect(command.vendedorId, 4);
      expect(command.descuentoGlobalMonto, 10);
      expect(command.cart.containsProduct(7), isTrue);
    });
  });
}
