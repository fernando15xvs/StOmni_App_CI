import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'pending_sale_queue_store.dart';

/// Audit-only gate for historic offline tickets without trustworthy tenant
/// provenance. The old queue cannot be silently moved to the selected tenant.
///
/// I3 must consult this before ever enabling real multi-company switching.
/// This class never deletes, migrates, retries or publishes historical sales.
final class LegacyPendingSaleQuarantine {
  const LegacyPendingSaleQuarantine(this.legacyQueue);

  final PendingSaleQueueStore legacyQueue;

  static const String historicalPreferencesKey = 'ventas_pendientes';

  Future<LegacyPendingSaleStatus> inspect() async {
    final sqliteCount = await legacyQueue.count();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(historicalPreferencesKey);
    var preferencesCount = 0;
    var malformed = false;

    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          preferencesCount = decoded.length;
        } else {
          malformed = true;
        }
      } catch (_) {
        malformed = true;
      }
    }

    return LegacyPendingSaleStatus(
      sqliteCount: sqliteCount,
      preferencesCount: preferencesCount,
      malformedHistoricalPayload: malformed,
    );
  }

  Future<void> requireNoUnattributedTickets() async {
    LegacyPendingSaleStatus status;
    try {
      status = await inspect();
    } catch (_) {
      throw StateError('No se pudo verificar la cola offline histórica.');
    }
    if (!status.safeToSwitch) {
      throw StateError(
        'Existen ventas históricas pendientes sin empresa verificada. '
        'No se puede habilitar el cambio de empresa.',
      );
    }
  }
}

final class LegacyPendingSaleStatus {
  const LegacyPendingSaleStatus({
    required this.sqliteCount,
    required this.preferencesCount,
    required this.malformedHistoricalPayload,
  });

  final int sqliteCount;
  final int preferencesCount;
  final bool malformedHistoricalPayload;

  bool get safeToSwitch =>
      sqliteCount == 0 && preferencesCount == 0 && !malformedHistoricalPayload;
}
