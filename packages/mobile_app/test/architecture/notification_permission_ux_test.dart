import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String bootstrap;
  late String permissionService;
  late String preferences;
  late String navigation;

  setUpAll(() {
    bootstrap = File('lib/app/bootstrap.dart').readAsStringSync();
    permissionService = File(
      'lib/platform/notifications/notification_permission_service.dart',
    ).readAsStringSync();
    preferences = File(
      '../core_logic/lib/services/preferences_service.dart',
    ).readAsStringSync();
    navigation = File(
      'lib/app/notification_navigation.dart',
    ).readAsStringSync();
  });

  test('bootstrap configura OneSignal sin abrir el permiso del sistema', () {
    expect(bootstrap, contains('OneSignal.initialize('));
    expect(
      bootstrap,
      contains('NotificationPermissionService.isSupportedPlatform'),
    );
    expect(bootstrap, isNot(contains('Notifications.requestPermission(')));
  });

  test('permiso móvil se solicita solo tras una explicación visible', () {
    expect(permissionService, contains('Alertas importantes de inventario'));
    expect(permissionService, contains('Activar notificaciones'));
    expect(
      permissionService,
      contains('Notifications.requestPermission(true)'),
    );
    expect(permissionService, contains('TargetPlatform.android'));
    expect(permissionService, contains('TargetPlatform.iOS'));
    expect(permissionService, contains('if (kIsWeb) return false'));
  });

  test('la explicación no se repite automáticamente', () {
    expect(preferences, contains('notificationPermissionExplanationSeen'));
    expect(
      permissionService,
      contains('PreferencesService.notificationPermissionExplanationSeen'),
    );
    expect(
      permissionService,
      contains('setNotificationPermissionExplanationSeen(true)'),
    );
  });

  test('la explicación ocurre cuando Home ya está autorizado', () {
    expect(
      navigation,
      contains('NotificationPermissionService.maybeExplainAndRequest(context)'),
    );
    expect(navigation, contains('if (widget.enabled && !_openingStockAlert)'));
  });

  test('core_logic ya no contiene la UI de permisos de notificación', () {
    expect(
      File('../core_logic/lib/services/notification_permission_service.dart')
          .existsSync(),
      isFalse,
    );
    expect(
      permissionService,
      contains("package:core_logic/core_logic.dart' show PreferencesService"),
    );
  });
}
