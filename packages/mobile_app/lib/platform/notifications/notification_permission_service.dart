import 'package:core_logic/core_logic.dart' show PreferencesService;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';

/// Adaptador exclusivamente móvil para explicar y solicitar permisos push.
///
/// Las decisiones visuales (dialog, BuildContext) y la API de OneSignal viven
/// aquí para que `core_logic` no dependa de UI ni de una plataforma concreta.
class NotificationPermissionService {
  const NotificationPermissionService._();

  static bool _dialogInFlight = false;

  static bool get isSupportedPlatform {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  static Future<void> maybeExplainAndRequest(BuildContext context) async {
    if (!isSupportedPlatform ||
        PreferencesService.notificationPermissionExplanationSeen ||
        _dialogInFlight) {
      return;
    }

    _dialogInFlight = true;
    try {
      if (!context.mounted) return;

      final activate = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.notifications_active_outlined),
          title: const Text('Alertas importantes de inventario'),
          content: const Text(
            'StOmni puede avisarte cuando un producto quede con stock bajo o se agote. '
            'Puedes seguir usando la aplicación aunque no actives las notificaciones.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Ahora no'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Activar notificaciones'),
            ),
          ],
        ),
      );

      await PreferencesService.setNotificationPermissionExplanationSeen(true);

      if (activate != true) return;

      try {
        await OneSignal.Notifications.requestPermission(true);
      } catch (e, st) {
        debugPrint('No se pudo solicitar permiso de notificaciones: $e');
        if (kDebugMode) debugPrintStack(stackTrace: st);
      }
    } finally {
      _dialogInFlight = false;
    }
  }
}
