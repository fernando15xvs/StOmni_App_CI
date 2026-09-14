import 'app_permission.dart';

class EmployeePermissionSetting {
  const EmployeePermissionSetting({
    required this.permission,
    required this.baseAllowed,
    required this.allowed,
  });

  final AppPermission permission;
  final bool baseAllowed;
  final bool allowed;

  bool get canBeGranted => baseAllowed;
}

class EmployeePermissionSettings {
  EmployeePermissionSettings({
    required this.employeeId,
    required this.role,
    required Iterable<EmployeePermissionSetting> permissions,
  }) : permissions = List<EmployeePermissionSetting>.unmodifiable(permissions);

  final int employeeId;
  final String role;
  final List<EmployeePermissionSetting> permissions;

  bool get isAdministrator => role == 'admin' || role == 'administrador';
}
