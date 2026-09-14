import 'package:mobile_app/platform/connectivity/connectivity_status_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';

import 'package:core_logic/core_logic.dart';
import '../../controllers/grafico_tendencia_provider.dart';

class DashboardCharts extends ConsumerWidget {
  final String titulo;
  final int diasFiltro;
  final bool isEgreso;
  final Function(int) onFiltroChanged;
  final Color colorPrincipal;

  const DashboardCharts({
    super.key,
    required this.titulo,
    required this.diasFiltro,
    required this.isEgreso,
    required this.onFiltroChanged,
    required this.colorPrincipal,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final req = TendenciaRequest(isEgreso ? 'egreso' : 'ingreso', diasFiltro);
    final asyncValue = ref.watch(graficoTendenciaProvider(req));

    return asyncValue.when(
      data: (data) => _buildSeccionGrafico(
        context,
        titulo: titulo,
        total: data.totalActual,
        variacion: data.variacion,
        diasFiltro: diasFiltro,
        spots: data.spots,
        fechas: data.fechas,
        isEgreso: isEgreso,
        onFiltroChanged: onFiltroChanged,
      ),
      loading: () => Container(
        height: 280,
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: _decoracionNeumorfica(context),
        alignment: Alignment.center,
        child: const CircularProgressIndicator(),
      ),
      error: (error, stack) => _buildGraficoErrorState(
        context,
        error: error,
        onRetry: () {
          _reintentarGrafico(context, ref, req);
        },
      ),
    );
  }

  Future<void> _reintentarGrafico(
      BuildContext context, WidgetRef ref, TendenciaRequest req) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: Colors.white,
              ),
            ),
            SizedBox(width: 12),
            Expanded(child: Text('Comprobando conexión y actualizando…')),
          ],
        ),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );

    final hayRed = await ConnectivityStatusService.hasInternet();
    if (!context.mounted) return;

    if (!hayRed) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Sigues sin conexión. Comprueba tu Internet y vuelve a intentarlo.',
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    ref.invalidate(graficoTendenciaProvider(req));

    try {
      await ref.read(graficoTendenciaProvider(req).future);
      if (!context.mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Gráfico actualizado.'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.green,
          duration: Duration(milliseconds: 1200),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            ErrorMapper.isConnectionError(e)
                ? 'No pudimos actualizar. Comprueba tu conexión a Internet e inténtalo nuevamente.'
                : ErrorMapper.map(e),
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  Widget _buildGraficoErrorState(
    BuildContext context, {
    required Object error,
    required VoidCallback onRetry,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final esConexion = ErrorMapper.isConnectionError(error);
    final accent = esConexion
        ? (isDark ? Colors.amber.shade300 : Colors.amber.shade700)
        : (isDark ? Colors.red.shade300 : Colors.red.shade700);
    final mensaje = esConexion
        ? 'Este gráfico necesita Internet para actualizarse. Tus datos no se han perdido.'
        : ErrorMapper.map(error);
    final colorTextoOscuro =
        Theme.of(context).textTheme.bodyLarge?.color ?? const Color(0xFF1E293B);

    return Container(
      height: 280,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      decoration: _decoracionNeumorfica(context),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: isDark ? 0.16 : 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(
              esConexion ? Icons.wifi_off_rounded : Icons.sync_problem_rounded,
              color: accent,
              size: 30,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            esConexion ? 'Sin conexión' : 'No se pudo cargar',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: colorTextoOscuro,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            mensaje,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.grey.shade500,
              fontSize: 13,
              height: 1.35,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 14),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Reintentar'),
            style: TextButton.styleFrom(foregroundColor: accent),
          ),
        ],
      ),
    );
  }

  Widget _buildSeccionGrafico(
    BuildContext context, {
    required String titulo,
    required double total,
    required double variacion,
    required int diasFiltro,
    required List<FlSpot> spots,
    required List<String> fechas,
    required bool isEgreso,
    required Function(int) onFiltroChanged,
  }) {
    bool graficoVacio = spots.isEmpty || spots.every((spot) => spot.y == 0);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorTextoOscuro =
        Theme.of(context).textTheme.bodyLarge?.color ?? const Color(0xFF1E293B);
    final TextStyle estiloTituloSeccion = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w800,
      color: colorTextoOscuro,
    );

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: _decoracionNeumorfica(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(titulo, style: estiloTituloSeccion),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey.shade800 : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: diasFiltro,
                    isDense: true,
                    dropdownColor: isDark ? Colors.grey.shade900 : Colors.white,
                    icon: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: isDark ? Colors.white70 : Colors.grey.shade700,
                    ),
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white : Colors.grey.shade700,
                      fontWeight: FontWeight.bold,
                    ),
                    onChanged: (val) {
                      if (val != null) onFiltroChanged(val);
                    },
                    items: const [
                      DropdownMenuItem(value: 7, child: Text("7 días")),
                      DropdownMenuItem(value: 30, child: Text("30 días")),
                      DropdownMenuItem(value: 90, child: Text("90 días")),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            isEgreso ? "Total egresos" : "Total ventas",
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade500,
              fontWeight: FontWeight.w600,
            ),
          ),
          Row(
            children: [
              Text(
                AppFormatters.currency(total),
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  color: colorTextoOscuro,
                ),
              ),
              const SizedBox(width: 12),
              if (total > 0 || variacion != 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: variacion >= 0
                        ? Colors.green.shade50
                        : Colors.red.shade50,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    "${variacion >= 0 ? '+' : ''}${variacion.toStringAsFixed(1)}%",
                    style: TextStyle(
                      color: variacion >= 0
                          ? Colors.green.shade700
                          : Colors.red.shade700,
                      fontWeight: FontWeight.bold,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 25),
          graficoVacio
              ? Container(
                  height: 160,
                  alignment: Alignment.center,
                  child: Text(
                    isEgreso
                        ? "No hay egresos en este período"
                        : "No hay ventas en este período",
                    style: TextStyle(
                      color: Colors.grey.shade500,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                )
              : SizedBox(
                  height: 160,
                  child: LineChart(
                    _construirGraficoLineal(spots, fechas, isEgreso),
                  ),
                ),
        ],
      ),
    );
  }

  LineChartData _construirGraficoLineal(
    List<FlSpot> spots,
    List<String> fechas,
    bool isEgreso,
  ) {
    Color chartColor = isEgreso ? const Color(0xFFD32F2F) : colorPrincipal;
    if (spots.isEmpty) spots = [const FlSpot(0, 0)];

    return LineChartData(
      gridData: const FlGridData(show: false),
      lineTouchData: LineTouchData(
        enabled: true,
        handleBuiltInTouches: true,
        touchSpotThreshold: 50,
        touchTooltipData: LineTouchTooltipData(
          tooltipBgColor: const Color(0xFF1E293B),
          getTooltipItems: (touchedSpots) {
            return touchedSpots.map((spot) {
              return LineTooltipItem(
                AppFormatters.currency(spot.y),
                const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              );
            }).toList();
          },
        ),
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 45,
            getTitlesWidget: (value, meta) {
              return Text(
                'S/ ${value.toInt()}',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              );
            },
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: 1,
            getTitlesWidget: (value, meta) {
              if (value % 1 != 0) return const SizedBox.shrink();
              int idx = value.toInt();
              if (idx >= 0 && idx < fechas.length) {
                return Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    fechas[idx],
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                );
              }
              return const Text('');
            },
          ),
        ),
      ),
      borderData: FlBorderData(show: false),
      lineBarsData: [
        LineChartBarData(
          spots: spots,
          isCurved: true,
          color: chartColor,
          barWidth: 4,
          isStrokeCapRound: true,
          dotData: const FlDotData(show: true),
          belowBarData: BarAreaData(
            show: true,
            color: chartColor.withValues(alpha: 0.1),
          ),
        ),
      ],
    );
  }

  BoxDecoration _decoracionNeumorfica(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return BoxDecoration(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(20),
      border: isDark ? null : Border.all(color: Colors.grey.shade100),
      boxShadow: isDark
          ? []
          : [
              BoxShadow(
                color: Colors.grey.shade200,
                blurRadius: 10,
                offset: const Offset(4, 4),
              ),
              const BoxShadow(
                color: Colors.white,
                blurRadius: 10,
                offset: Offset(-4, -4),
              ),
            ],
    );
  }
}
