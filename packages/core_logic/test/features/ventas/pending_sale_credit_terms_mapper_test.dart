import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PendingSaleMapper conserva cronograma de crédito versionado', () {
    final sale = PendingSale(
      requestId: 'credit-queue-1',
      fecha: '2026-11-01T10:00:00-05:00',
      esCredito: true,
      totalAPagar: 100,
      montoAbono: 20,
      montoDeuda: 80,
      concepto: 'Venta a crédito',
      tipoComprobante: 'ticket_interno',
      subtotalBruto: 100,
      descuentoGlobalPorcentaje: 0,
      descuentoGlobalMonto: 0,
      motivoDescuento: '',
      cliente: const SaleCustomer(
        ruc: '12345678',
        nombre: 'Cliente',
        direccion: 'Lima',
      ),
      pagos: const [SalePayment(metodo: 'Efectivo', monto: 20)],
      detalles: SaleCart.empty(),
      creditTerms: SaleCreditTerms(
        installments: [
          SaleCreditInstallment(
            number: 1,
            amount: 40,
            dueDate: DateTime(2026, 12, 1),
          ),
          SaleCreditInstallment(
            number: 2,
            amount: 40,
            dueDate: DateTime(2027, 1, 1),
          ),
        ],
      ),
    );

    final encoded = PendingSaleMapper.encode(sale);
    expect(encoded['schema_version'], 3);

    final decoded = PendingSaleMapper.decode(encoded);
    expect(decoded.creditTerms, isNotNull);
    expect(decoded.creditTerms!.installments, hasLength(2));
    expect(decoded.creditTerms!.total, 80);
    expect(
      decoded.creditTerms!.installments.first.dueDate,
      DateTime(2026, 12, 1),
    );
  });
}
