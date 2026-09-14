import '../domain/app_permission.dart';
import '../domain/employee_permission_settings.dart';

abstract interface class EmployeePermissionGateway {
  Future<EmployeePermissionSettings> load(int employeeId);
  Future<EmployeePermissionSettings> save(
    int employeeId,
    Map<AppPermission, bool> overrides,
  );
}

class ManageEmployeePermissionsUseCase {
  const ManageEmployeePermissionsUseCase(this._gateway);
  final EmployeePermissionGateway _gateway;

  Future<EmployeePermissionSettings> load(int employeeId) {
    if (employeeId <= 0) throw ArgumentError('Empleado inválido.');
    return _gateway.load(employeeId);
  }

  Future<EmployeePermissionSettings> save(
    EmployeePermissionSettings current,
    Map<AppPermission, bool> requested,
  ) {
    if (current.isAdministrator) {
      throw ArgumentError('Los permisos del administrador se derivan de su rol.');
    }
    final known = {for (final row in current.permissions) row.permission: row};
    final normalized = <AppPermission, bool>{};
    for (final entry in requested.entries) {
      final setting = known[entry.key];
      if (setting == null) {
        throw ArgumentError('Permiso no reconocido para este empleado.');
      }
      if (entry.value && !setting.canBeGranted) {
        throw ArgumentError('El rol no permite conceder ${entry.key.code}.');
      }
      normalized[entry.key] = entry.value;
    }
    return _gateway.save(current.employeeId, normalized);
  }
}
