import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';
import '../../features/almacen/presentation/controllers/almacen_controller.dart';
import 'grafico_tendencia_provider.dart';
import 'prefetch_providers.dart';

/// Coordina la precarga compartida de los módulos principales de Home.
///
/// Se usa tanto después de un login manual como durante el Splash cuando ya
/// existe una sesión válida. Al vivir detrás de un Provider, el trabajo puede
/// terminar aunque el widget que lo inició cambie de ruta, sin conservar un
/// WidgetRef de una pantalla ya desmontada.
final homeWarmupCoordinatorProvider = Provider<HomeWarmupCoordinator>((ref) {
  return HomeWarmupCoordinator(ref);
});

class HomeWarmupCoordinator {
  HomeWarmupCoordinator(this._ref);

  final Ref _ref;

  /// Elimina snapshots compartidos de una sesión anterior.
  ///
  /// Debe invocarse fuera de build/initState. Los consumidores actuales lo
  /// hacen desde un post-frame callback o desde una rutina iniciada después
  /// del primer frame del Splash.
  void clearSessionCaches() {
    _ref.read(almacenesCacheProvider.notifier).state = null;
    _ref.read(balanceCacheProvider.notifier).state = null;
  }

  Future<void> warmUp() async {
    final repoBalance = _ref.read(balanceRepositoryProvider);
    final hoyInicio = AppTime.startOfToday();
    final hoyFin = AppTime.endOfToday();

    await Future.wait<void>([
      _ignoreFailure(_ref.read(almacenNotifierProvider.future)),
      _ignoreFailure(
        _ref.read(
          graficoTendenciaProvider(TendenciaRequest('ingreso', 7)).future,
        ),
      ),
      _ignoreFailure(
        _ref.read(
          graficoTendenciaProvider(TendenciaRequest('egreso', 7)).future,
        ),
      ),
      // Mover Stock: deja una lista fresca de almacenes lista para consumir.
      _ignoreFailure(() async {
        final data = await _ref
            .read(almacenRepositoryProvider)
            .obtenerAlmacenesDirecto();
        _ref.read(almacenesCacheProvider.notifier).state =
            List<Map<String, dynamic>>.from(data);
      }()),
      // Balance y Movimientos comparten el mismo snapshot inicial del día.
      _ignoreFailure(() async {
        final futures = await Future.wait([
          repoBalance.getDashboardSummary(hoyInicio, hoyFin),
          repoBalance.getMovimientos('ingreso', hoyInicio, hoyFin),
          repoBalance.getMovimientos('egreso', hoyInicio, hoyFin),
          repoBalance.getVentasParaDescuento(hoyInicio, hoyFin),
        ]);

        _ref.read(balanceCacheProvider.notifier).state = {
          'resumen': futures[0],
          'ingresos': futures[1],
          'egresos': futures[2],
          'ventas': futures[3],
          'fecha_inicio': hoyInicio.toIso8601String(),
        };
      }()),
    ]);
  }

  Future<void> _ignoreFailure(Future<dynamic> future) async {
    try {
      await future;
    } catch (_) {
      // El warm-up es una optimización. Cada módulo mantiene su propio estado,
      // manejo de errores y reintento si una consulta no está disponible.
    }
  }
}
