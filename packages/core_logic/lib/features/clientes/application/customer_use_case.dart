class CustomerRecord {
  const CustomerRecord({
    required this.id,
    required this.name,
    required this.document,
    required this.address,
    this.documentType,
    this.phone,
  });

  final int id;
  final String name;
  final String document;
  final String address;
  final String? documentType;
  final String? phone;
}

class CustomerDraft {
  const CustomerDraft({
    required this.name,
    required this.document,
    required this.address,
    this.documentType,
    this.phone,
  });

  final String name;
  final String document;
  final String address;
  final String? documentType;
  final String? phone;
}

abstract interface class CustomerGateway {
  Future<List<CustomerRecord>> list({
    int limit = 50,
    int offset = 0,
    String query = '',
  });
  Future<bool> documentExists(String document, {int? excludingId});
  Future<CustomerRecord> save(CustomerDraft draft, {int? id});
  Future<void> delete(int id);
}

class CustomerUseCase {
  const CustomerUseCase(this._gateway);
  final CustomerGateway _gateway;

  Future<List<CustomerRecord>> list({String query = '', int limit = 50, int offset = 0}) =>
      _gateway.list(query: query.trim(), limit: limit, offset: offset);

  Future<CustomerRecord> save(CustomerDraft draft, {int? id}) async {
    final name = draft.name.trim();
    final document = draft.document.trim();
    if (name.isEmpty) throw ArgumentError('El nombre del cliente es obligatorio.');
    if (document.isNotEmpty && await _gateway.documentExists(document, excludingId: id)) {
      throw StateError('Ya existe un cliente con ese documento.');
    }
    return _gateway.save(
      CustomerDraft(
        name: name,
        document: document,
        address: draft.address.trim(),
        documentType: draft.documentType?.trim(),
        phone: draft.phone?.trim(),
      ),
      id: id,
    );
  }

  Future<void> delete(int id) {
    if (id <= 0) throw ArgumentError('Cliente inválido.');
    return _gateway.delete(id);
  }
}
