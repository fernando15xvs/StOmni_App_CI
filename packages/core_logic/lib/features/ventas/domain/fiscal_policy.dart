import 'sale_models.dart';

class FiscalSaleDraft {
  const FiscalSaleDraft({
    required this.documentCode,
    required this.date,
    required this.isCredit,
    required this.total,
    required this.customer,
  });
  final String documentCode;
  final DateTime date;
  final bool isCredit;
  final double total;
  final SaleCustomer customer;
}

class FiscalDocumentType {
  const FiscalDocumentType({
    required this.code,
    required this.requiresElectronicEmission,
    required this.allowsOffline,
  });
  final String code;
  final bool requiresElectronicEmission;
  final bool allowsOffline;
}

/// Ventas no conoce países, autoridades tributarias ni formatos de identidad.
abstract interface class FiscalPolicy {
  FiscalDocumentType? documentFor(String code);
  String? validate(FiscalSaleDraft sale, {required DateTime now});
}

/// Política mínima para clientes que solo registran documentos internos.
class InternalTicketFiscalPolicy implements FiscalPolicy {
  const InternalTicketFiscalPolicy();
  static const document = FiscalDocumentType(
    code: 'ticket_interno', requiresElectronicEmission: false, allowsOffline: true,
  );

  @override
  FiscalDocumentType? documentFor(String code) =>
      code.trim().toLowerCase() == document.code ? document : null;

  @override
  String? validate(FiscalSaleDraft sale, {required DateTime now}) =>
      documentFor(sale.documentCode) == null
          ? 'El tipo de comprobante no es válido.'
          : null;
}
