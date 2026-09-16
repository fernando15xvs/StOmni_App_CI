import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import '../errors/user_facing_exception.dart';
export '../errors/user_facing_exception.dart';

/// Traduce errores de negocio y transporte sin exponer detalles internos.
class ErrorMapper {
  static const String connectionMessage =
      'No pudimos conectarnos al servidor. Revisa tu conexión a Internet e '
      'inténtalo nuevamente.';

  /// Detecta los errores de conectividad más comunes emitidos por Dart, HTTP,
  /// Supabase Auth, PostgREST, Storage y Edge Functions sin acoplar la UI a
  /// clases específicas de cada transporte.
  static bool isConnectionError(Object? error) {
    if (error == null) return false;
    if (error is TimeoutException) return true;

    final text = error.toString().toLowerCase();
    const markers = <String>[
      'socketexception',
      'clientexception',
      'handshakeexception',
      'httpexception',
      'failed host lookup',
      'failed to fetch',
      'xmlhttprequest error',
      'network is unreachable',
      'network error',
      'network request failed',
      'connection refused',
      'connection reset',
      'connection closed',
      'connection abort',
      'connection aborted',
      'software caused connection abort',
      'host lookup',
      'dns error',
      'timed out',
      'timeout',
      'send request failed',
      'failed to send a request',
      'statuscode: 0',
      'status code: 0',
      '502 bad gateway',
      '503 service unavailable',
      '504 gateway timeout',
    ];

    return markers.any(text.contains);
  }

  /// Traduce errores técnicos a mensajes aptos para mostrar al usuario.
  static String map(dynamic error) {
    if (error is UserFacingException) return error.message;
    if (isConnectionError(error)) return connectionMessage;

    if (error is AuthException) {
      final msg = error.message.toLowerCase();

      if (msg.contains('invalid login credentials')) {
        return 'Correo o contraseña incorrectos.';
      }
      if (msg.contains('user already registered')) {
        return 'Este correo ya está registrado en el sistema.';
      }
      if (msg.contains('email format')) {
        return 'El formato del correo es inválido.';
      }
      if (msg.contains('password should be at least')) {
        return 'La contraseña debe tener al menos 6 caracteres.';
      }
      if (msg.contains('database error')) {
        return 'El servidor tuvo un problema temporal. Inténtalo nuevamente en unos momentos.';
      }
      return 'No pudimos completar la autenticación. Inténtalo nuevamente.';
    }

    final text = error.toString().toLowerCase();

    // Reglas de negocio conocidas que pueden llegar encapsuladas por PostgREST.
    // Se traducen aquí para que ninguna pantalla inspeccione ni muestre el error
    // técnico completo recibido desde PostgreSQL.
    if (text.contains('caja está cerrada') ||
        text.contains('caja esta cerrada')) {
      return 'La caja está cerrada. Ábrela primero desde Caja Chica para continuar.';
    }
    if (text.contains('saldo insuficiente en caja chica')) {
      return 'No hay saldo suficiente en Caja Chica para completar esta operación.';
    }

    if (text.contains('database') || text.contains('postgrest')) {
      return 'El servidor no pudo completar la operación. Inténtalo nuevamente.';
    }

    return 'Ocurrió un problema inesperado. Inténtalo nuevamente.';
  }
}
