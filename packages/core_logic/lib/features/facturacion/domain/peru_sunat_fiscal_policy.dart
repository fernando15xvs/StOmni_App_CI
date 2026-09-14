import '../../ventas/domain/fiscal_policy.dart';

/// Extrae las restricciones que ya aplicaba StOmni. No cambia normativa,
/// plazos ni el contrato RPC; la validación del servidor sigue siendo obligatoria.
class PeruSunatFiscalPolicy implements FiscalPolicy {
  const PeruSunatFiscalPolicy();

  static const _documents = <String, FiscalDocumentType>{
    'ticket_interno': InternalTicketFiscalPolicy.document,
    'boleta': FiscalDocumentType(
      code: 'boleta', requiresElectronicEmission: true, allowsOffline: false,
    ),
    'factura': FiscalDocumentType(
      code: 'factura', requiresElectronicEmission: true, allowsOffline: false,
    ),
  };

  @override
  FiscalDocumentType? documentFor(String code) => _documents[code.trim().toLowerCase()];

  @override
  String? validate(FiscalSaleDraft sale, {required DateTime now}) {
    final type = documentFor(sale.documentCode);
    if (type == null) return 'El tipo de comprobante no es válido.';
    if (sale.isCredit && type.requiresElectronicEmission) {
      return 'Las facturas y boletas electrónicas solo pueden emitirse al contado. '
          'Para una venta a crédito usa Ticket Interno.';
    }
    if (type.requiresElectronicEmission) {
      final today = DateTime(now.year, now.month, now.day);
      final issued = DateTime(sale.date.year, sale.date.month, sale.date.day);
      if (issued.isAfter(today)) {
        return 'La fecha de emisión electrónica no puede estar en el futuro.';
      }
      if (type.code == 'factura' && today.difference(issued).inDays > 3) {
        return 'La factura supera el plazo máximo de tres días calendario '
            'posteriores a su fecha de emisión.';
      }
    }
    final identity = sale.customer.ruc.trim();
    final name = sale.customer.nombre.trim();
    if (type.code == 'factura') {
      if (!RegExp(r'^\d{11}$').hasMatch(identity)) {
        return 'Para emitir factura, el RUC debe tener 11 dígitos.';
      }
      if (name.isEmpty) return 'La factura requiere la razón social del cliente.';
    }
    if (type.code == 'boleta') {
      if (identity.isNotEmpty && identity != '00000000' &&
          !RegExp(r'^\d{8}$').hasMatch(identity)) {
        return 'Para emitir boleta, ingresa un DNI de 8 dígitos '
            'o deja el documento vacío.';
      }
      if (sale.total > 700.00) {
        if (!RegExp(r'^\d{8}$').hasMatch(identity)) {
          return 'Para boletas mayores a S/ 700.00, el DNI de 8 dígitos '
              'es obligatorio.';
        }
        if (name.isEmpty) {
          return 'Para boletas mayores a S/ 700.00, el nombre completo '
              'del cliente es obligatorio.';
        }
      }
    }
    return null;
  }
}
