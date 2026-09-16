import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';
import 'package:mobile_app/app/providers/sync_providers.dart';
import 'package:mobile_app/platform/connectivity/connectivity_status_service.dart';

class BalanceService {
  static Future<void> sincronizarVentasOffline(
    BuildContext context,
    WidgetRef ref,
    VoidCallback onComplete,
  ) async {
    final hayInternet = await ConnectivityStatusService.hasInternet();
    if (!hayInternet) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No hay conexión a internet para sincronizar.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final pendientes = await OfflineService.obtenerVentasOffline();
    if (pendientes.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No tienes ventas pendientes. Todo al día. ✨'),
            backgroundColor: Colors.blue,
          ),
        );
      }
      return;
    }

    if (!context.mounted) return;

    final rootNavigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          const Center(child: CircularProgressIndicator(color: Colors.white)),
    );

    SyncPendingOperationsResult? result;
    Object? syncError;

    try {
      result = await ref.read(syncPendingOperationsProvider).execute();
    } catch (e, st) {
      syncError = e;
      debugPrint('BalanceService: synchronization failed: $e');
      debugPrintStack(stackTrace: st);
    } finally {
      if (rootNavigator.mounted && rootNavigator.canPop()) {
        rootNavigator.pop();
      }
    }

    if (!context.mounted) return;

    if (syncError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(syncError)),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (result?.outcome == PendingOperationsSyncOutcome.requireLogin ||
        result?.outcome ==
            PendingOperationsSyncOutcome.authorizationUnavailable ||
        (result?.outcome == PendingOperationsSyncOutcome.idle &&
            ref.read(supabaseProvider).auth.currentUser == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No se pudo autorizar la sincronización. '
            'Tus ventas siguen guardadas; verifica tu sesión e inténtalo de nuevo.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final pendingCount = result?.pendingCount ?? pendientes.length;
    if (result?.inventoryRefreshPending == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Las ventas confirmadas se guardaron. '
            'Falta actualizar la vista de inventario; vuelve a cargarla.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
    }
    if (pendingCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('¡Todas las ventas sincronizadas con éxito! 🚀'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 3),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Quedaron $pendingCount ventas pendientes. Intenta luego.',
          ),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
    }

    onComplete();
  }
}
