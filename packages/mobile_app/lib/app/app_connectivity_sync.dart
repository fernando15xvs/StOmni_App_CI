import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/pages/login_page.dart';
import '../platform/connectivity/connectivity_sync_controller.dart';
import 'app_router.dart';

/// Presenta el resultado de la sincronización automática mediante navegación
/// y mensajes móviles. No contiene reglas de autenticación ni de la cola.
class AppConnectivitySync extends ConsumerStatefulWidget {
  const AppConnectivitySync({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AppConnectivitySync> createState() =>
      _AppConnectivitySyncState();
}

class _AppConnectivitySyncState extends ConsumerState<AppConnectivitySync> {
  @override
  Widget build(BuildContext context) {
    ref.listen<ConnectivitySyncState>(connectivitySyncControllerProvider, (
      previous,
      next,
    ) {
      if (next.type == SyncResultType.requireLogin) {
        _redirectToLogin();
      } else if (next.type == SyncResultType.error ||
          next.type == SyncResultType.partial) {
        _showConnectionMessage(next.message ?? 'Error de conectividad');
      } else if (next.type == SyncResultType.success) {
        debugPrint('Sync automático offline completado');
        if (next.message != null) _showConnectionMessage(next.message!);
      }
    });

    return widget.child;
  }

  void _redirectToLogin() {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;
    navigator.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  void _showConnectionMessage(String message) {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.orange,
        duration: const Duration(seconds: 5),
      ),
    );
  }
}
