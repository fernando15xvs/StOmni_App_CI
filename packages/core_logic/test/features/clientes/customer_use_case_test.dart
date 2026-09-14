import 'package:core_logic/features/clientes/application/customer_use_case.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeGateway implements CustomerGateway {
  final records = <CustomerRecord>[];
  int _nextId = 1;

  @override
  Future<void> delete(int id) async => records.removeWhere((row) => row.id == id);

  @override
  Future<bool> documentExists(String document, {int? excludingId}) async =>
      records.any((row) => row.document == document && row.id != excludingId);

  @override
  Future<List<CustomerRecord>> list({
    int limit = 50,
    int offset = 0,
    String query = '',
  }) async => records
      .where((row) => query.isEmpty || row.name.contains(query) || row.document.contains(query))
      .skip(offset)
      .take(limit)
      .toList();

  @override
  Future<CustomerRecord> save(CustomerDraft draft, {int? id}) async {
    final row = CustomerRecord(
      id: id ?? _nextId++,
      name: draft.name,
      document: draft.document,
      address: draft.address,
      documentType: draft.documentType,
      phone: draft.phone,
    );
    records.removeWhere((current) => current.id == row.id);
    records.add(row);
    return row;
  }
}

void main() {
  test('normalizes and saves a customer', () async {
    final gateway = _FakeGateway();
    final useCase = CustomerUseCase(gateway);
    final saved = await useCase.save(
      const CustomerDraft(
        name: '  Cliente Uno  ',
        document: ' 12345678 ',
        address: ' Lima ',
      ),
    );
    expect(saved.name, 'Cliente Uno');
    expect(saved.document, '12345678');
    expect(saved.address, 'Lima');
  });

  test('rejects duplicate document when creating another customer', () async {
    final gateway = _FakeGateway();
    final useCase = CustomerUseCase(gateway);
    await useCase.save(
      const CustomerDraft(name: 'Uno', document: '123', address: ''),
    );
    expect(
      () => useCase.save(
        const CustomerDraft(name: 'Dos', document: '123', address: ''),
      ),
      throwsStateError,
    );
  });

  test('allows preserving the same document when editing the same customer', () async {
    final gateway = _FakeGateway();
    final useCase = CustomerUseCase(gateway);
    final saved = await useCase.save(
      const CustomerDraft(name: 'Uno', document: '123', address: ''),
    );
    final updated = await useCase.save(
      const CustomerDraft(name: 'Uno Editado', document: '123', address: ''),
      id: saved.id,
    );
    expect(updated.id, saved.id);
    expect(updated.name, 'Uno Editado');
  });
}
