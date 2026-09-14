import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:core_logic/core_logic.dart';

class TendenciaGraficoResult {
  final double totalActual;
  final double variacion;
  final List<FlSpot> spots;
  final List<String> fechas;

  TendenciaGraficoResult({
    required this.totalActual,
    required this.variacion,
    required this.spots,
    required this.fechas,
  });
}

class TendenciaRequest {
  final String tipo;
  final int diasFiltro;

  TendenciaRequest(this.tipo, this.diasFiltro);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TendenciaRequest &&
          runtimeType == other.runtimeType &&
          tipo == other.tipo &&
          diasFiltro == other.diasFiltro;

  @override
  int get hashCode => tipo.hashCode ^ diasFiltro.hashCode;
}

final graficoTendenciaProvider =
    FutureProvider.family<TendenciaGraficoResult, TendenciaRequest>((
      ref,
      req,
    ) async {
      final repository = ref.read(dashboardRepositoryProvider);
      final ahora = AppTime.now();

      final inicioActual = DateTime(
        ahora.year,
        ahora.month,
        ahora.day,
      ).subtract(Duration(days: req.diasFiltro - 1));

      final inicioAnterior = inicioActual.subtract(
        Duration(days: req.diasFiltro),
      );

      final fin = DateTime(ahora.year, ahora.month, ahora.day, 23, 59, 59);

      final data = await repository.obtenerTendenciaMovimientos(
        tipo: req.tipo,
        inicioIso: AppTime.toIsoLima(inicioAnterior),
        finIso: AppTime.toIsoLima(fin),
      );

      double periodoAnterior = 0.0;
      double periodoActual = 0.0;
      Map<String, double> agrupado = {};
      bool agruparPorSemanas = req.diasFiltro > 7;

      for (var m in data) {
        // El RPC devuelve YYYY-MM-DD
        final date = DateTime.parse(m['fecha_agrupada']);
        final double monto = (m['total'] as num?)?.toDouble() ?? 0.0;

        if (date.isBefore(inicioActual)) {
          periodoAnterior += monto;
        } else {
          periodoActual += monto;

          if (agruparPorSemanas) {
            int diasDesdeLunes = date.weekday - 1;
            DateTime inicioSemana = DateTime(
              date.year,
              date.month,
              date.day,
            ).subtract(Duration(days: diasDesdeLunes));
            final key = DateFormat('dd/MM').format(inicioSemana);
            agrupado[key] = (agrupado[key] ?? 0.0) + monto;
          } else {
            final key = DateFormat('dd/MM').format(date);
            agrupado[key] = (agrupado[key] ?? 0.0) + monto;
          }
        }
      }

      List<FlSpot> tempSpots = [];
      List<String> tempFechas = [];
      int index = 0;

      if (agruparPorSemanas) {
        DateTime cursor = inicioActual;
        cursor = cursor.subtract(Duration(days: cursor.weekday - 1));
        final finBucket = DateTime(ahora.year, ahora.month, ahora.day);

        while (cursor.isBefore(finBucket) ||
            cursor.isAtSameMomentAs(finBucket)) {
          final key = DateFormat('dd/MM').format(cursor);
          double monto = agrupado[key] ?? 0.0;
          tempFechas.add(key);
          tempSpots.add(FlSpot(index.toDouble(), monto));
          index++;
          cursor = cursor.add(const Duration(days: 7));
        }
      } else {
        for (int i = 0; i < req.diasFiltro; i++) {
          final f = inicioActual.add(Duration(days: i));
          final key = DateFormat('dd/MM').format(f);
          double monto = agrupado[key] ?? 0.0;
          tempFechas.add(key);
          tempSpots.add(FlSpot(index.toDouble(), monto));
          index++;
        }
      }

      double variacion = 0.0;
      if (periodoAnterior > 0) {
        variacion = ((periodoActual - periodoAnterior) / periodoAnterior) * 100;
      } else if (periodoActual > 0) {
        variacion = 100.0;
      }

      return TendenciaGraficoResult(
        totalActual: periodoActual,
        variacion: variacion,
        spots: tempSpots,
        fechas: tempFechas,
      );
    });
