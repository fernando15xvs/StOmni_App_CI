import 'package:core_logic/features/proveedores/application/supplier_use_case.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeGateway implements SupplierGateway {
  final records = <SupplierRecord>[];
  int _nextId = 1;

  @override
  Future<void> deactivate(int id) async {
    final index = records.indexWhere((row) => row.id == id);
    if (index < 0) return;
    final row = records[index];
    records[index] = SupplierRecord(
      id: row.id,
      name: row.name,
      document: row.document,
      active: false,
      documentType: row.documentType,
      phone: row.phone,
      address: row.address,
    );
  }

  @override
  Future<bool> documentExists(String document, {int? excludingId}) async =>
      records.any((row) => row.document == document && row.id != excludingId);

  @override
  Future<List<SupplierRecord>> list({
    String query = '',
    bool activeOnly = false,
  }) async => records
      .where((row) => !activeOnly || row.active)
      .where((row) => query.isEmpty || row.name.contains(query) || row.document.contains(query))
      .toList();

  @override
  Future<SupplierRecord> save(SupplierDraft draft, {int? id}) async {
    final row = SupplierRecord(
      id: id ?? _nextId++,
      name: draft.name,
      document: draft.document,
      active: draft.active,
      documentType: draft.documentType,
      phone: draft.phone,
      address: draft.address,
    );
    records.removeWhere((current) => current.id == row.id);
    records.add(row);
    return row;
  }
}

void main() {
  test('normalizes supplier before saving', () async {
    final gateway = _FakeGateway();
    final useCase = SupplierUseCase(gateway);
    final saved = await useCase.save(
      const SupplierDraft(
        name: '  Proveedor Uno ',
        document: ' 20123456789 ',
        phone: ' 999111222 ',
      ),
    );
    expect(saved.name, 'Proveedor Uno');
    expect(saved.document, '20123456789');
    expect(saved.phone, '999111222');
  });

  test('blocks duplicate supplier document', () async {
    final gateway = _FakeGateway();
    final useCase = SupplierUseCase(gateway);
    await useCase.save(const SupplierDraft(name: 'Uno', document: '123'));
    expect(
      () => useCase.save(const SupplierDraft(name: 'Dos', document: '123')),
      throwsStateError,
    );
  });

  test('deactivation keeps supplier record but removes it from active list', () async {
    final gateway = _FakeGateway();
    final useCase = SupplierUseCase(gateway);
    final saved = await useCase.save(const SupplierDraft(name: 'Uno', document: '123'));
    await useCase.deactivate(saved.id);
    expect(await useCase.list(), hasLength(1));
    expect(await useCase.list(activeOnly: true), isEmpty);
  });
}
