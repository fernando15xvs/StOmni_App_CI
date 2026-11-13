import 'package:core_logic/features/ventas/data/tenant_venta_context_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const orgA = '00000000-0000-0000-0000-000000000021';
  const orgB = '00000000-0000-0000-0000-000000000022';

  test('accepts server customer row for the selected organization', () {
    final row = TenantVentaContextRepository.requireOwnRow(
      {'id': 15, 'organization_id': orgA},
      organizationId: orgA,
    );
    expect(row['id'], 15);
    expect(row['organization_id'], orgA);
  });

  test('rejects foreign customer even when its numeric id exists', () {
    expect(
      () => TenantVentaContextRepository.requireOwnRow(
        {'id': 15, 'organization_id': orgB},
        organizationId: orgA,
      ),
      throwsStateError,
    );
  });

  test('rejects response without a verifiable organization', () {
    expect(
      () => TenantVentaContextRepository.requireOwnRow(
        {'id': 15},
        organizationId: orgA,
      ),
      throwsStateError,
    );
  });

  test('rejects unknown, empty or nonnumeric row ids', () {
    for (final invalidId in [null, 0, -1, '15']) {
      expect(
        () => TenantVentaContextRepository.requireOwnRow(
          {'id': invalidId, 'organization_id': orgA},
          organizationId: orgA,
        ),
        throwsStateError,
      );
    }
  });

  test('rejects malformed response instead of defaulting tenant', () {
    for (final invalidRow in [null, [], 'untrusted']) {
      expect(
        () => TenantVentaContextRepository.requireOwnRow(
          invalidRow,
          organizationId: orgA,
        ),
        throwsFormatException,
      );
    }
  });

  test('a selected tenant cannot be guessed from returned data', () {
    final a = TenantVentaContextRepository.requireOwnRow(
      {'id': 41, 'organization_id': orgA},
      organizationId: orgA,
    );
    final b = TenantVentaContextRepository.requireOwnRow(
      {'id': 42, 'organization_id': orgB},
      organizationId: orgB,
    );
    expect(a['organization_id'], isNot(b['organization_id']));
  });
}
