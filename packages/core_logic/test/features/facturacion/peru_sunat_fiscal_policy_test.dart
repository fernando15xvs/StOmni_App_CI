import 'package:core_logic/features/facturacion/domain/peru_sunat_fiscal_policy.dart';
import 'package:core_logic/features/ventas/domain/fiscal_policy.dart';
import 'package:core_logic/features/ventas/domain/sale_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = PeruSunatFiscalPolicy();
  final now = DateTime(2026, 9, 4, 12);
  String? validate({
    String type = 'boleta',
    double total = 700,
    String document = '',
    String name = '',
    bool credit = false,
    DateTime? date,
  }) => policy.validate(
    FiscalSaleDraft(
      documentCode: type,
      date: date ?? now,
      isCredit: credit,
      total: total,
      customer: SaleCustomer(ruc: document, nombre: name, direccion: ''),
    ),
    now: now,
  );

  test('solo el ticket admite cola offline', () {
    expect(policy.documentFor('ticket_interno')!.allowsOffline, isTrue);
    expect(policy.documentFor('boleta')!.allowsOffline, isFalse);
    expect(policy.documentFor('factura')!.requiresElectronicEmission, isTrue);
    expect(policy.documentFor('desconocido'), isNull);
  });
  test('se conserva el umbral existente de identificación para boleta', () {
    expect(validate(total: 700), isNull);
    expect(validate(total: 700.01), contains('DNI'));
    expect(
      validate(total: 701, document: '12345678'),
      contains('nombre completo'),
    );
    expect(validate(total: 701, document: '12345678', name: 'Cliente'), isNull);
  });
  test('se conservan crédito, fecha y datos de factura', () {
    expect(validate(type: 'factura', credit: true), contains('al contado'));
    expect(
      validate(date: now.add(const Duration(days: 1))),
      contains('futuro'),
    );
    expect(
      validate(
        type: 'factura',
        document: '20123456789',
        name: 'Empresa',
        date: now.subtract(const Duration(days: 3)),
      ),
      isNull,
    );
    expect(
      validate(
        type: 'factura',
        document: '20123456789',
        name: 'Empresa',
        date: now.subtract(const Duration(days: 4)),
      ),
      contains('tres días'),
    );
    expect(validate(type: 'factura', document: '12345678'), contains('RUC'));
  });
  test('política interna no hereda condiciones de emisión electrónica', () {
    const internal = InternalTicketFiscalPolicy();
    expect(internal.documentFor('factura'), isNull);
    expect(
      internal.validate(
        FiscalSaleDraft(
          documentCode: 'ticket_interno',
          date: DateTime(2000),
          isCredit: true,
          total: 1500,
          customer: const SaleCustomer(ruc: '', nombre: '', direccion: ''),
        ),
        now: now,
      ),
      isNull,
    );
  });
}
