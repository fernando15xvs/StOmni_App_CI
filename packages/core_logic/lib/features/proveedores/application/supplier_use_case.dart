class SupplierRecord {
  const SupplierRecord({
    required this.id,
    required this.name,
    required this.document,
    required this.active,
    this.documentType,
    this.phone,
    this.address,
  });

  final int id;
  final String name;
  final String document;
  final bool active;
  final String? documentType;
  final String? phone;
  final String? address;
}

class SupplierDraft {
  const SupplierDraft({
    required this.name,
    required this.document,
    this.documentType,
    this.phone,
    this.address,
    this.active = true,
  });

  final String name;
  final String document;
  final String? documentType;
  final String? phone;
  final String? address;
  final bool active;
}

abstract interface class SupplierGateway {
  Future<List<SupplierRecord>> list({
    String query = '',
    bool activeOnly = false,
  });
  Future<bool> documentExists(String document, {int? excludingId});
  Future<SupplierRecord> save(SupplierDraft draft, {int? id});
  Future<void> deactivate(int id);
}

class SupplierUseCase {
  const SupplierUseCase(this._gateway);
  final SupplierGateway _gateway;

  Future<List<SupplierRecord>> list({
    String query = '',
    bool activeOnly = false,
  }) => _gateway.list(query: query.trim(), activeOnly: activeOnly);

  Future<SupplierRecord> save(SupplierDraft draft, {int? id}) async {
    final name = draft.name.trim();
    final document = draft.document.trim();
    if (name.isEmpty)
      throw ArgumentError('El nombre del proveedor es obligatorio.');
    if (document.isNotEmpty &&
        await _gateway.documentExists(document, excludingId: id)) {
      throw StateError('Ya existe un proveedor con ese documento.');
    }
    return _gateway.save(
      SupplierDraft(
        name: name,
        document: document,
        documentType: draft.documentType?.trim(),
        phone: draft.phone?.trim(),
        address: draft.address?.trim(),
        active: draft.active,
      ),
      id: id,
    );
  }

  Future<void> deactivate(int id) {
    if (id <= 0) throw ArgumentError('Proveedor inválido.');
    return _gateway.deactivate(id);
  }
}
