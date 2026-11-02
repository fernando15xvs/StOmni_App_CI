import 'package:flutter_test/flutter_test.dart';

import 'package:core_logic/core_logic.dart';

void main() {
  final ahora = DateTime(2026, 8, 20, 10);

  String? validar({
    bool esCredito = false,
    String tipo = 'ticket_interno',
    DateTime? fecha,
    double subtotal = 100,
    double descuento = 0,
    bool porcentaje = true,
    double descuentoMonto = 0,
    double descuentoPorcentaje = 0,
    String motivo = '',
    double total = 100,
    double pagado = 100,
    double abono = 0,
    SaleCreditTerms? creditTerms,
    String documento = '',
    String nombre = '',
  }) {
    return VentaFormRules.validar(
      fiscalPolicy: const PeruSunatFiscalPolicy(),
      esCredito: esCredito,
      tipoComprobante: tipo,
      fecha: fecha ?? ahora,
      ahora: ahora,
      subtotalBruto: subtotal,
      valorDescuentoIngresado: descuento,
      descuentoEsPorcentaje: porcentaje,
      descuentoGlobalMonto: descuentoMonto,
      descuentoGlobalPorcentaje: descuentoPorcentaje,
      motivoDescuento: motivo,
      totalFinal: total,
      totalPagado: pagado,
      montoAbono: abono,
      creditTerms: creditTerms,
      documentoCliente: documento,
      nombreCliente: nombre,
    );
  }

  test('ticket interno al contado válido no produce error', () {
    expect(validar(), isNull);
  });

  test('tipo de comprobante desconocido se rechaza fail-closed', () {
    expect(validar(tipo: 'otro'), contains('no es válido'));
  });

  test('crédito bloquea factura y boleta', () {
    expect(
      validar(esCredito: true, tipo: 'factura'),
      contains('solo pueden emitirse al contado'),
    );
  });

  test('cronograma de crédito debe cuadrar con el saldo pendiente', () {
    final terms = SaleCreditTerms.single(
      amount: 70,
      dueDate: DateTime(2026, 9, 20),
    );
    expect(
      validar(
        esCredito: true,
        total: 100,
        abono: 20,
        pagado: 0,
        creditTerms: terms,
      ),
      contains('sumar exactamente'),
    );
  });

  test('cronograma exige vencimientos posteriores a la venta', () {
    final terms = SaleCreditTerms.single(
      amount: 80,
      dueDate: DateTime(2026, 8, 20),
    );
    expect(
      validar(
        esCredito: true,
        total: 100,
        abono: 20,
        pagado: 0,
        creditTerms: terms,
      ),
      contains('después de la fecha'),
    );
  });

  test('cronograma válido de ticket a crédito pasa reglas generales', () {
    final terms = SaleCreditTerms(
      installments: [
        SaleCreditInstallment(
          number: 1,
          amount: 40,
          dueDate: DateTime(2026, 9, 20),
        ),
        SaleCreditInstallment(
          number: 2,
          amount: 40,
          dueDate: DateTime(2026, 10, 20),
        ),
      ],
    );
    expect(
      validar(
        esCredito: true,
        total: 100,
        abono: 20,
        pagado: 0,
        creditTerms: terms,
      ),
      isNull,
    );
  });

  test('boleta mayor a 700 exige DNI y nombre', () {
    expect(
      validar(tipo: 'boleta', total: 701, pagado: 701),
      contains('DNI de 8 dígitos'),
    );
    expect(
      validar(tipo: 'boleta', total: 701, pagado: 701, documento: '12345678'),
      contains('nombre completo'),
    );
    expect(
      validar(
        tipo: 'boleta',
        total: 701,
        pagado: 701,
        documento: '12345678',
        nombre: 'Cliente Prueba',
      ),
      isNull,
    );
  });

  test('pagos al contado deben cuadrar con el total', () {
    expect(
      validar(total: 100, pagado: 99),
      contains('deben sumar exactamente'),
    );
  });

  test('factura no admite fecha futura ni más de tres días', () {
    expect(
      validar(
        tipo: 'factura',
        fecha: DateTime(2026, 8, 21),
        documento: '20123456789',
        nombre: 'Empresa SAC',
      ),
      contains('futuro'),
    );
    expect(
      validar(
        tipo: 'factura',
        fecha: DateTime(2026, 8, 16),
        documento: '20123456789',
        nombre: 'Empresa SAC',
      ),
      contains('tres días'),
    );
  });

  test('descuento de 10 por ciento o más exige motivo', () {
    expect(validar(descuentoPorcentaje: 10), contains('requieren un motivo'));
    expect(
      validar(descuentoPorcentaje: 10, motivo: 'Promoción autorizada'),
      isNull,
    );
  });
}
