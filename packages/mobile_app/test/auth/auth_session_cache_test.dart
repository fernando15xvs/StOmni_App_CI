import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:core_logic/core_logic.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  List<AppPermission> permissionsFor(String role) =>
      RolePermissionPolicy.forRole(role).toList(growable: false);

  String snapshot({
    required String user,
    required String role,
    required String validatedAt,
  }) {
    return '{"schema_version":2,"auth_user_id":"$user","role":"$role",'
        '"validated_at":"$validatedAt","permissions":[]}';
  }

  test('restaura solo la autorización validada del mismo usuario', () async {
    await AuthSessionCache.saveValidatedSession(
      authUserId: 'user-a',
      role: 'admin',
      permissions: permissionsFor('admin'),
    );

    final own = await AuthSessionCache.loadForUser('user-a');
    final other = await AuthSessionCache.loadForUser('user-b');

    expect(own, isNotNull);
    expect(own!.authUserId, 'user-a');
    expect(own.role, 'admin');
    expect(own.validatedAt, isNotEmpty);
    expect(own.permissions, RolePermissionPolicy.forRole('admin'));
    expect(other, isNull);
  });

  test('normaliza rol válido antes de persistirlo', () async {
    await AuthSessionCache.saveValidatedSession(
      authUserId: ' user-a ',
      role: ' OPERADOR ',
      permissions: permissionsFor('operador'),
    );

    final snapshot = await AuthSessionCache.loadForUser('user-a');
    expect(snapshot, isNotNull);
    expect(snapshot!.role, 'operador');
  });

  test('snapshot v2 offline sigue vigente antes de 24 horas', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'auth_validated_session_v2': snapshot(
        user: 'user-a',
        role: 'admin',
        validatedAt: '2026-08-20T10:00:00Z',
      ),
    });

    final cached = await AuthSessionCache.loadForUser(
      'user-a',
      nowUtc: DateTime.parse('2026-08-21T09:59:59Z'),
    );

    expect(cached, isNotNull);
    expect(cached!.role, 'admin');
  });

  test('autorización offline expira al cumplir 24 horas', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'auth_validated_session_v2': snapshot(
        user: 'user-a',
        role: 'operador',
        validatedAt: '2026-08-20T10:00:00Z',
      ),
    });

    final cached = await AuthSessionCache.loadForUser(
      'user-a',
      nowUtc: DateTime.parse('2026-08-21T10:00:00Z'),
    );

    expect(cached, isNull);
  });

  test(
    'snapshot con timestamp significativamente futuro falla cerrado',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'auth_validated_session_v2': snapshot(
          user: 'user-a',
          role: 'admin',
          validatedAt: '2026-08-21T10:10:01Z',
        ),
      });

      final cached = await AuthSessionCache.loadForUser(
        'user-a',
        nowUtc: DateTime.parse('2026-08-21T10:00:00Z'),
      );

      expect(cached, isNull);
    },
  );

  test('pequeña diferencia futura de reloj se tolera', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'auth_validated_session_v2': snapshot(
        user: 'user-a',
        role: 'operador',
        validatedAt: '2026-08-21T10:04:00Z',
      ),
    });

    final cached = await AuthSessionCache.loadForUser(
      'user-a',
      nowUtc: DateTime.parse('2026-08-21T10:00:00Z'),
    );

    expect(cached, isNotNull);
  });

  test('snapshot sin fecha válida no concede acceso offline', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'auth_validated_session_v2': snapshot(
        user: 'user-a',
        role: 'admin',
        validatedAt: 'fecha-invalida',
      ),
    });

    expect(await AuthSessionCache.loadForUser('user-a'), isNull);
  });

  test('snapshot manipulado con rol no autorizado no concede acceso', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'auth_validated_session_v2': snapshot(
        user: 'user-a',
        role: 'vendedor',
        validatedAt: '2026-08-20T10:00:00Z',
      ),
    });

    expect(
      await AuthSessionCache.loadForUser(
        'user-a',
        nowUtc: DateTime.parse('2026-08-20T11:00:00Z'),
      ),
      isNull,
    );
  });

  test('snapshot legacy v1 no concede autorización offline', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'auth_validated_session_v1':
          '{"auth_user_id":"user-a","role":"admin","validated_at":"2026-08-20T10:00:00Z"}',
    });

    expect(
      await AuthSessionCache.loadForUser(
        'user-a',
        nowUtc: DateTime.parse('2026-08-20T11:00:00Z'),
      ),
      isNull,
    );
  });

  test('snapshot corrupto falla cerrado', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'auth_validated_session_v2': '{json-invalido',
    });

    expect(await AuthSessionCache.loadForUser('user-a'), isNull);
  });

  test('clear elimina la autorización offline', () async {
    await AuthSessionCache.saveValidatedSession(
      authUserId: 'user-a',
      role: 'operador',
      permissions: permissionsFor('operador'),
    );
    await AuthSessionCache.clear();

    expect(await AuthSessionCache.loadForUser('user-a'), isNull);
  });
}
