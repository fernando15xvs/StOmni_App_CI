class ElectronicDocumentRecord {
  const ElectronicDocumentRecord({
    required this.id,
    required this.category,
    required this.number,
    required this.typeLabel,
    required this.status,
    required this.party,
    this.sunatDescription,
    this.saleId,
    this.issueDate,
    this.total,
  });

  final String id;
  final String category;
  final String number;
  final String typeLabel;
  final String status;
  final String party;
  final String? sunatDescription;
  final int? saleId;
  final DateTime? issueDate;
  final double? total;

  String get searchableText => [
        number,
        typeLabel,
        party,
        status,
        sunatDescription ?? '',
      ].join(' ').toLowerCase();
}

class ElectronicDocumentActionResult {
  const ElectronicDocumentActionResult({
    required this.status,
    this.message,
  });

  final String status;
  final String? message;
}

abstract interface class ElectronicDocumentGateway {
  Future<List<ElectronicDocumentRecord>> list({
    required DateTime start,
    required DateTime end,
    int page = 0,
    int pageSize = 50,
  });

  Future<ElectronicDocumentActionResult> consult(
    ElectronicDocumentRecord document, {
    bool consultSunat = true,
  });

  Future<ElectronicDocumentActionResult> retry(
    ElectronicDocumentRecord document,
  );
}

class ElectronicDocumentUseCase {
  const ElectronicDocumentUseCase(this._gateway);

  final ElectronicDocumentGateway _gateway;

  Future<List<ElectronicDocumentRecord>> list({
    required DateTime start,
    required DateTime end,
    int page = 0,
    int pageSize = 50,
  }) {
    if (end.isBefore(start)) {
      throw ArgumentError('El rango de documentos no es válido.');
    }
    return _gateway.list(
      start: start,
      end: end,
      page: page < 0 ? 0 : page,
      pageSize: pageSize.clamp(10, 100),
    );
  }

  Future<ElectronicDocumentActionResult> consult(
    ElectronicDocumentRecord document, {
    bool consultSunat = true,
  }) => _gateway.consult(document, consultSunat: consultSunat);

  Future<ElectronicDocumentActionResult> retry(
    ElectronicDocumentRecord document,
  ) {
    if (!{'factura', 'boleta', 'nota', 'guia'}.contains(document.category)) {
      throw ArgumentError('El tipo de documento no admite reintento.');
    }
    return _gateway.retry(document);
  }
}
