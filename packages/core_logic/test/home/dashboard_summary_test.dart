import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DashboardSummary transforma el payload del RPC', () {
    final summary = DashboardSummary.fromMap({
      'ventas_hoy': 1250.50,
      'gastos_hoy': 310.25,
      'total_productos': 480,
      'low_stock_count': 7,
      'out_of_stock_count': 2,
      'deudas_por_cobrar': 900.0,
      'deudas_por_pagar': 450.0,
    });

    expect(summary.ventasHoy, 1250.50);
    expect(summary.gastosHoy, 310.25);
    expect(summary.totalProductos, 480);
    expect(summary.alertasInventario, 9);
    expect(summary.resultadoOperativoHoy, 940.25);
    expect(summary.deudasPorCobrar, 900);
    expect(summary.deudasPorPagar, 450);
  });

  test('DashboardSummary usa cero cuando faltan campos', () {
    final summary = DashboardSummary.fromMap(const {});

    expect(summary.ventasHoy, 0);
    expect(summary.gastosHoy, 0);
    expect(summary.totalProductos, 0);
    expect(summary.alertasInventario, 0);
    expect(summary.resultadoOperativoHoy, 0);
  });
}
