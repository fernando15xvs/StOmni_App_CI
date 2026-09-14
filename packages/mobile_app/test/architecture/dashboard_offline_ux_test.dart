import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dashboard no expone errores técnicos de red al usuario', () {
    final charts = File(
      'lib/home/widgets/dashboard/dashboard_charts.dart',
    ).readAsStringSync();

    expect(charts, contains('ErrorMapper.isConnectionError'));
    expect(charts, contains('_buildGraficoErrorState'));
    expect(charts, contains("'Sin conexión'"));
    expect(charts, contains("'Reintentar'"));
    expect(charts, isNot(contains('Text("Error: \$error"')));
  });

  test('dashboard no presenta ceros falsos si el resumen remoto falla', () {
    final dashboard = File(
      'lib/home/widgets/dashboard_tab.dart',
    ).readAsStringSync();

    expect(dashboard, contains('_resumenDisponible = false'));
    expect(
      dashboard,
      contains('valor: _resumenDisponible ? "\$_totalProductos" : "—"'),
    );
    expect(
      dashboard,
      contains('resumenDisponible: _resumenDisponible'),
    );
  });

  test('reintentar gráfico da feedback cuando sigue sin Internet', () {
    final charts = File(
      'lib/home/widgets/dashboard/dashboard_charts.dart',
    ).readAsStringSync();

    expect(charts, contains('ConnectivityStatusService.hasInternet()'));
    expect(charts, contains('_reintentarGrafico'));
    expect(
      charts,
      contains('Comprobando conexión y actualizando'),
    );
    expect(
      charts,
      contains('Sigues sin conexión. Comprueba tu Internet'),
    );
    expect(charts, contains('Gráfico actualizado.'));
  });
}
