import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/manage_employee_permissions_use_case.dart';
import '../domain/app_permission.dart';
import '../domain/employee_permission_settings.dart';

class SupabaseEmployeePermissionGateway implements EmployeePermissionGateway {
  const SupabaseEmployeePermissionGateway(this.client);
  final SupabaseClient client;

  EmployeePermissionSettings _decode(dynamic raw) {
    if (raw is! Map) {
      throw const FormatException(
        'Respuesta de permisos de empleado inválida.',
      );
    }
    final map = Map<String, dynamic>.from(raw);
    final employeeId = (map['employee_id'] as num?)?.toInt();
    final role = map['role']?.toString().trim().toLowerCase() ?? '';
    final permissionMap = map['permissions'];
    if (employeeId == null ||
        employeeId <= 0 ||
        role.isEmpty ||
        permissionMap is! Map) {
      throw const FormatException('Contrato de permisos de empleado inválido.');
    }

    final rows = <EmployeePermissionSetting>[];
    for (final permission in AppPermission.values) {
      final rawSetting = permissionMap[permission.code];
      if (rawSetting is! Map) {
        throw FormatException('Falta el permiso ${permission.code}.');
      }
      final setting = Map<String, dynamic>.from(rawSetting);
      if (setting['base_allowed'] is! bool || setting['allowed'] is! bool) {
        throw FormatException('Estado inválido para ${permission.code}.');
      }
      rows.add(
        EmployeePermissionSetting(
          permission: permission,
          baseAllowed: setting['base_allowed'] as bool,
          allowed: setting['allowed'] as bool,
        ),
      );
    }
    return EmployeePermissionSettings(
      employeeId: employeeId,
      role: role,
      permissions: rows,
    );
  }

  @override
  Future<EmployeePermissionSettings> load(int employeeId) async {
    final raw = await client.rpc(
      'get_employee_permission_settings_v1',
      params: {'p_employee_id': employeeId},
    );
    return _decode(raw);
  }

  @override
  Future<EmployeePermissionSettings> save(
    int employeeId,
    Map<AppPermission, bool> overrides,
  ) async {
    final raw = await client.rpc(
      'update_employee_permission_overrides_v1',
      params: {
        'p_employee_id': employeeId,
        'p_overrides': {
          for (final entry in overrides.entries) entry.key.code: entry.value,
        },
      },
    );
    return _decode(raw);
  }
}
