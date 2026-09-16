import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeGateway implements EmployeePermissionGateway {
  EmployeePermissionSettings? saved;
  Map<AppPermission, bool>? overrides;

  @override
  Future<EmployeePermissionSettings> load(int employeeId) async =>
      EmployeePermissionSettings(
        employeeId: employeeId,
        role: 'operador',
        permissions: const [
          EmployeePermissionSetting(
            permission: AppPermission.inventoryReceive,
            baseAllowed: true,
            allowed: true,
          ),
          EmployeePermissionSetting(
            permission: AppPermission.inventoryAdjust,
            baseAllowed: false,
            allowed: false,
          ),
        ],
      );

  @override
  Future<EmployeePermissionSettings> save(
    int employeeId,
    Map<AppPermission, bool> overrides,
  ) async {
    this.overrides = Map<AppPermission, bool>.from(overrides);
    saved = EmployeePermissionSettings(
      employeeId: employeeId,
      role: 'operador',
      permissions: [
        EmployeePermissionSetting(
          permission: AppPermission.inventoryReceive,
          baseAllowed: true,
          allowed: overrides[AppPermission.inventoryReceive] ?? true,
        ),
        const EmployeePermissionSetting(
          permission: AppPermission.inventoryAdjust,
          baseAllowed: false,
          allowed: false,
        ),
      ],
    );
    return saved!;
  }
}

void main() {
  test('allows removing a permission granted by the role', () async {
    final gateway = _FakeGateway();
    final useCase = ManageEmployeePermissionsUseCase(gateway);
    final current = await useCase.load(7);

    final result = await useCase.save(current, {
      AppPermission.inventoryReceive: false,
    });

    expect(gateway.overrides?[AppPermission.inventoryReceive], isFalse);
    expect(
      result.permissions
          .singleWhere(
            (row) => row.permission == AppPermission.inventoryReceive,
          )
          .allowed,
      isFalse,
    );
  });

  test('cannot elevate an operator outside its base role', () async {
    final gateway = _FakeGateway();
    final useCase = ManageEmployeePermissionsUseCase(gateway);
    final current = await useCase.load(8);

    expect(
      () => useCase.save(current, {AppPermission.inventoryAdjust: true}),
      throwsArgumentError,
    );
  });

  test('administrator permissions cannot be overridden', () {
    final gateway = _FakeGateway();
    final useCase = ManageEmployeePermissionsUseCase(gateway);
    final current = EmployeePermissionSettings(
      employeeId: 1,
      role: 'admin',
      permissions: const [
        EmployeePermissionSetting(
          permission: AppPermission.salesCreate,
          baseAllowed: true,
          allowed: true,
        ),
      ],
    );

    expect(
      () => useCase.save(current, {AppPermission.salesCreate: false}),
      throwsArgumentError,
    );
  });
}
