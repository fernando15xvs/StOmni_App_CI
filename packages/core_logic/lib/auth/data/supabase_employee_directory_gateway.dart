import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/employee_directory_use_case.dart';

class SupabaseEmployeeDirectoryGateway implements EmployeeDirectoryGateway {
  const SupabaseEmployeeDirectoryGateway(this.client);

  final SupabaseClient client;

  @override
  Future<List<EmployeeDirectoryRecord>> list({
    bool includeInactive = true,
  }) async {
    var request = client
        .from('empleados')
        .select('id,nombre,rol,activo,email,cargo');
    if (!includeInactive) request = request.eq('activo', true);
    final rows = await request.order('nombre');
    return rows
        .map((raw) {
          final map = Map<String, dynamic>.from(raw);
          final rawId = map['id'];
          final id = rawId is num
              ? rawId.toInt()
              : int.tryParse(rawId?.toString() ?? '');
          final name = map['nombre']?.toString().trim() ?? '';
          final role = map['rol']?.toString().trim().toLowerCase() ?? '';
          if (id == null || id <= 0 || name.isEmpty || role.isEmpty) {
            throw const FormatException(
              'Empleado sin id, nombre o rol válido.',
            );
          }
          String? optional(Object? value) {
            final text = value?.toString().trim() ?? '';
            return text.isEmpty ? null : text;
          }

          return EmployeeDirectoryRecord(
            id: id,
            name: name,
            role: role,
            active: map['activo'] == true,
            email: optional(map['email']),
            position: optional(map['cargo']),
          );
        })
        .toList(growable: false);
  }
}
