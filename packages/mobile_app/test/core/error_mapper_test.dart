import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

void main() {
  test('detecta timeout como error de conexión', () {
    final error = TimeoutException('La operación tardó demasiado');

    expect(ErrorMapper.isConnectionError(error), isTrue);
    expect(ErrorMapper.map(error), ErrorMapper.connectionMessage);
  });

  test('detecta errores de socket, cliente, DNS y fetch', () {
    final errors = <Object>[
      Exception('SocketException: Failed host lookup'),
      Exception('ClientException: connection closed before full header'),
      Exception('TypeError: Failed to fetch'),
      Exception('Network is unreachable'),
      Exception('Software caused connection abort'),
      Exception('503 Service Unavailable'),
    ];

    for (final error in errors) {
      expect(
        ErrorMapper.isConnectionError(error),
        isTrue,
        reason: error.toString(),
      );
      expect(ErrorMapper.map(error), ErrorMapper.connectionMessage);
    }
  });

  test('credenciales inválidas conservan mensaje específico', () {
    final error = AuthException('Invalid login credentials');

    expect(ErrorMapper.isConnectionError(error), isFalse);
    expect(ErrorMapper.map(error), 'Correo o contraseña incorrectos.');
  });

  test('UserFacingException conserva solo el mensaje aprobado para UI', () {
    const error = UserFacingException(
      'Solo un administrador activo puede gestionar el personal.',
    );

    expect(
      ErrorMapper.map(error),
      'Solo un administrador activo puede gestionar el personal.',
    );
    expect(error.toString(), isNot(contains('Exception:')));
  });

  test('caja cerrada se traduce sin exponer PostgREST', () {
    final error = Exception(
      'PostgrestException(message: La caja está cerrada. SQLSTATE P0001)',
    );

    final message = ErrorMapper.map(error);

    expect(
      message,
      'La caja está cerrada. Ábrela primero desde Caja Chica para continuar.',
    );
    expect(message.toLowerCase(), isNot(contains('postgrest')));
    expect(message.toLowerCase(), isNot(contains('sqlstate')));
  });

  test('saldo insuficiente de caja se traduce como regla de negocio', () {
    final error = Exception(
      'PostgrestException(message: Saldo insuficiente en Caja Chica. Disponible: S/ 5)',
    );

    final message = ErrorMapper.map(error);

    expect(
      message,
      'No hay saldo suficiente en Caja Chica para completar esta operación.',
    );
    expect(message, isNot(contains('S/ 5')));
  });

  test('error desconocido no expone texto técnico', () {
    final error = Exception('detalle interno muy técnico');

    expect(ErrorMapper.map(error), isNot(contains('detalle interno')));
    expect(
      ErrorMapper.map(error),
      'Ocurrió un problema inesperado. Inténtalo nuevamente.',
    );
  });
}
