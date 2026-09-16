import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final empleadosRepositoryProvider = Provider<EmpleadosRepository>((ref) {
  return EmpleadosRepository(ref.read(supabaseProvider));
});

class EmpleadosRepository {
  final SupabaseClient _client;

  EmpleadosRepository(this._client);

  Future<void> _requireAdmin() async {
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
          'Solo un administrador activo puede gestionar el personal.',
        );
      }
    } on UserFacingException {
      rethrow;
    } catch (e) {
      if (ErrorMapper.isConnectionError(e)) {
        throw const UserFacingException(ErrorMapper.connectionMessage);
      }
      throw const UserFacingException(
        'No pudimos verificar tus permisos. Inténtalo nuevamente.',
      );
    }
  }

  String _normalizarRol(dynamic raw) {
    final rol = AppRoles.normalize(raw?.toString());
    if (rol == null) {
      throw const UserFacingException(
        'El rol seleccionado no es válido. Usa Administrador u Operador.',
      );
    }
    return rol;
  }

  UserFacingException _errorCreacionAcceso(Object error) {
    if (ErrorMapper.isConnectionError(error)) {
      return const UserFacingException(ErrorMapper.connectionMessage);
    }

    final text = error.toString().toLowerCase();
    if (text.contains('already registered') ||
        text.contains('already exists') ||
        text.contains('duplicate') ||
        text.contains('correo') && text.contains('registr')) {
      return const UserFacingException(
        'Ese correo ya está asociado a un acceso existente.',
      );
    }

    return const UserFacingException(
      'No pudimos crear el acceso del empleado. Inténtalo nuevamente.',
    );
  }

  Future<List<dynamic>> obtenerEmpleados() async {
    await _requireAdmin();
    return _client.from('empleados').select().order('nombre');
  }

  Future<String?> guardarEmpleado(
    Map<String, dynamic> data, {
    bool isEdit = false,
  }) async {
    await _requireAdmin();
    final rol = _normalizarRol(data['rol']);

    if (isEdit) {
      await _client
          .from('empleados')
          .update({
            'nombre': data['nombre'],
            'cargo': data['cargo'],
            'telefono': data['telefono'],
            'rol': rol,
            'fecha_actualizacion': AppTime.nowIso(),
          })
          .eq('id', data['id']);
      return null;
    }

    final email = data['email']?.toString();
    final nombre = data['nombre']?.toString();

    String? generatedPassword;
    if (email != null && email.isNotEmpty) {
      generatedPassword = AuthUtils.generateSecurePassword();
    }

    data['rol'] = rol;
    data['creado_por'] = _client.auth.currentUser?.id;
    data['fecha_actualizacion'] = AppTime.toIsoLima(AppTime.now());

    if (email != null && email.isNotEmpty && generatedPassword != null) {
      try {
        final res = await _client.functions
            .invoke(
              'create_employee',
              body: {
                'email': email,
                'nombre': nombre,
                'password': generatedPassword,
                'empleado_data': data,
              },
            )
            .timeout(const Duration(seconds: 15));

        final responseData = res.data;
        if (responseData != null && responseData['password'] != null) {
          return responseData['password'] as String;
        }
        return generatedPassword;
      } catch (e) {
        try {
          final checkEmpleado = await _client
              .from('empleados')
              .select('auth_id')
              .eq('email', email)
              .maybeSingle();

          if (checkEmpleado != null && checkEmpleado['auth_id'] != null) {
            return generatedPassword;
          }
        } catch (_) {
          // La comprobación best-effort no reemplaza el error original.
        }

        throw _errorCreacionAcceso(e);
      }
    }

    await _client.from('empleados').insert(data);
    return null;
  }

  Future<void> darDeBajaEmpleado(int empleadoId) async {
    await _requireAdmin();
    await _client
        .from('empleados')
        .update({
          'activo': false,
          'eliminado_por': _client.auth.currentUser?.id,
          'fecha_eliminacion': AppTime.nowIso(),
          'fecha_actualizacion': AppTime.nowIso(),
        })
        .eq('id', empleadoId);
  }

  Future<void> reactivarEmpleado(int empleadoId) async {
    await _requireAdmin();
    await _client
        .from('empleados')
        .update({'activo': true, 'fecha_actualizacion': AppTime.nowIso()})
        .eq('id', empleadoId);
  }

  Future<double> calcularAdelantosPendientes(int empleadoId) async {
    await _requireAdmin();
    final ultimoSueldo = await _client
        .from('pagos_empleados')
        .select('fecha')
        .eq('empleado_id', empleadoId)
        .ilike('concepto', '%sueldo%')
        .order('fecha', ascending: false)
        .limit(1)
        .maybeSingle();

    final String fechaCorte = ultimoSueldo != null
        ? ultimoSueldo['fecha']
        : AppTime.toIsoLima(AppTime.now().subtract(const Duration(days: 30)));

    final data = await _client
        .from('pagos_empleados')
        .select('monto')
        .eq('empleado_id', empleadoId)
        .ilike('concepto', '%adelanto%')
        .gt('fecha', fechaCorte);

    var total = 0.0;
    for (final a in data) {
      total += (a['monto'] as num).toDouble();
    }
    return total;
  }

  Future<void> registrarPagoEmpleadoMixto({
    required int empleadoId,
    required String concepto,
    required String fechaIso,
    required List<Map<String, dynamic>> pagos,
  }) async {
    await _requireAdmin();
    await _client.rpc(
      'registrar_pago_empleado_mixto',
      params: {
        'p_empleado_id': empleadoId,
        'p_concepto': concepto,
        'p_fecha': fechaIso,
        'p_pagos_json': pagos,
      },
    );
  }

  Future<List<Map<String, dynamic>>> obtenerHistorialPagos({
    int? empleadoId,
    DateTime? fechaInicio,
    DateTime? fechaFin,
    int offset = 0,
    int limit = 20,
  }) async {
    await _requireAdmin();
    var query = _client
        .from('pagos_empleados')
        .select('*, empleados(nombre, cargo, rol)');

    if (empleadoId != null) {
      query = query.eq('empleado_id', empleadoId);
    }
    if (fechaInicio != null) {
      query = query.gte('fecha', AppTime.toIsoLima(fechaInicio));
    }
    if (fechaFin != null) {
      final finDia = DateTime(
        fechaFin.year,
        fechaFin.month,
        fechaFin.day,
        23,
        59,
        59,
      );
      query = query.lte('fecha', AppTime.toIsoLima(finDia));
    }

    return query
        .order('fecha', ascending: false)
        .range(offset, offset + limit - 1);
  }

  Future<List<Map<String, dynamic>>> obtenerHistorialPagosParaPdf({
    int? empleadoId,
    DateTime? fechaInicio,
    DateTime? fechaFin,
  }) async {
    await _requireAdmin();
    var query = _client
        .from('pagos_empleados')
        .select('*, empleados(nombre, cargo, rol)');

    if (empleadoId != null) {
      query = query.eq('empleado_id', empleadoId);
    }
    if (fechaInicio != null) {
      query = query.gte('fecha', AppTime.toIsoLima(fechaInicio));
    }
    if (fechaFin != null) {
      final finDia = DateTime(
        fechaFin.year,
        fechaFin.month,
        fechaFin.day,
        23,
        59,
        59,
      );
      query = query.lte('fecha', AppTime.toIsoLima(finDia));
    }

    return query.order('fecha', ascending: false);
  }

  Future<double> obtenerTotalHistorialPagos({
    int? empleadoId,
    DateTime? fechaInicio,
    DateTime? fechaFin,
  }) async {
    await _requireAdmin();
    var query = _client.from('pagos_empleados').select('monto');

    if (empleadoId != null) {
      query = query.eq('empleado_id', empleadoId);
    }
    if (fechaInicio != null) {
      query = query.gte('fecha', AppTime.toIsoLima(fechaInicio));
    }
    if (fechaFin != null) {
      final finDia = DateTime(
        fechaFin.year,
        fechaFin.month,
        fechaFin.day,
        23,
        59,
        59,
      );
      query = query.lte('fecha', AppTime.toIsoLima(finDia));
    }

    final result = await query;
    var total = 0.0;
    for (final p in result) {
      total += (p['monto'] as num).toDouble();
    }
    return total;
  }

  Future<Map<String, dynamic>> obtenerDetallePago(int pagoId) async {
    await _requireAdmin();
    return _client
        .from('pagos_empleados')
        .select('*, empleados(*)')
        .eq('id', pagoId)
        .single();
  }

  Future<void> eliminarPagoEmpleado(int pagoId) async {
    await _requireAdmin();
    await _client.rpc(
      'eliminar_pago_empleado_v1',
      params: {'p_pago_id': pagoId},
    );
  }

  Future<String?> crearAccesoEmpleado(
    int empleadoId,
    String email,
    String nombre,
  ) async {
    await _requireAdmin();
    final generatedPassword = AuthUtils.generateSecurePassword();
    try {
      final res = await _client.functions
          .invoke(
            'create_employee',
            body: {
              'email': email,
              'nombre': nombre,
              'password': generatedPassword,
            },
          )
          .timeout(const Duration(seconds: 15));

      final responseData = res.data;
      if (responseData != null && responseData['password'] != null) {
        return responseData['password'] as String;
      }
      return generatedPassword;
    } catch (e) {
      try {
        final checkEmpleado = await _client
            .from('empleados')
            .select('auth_id')
            .eq('id', empleadoId)
            .maybeSingle();

        if (checkEmpleado != null && checkEmpleado['auth_id'] != null) {
          return generatedPassword;
        }
      } catch (_) {
        // La comprobación best-effort no reemplaza el error original.
      }
      throw _errorCreacionAcceso(e);
    }
  }

  Future<void> eliminarEmpleadoDefinitivamente(int empleadoId) async {
    await _requireAdmin();
    try {
      await _client.functions
          .invoke('delete_employee', body: {'empleado_id': empleadoId})
          .timeout(const Duration(seconds: 15));
    } on FunctionException catch (e) {
      final detail = e.details?.toString().toLowerCase() ?? '';
      if (detail.contains('historical_records_exist')) {
        throw const UserFacingException(
          'El empleado tiene historial y no puede eliminarse definitivamente. Usa "Dar de baja" para conservar sus registros.',
        );
      }
      if (detail.contains('cannot_delete_self') ||
          detail.contains('propio') && detail.contains('eliminar')) {
        throw const UserFacingException(
          'No puedes eliminar definitivamente tu propio usuario.',
        );
      }
      throw UserFacingException(ErrorMapper.map(e));
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }
}
