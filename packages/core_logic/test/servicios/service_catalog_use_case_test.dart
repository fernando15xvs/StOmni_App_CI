import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_operation_policy.dart';

class _ServiceGateway implements ServiceCatalogGateway {
  final rows = <ServiceRecord>[];
  int writes = 0;

  @override
  Future<List<ServiceRecord>> list({bool includeInactive = false}) async =>
      rows.where((row) => includeInactive || row.active).toList(growable: false);

  @override
  Future<ServiceRecord> save(ServiceDraft draft) async {
    writes++;
    final row = ServiceRecord(
      id: draft.serviceId ?? 1,
      code: draft.code,
      name: draft.name,
      description: draft.description,
      unitPrice: draft.unitPrice,
      purchasePrice: draft.purchasePrice,
      active: true,
    );
    rows.removeWhere((item) => item.id == row.id);
    rows.add(row);
    return row;
  }

  @override
  Future<void> deactivate(int serviceId) async {
    writes++;
  }
}

void main() {
  test('servicio habilitado normaliza y guarda con permisos de producto', () async {
    final profiles = TestBusinessProfiles()
      ..profile = const BusinessProfile(
        businessId: '1',
        displayName: 'Pruebas',
        capabilities: BusinessCapabilities(services: true),
        revision: 1,
        supportsCapabilitySettings: true,
      );
    final gateway = _ServiceGateway();
    final useCase = ServiceCatalogUseCase(
      gateway: gateway,
      businessProfile: profiles,
      authorizer: TestOperationAuthorizer(),
    );

    final saved = await useCase.save(const ServiceDraft(
      code: ' srv-01 ',
      name: ' Instalación ',
      unitPrice: 25,
    ));

    expect(saved.code, 'SRV-01');
    expect(saved.name, 'Instalación');
    expect(gateway.writes, 1);
  });

  test('servicios apagados fallan antes de escribir', () async {
    final gateway = _ServiceGateway();
    final useCase = ServiceCatalogUseCase(
      gateway: gateway,
      businessProfile: TestBusinessProfiles(),
      authorizer: TestOperationAuthorizer(),
    );

    await expectLater(
      useCase.save(const ServiceDraft(code: 'SRV', name: 'Servicio', unitPrice: 10)),
      throwsA(isA<UserFacingException>()),
    );
    expect(gateway.writes, 0);
  });
}
