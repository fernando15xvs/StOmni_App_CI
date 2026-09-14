import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final empleadoPagoContextRepositoryProvider =
    Provider<EmpleadoPagoContextRepository>((ref) {
      return EmpleadoPagoContextRepository(ref.read(supabaseProvider));
    });

class EmpleadoPagoContextRepository {
  EmpleadoPagoContextRepository(this._client);

  final SupabaseClient _client;

  Future<Map<String, dynamic>> obtenerEstadoCajaChica() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const UserFacingException(
        'Tu sesión ya no está disponible. Inicia sesión nuevamente.',
      );
    }

    try {
      final empleado = await _client
          .from('empleados')
          .select('rol')
          .eq('auth_id', user.id)
          .eq('activo', true)
          .maybeSingle();
      if (!AppRoles.isAdmin(empleado?['rol']?.toString())) {
        throw const UserFacingException(
          'Solo un administrador activo puede registrar pagos al personal.',
        );
      }

      final data = await _client.rpc('get_estado_caja_chica');
      if (data is! Map) {
        throw const UserFacingException(
          'No pudimos verificar el estado de Caja Chica.',
        );
      }
      return Map<String, dynamic>.from(data);
    } on UserFacingException {
      rethrow;
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }
}
