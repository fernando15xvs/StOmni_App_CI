import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DesktopDashboardData {
  const DesktopDashboardData({
    required this.userName,
    required this.summary,
    this.configurableMetrics,
  });

  final String userName;
  final DashboardSummary summary;
  final ConfigurableDashboardSnapshot? configurableMetrics;
}

final desktopDashboardProvider = FutureProvider<DesktopDashboardData>((ref) async {
  final repository = ref.watch(dashboardRepositoryProvider);
  final metrics = ref.watch(configurableMetricsUseCaseProvider);
  final now = AppTime.now();
  final startToday = DateTime(now.year, now.month, now.day);
  final endExclusive = startToday.add(const Duration(days: 1));
  final startMetrics = now.subtract(const Duration(days: 30));

  ConfigurableDashboardSnapshot? configurableMetrics;
  try {
    configurableMetrics = await metrics.dashboard(start: startMetrics, end: now);
  } catch (_) {
    // El dashboard operativo base sigue disponible para roles sin reportes de utilidad.
    configurableMetrics = null;
  }

  final results = await Future.wait<dynamic>([
    repository.obtenerNombreUsuarioActual(),
    repository.obtenerResumenTipado(
      inicioIso: AppTime.toIsoLima(startToday),
      finIso: AppTime.toIsoLima(endExclusive),
    ),
  ]);

  return DesktopDashboardData(
    userName: results[0] as String,
    summary: results[1] as DashboardSummary,
    configurableMetrics: configurableMetrics,
  );
});
