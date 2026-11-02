import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Navegación principal expone solo Inicio Balance Inventario y Centro',
    () {
      final nav = File(
        'lib/home/widgets/custom_bottom_nav.dart',
      ).readAsStringSync();
      expect(nav, contains("'Inicio'"));
      expect(nav, contains("'Balance'"));
      expect(nav, contains("'Inventario'"));
      expect(nav, contains("'Centro'"));
      expect(nav, isNot(contains("'Movimientos'")));

      final home = File('lib/home/home_page.dart').readAsStringSync();
      expect(home, isNot(contains('const MoverStockPage()')));
      expect(home, contains('widget.pestanaInicial.clamp(0, 3).toInt()'));
    },
  );

  test('Movimientos vive dentro de Centro de trabajo', () {
    final center = File(
      'lib/home/widgets/work_center_tab.dart',
    ).readAsStringSync();
    expect(center, contains('BusinessModule.stockTransfers'));
    expect(center, contains("'Movimientos'"));
    expect(center, contains('MoverStockPage()'));
  });

  test('Inicio no duplica Centro ni conserva el menú antiguo de módulos', () {
    final dashboard = File(
      'lib/home/widgets/dashboard_tab.dart',
    ).readAsStringSync();
    expect(dashboard, isNot(contains("'Centro de trabajo'")));
    expect(dashboard, isNot(contains("'Más herramientas'")));
    expect(dashboard, isNot(contains('_mostrarMenuAcciones')));
    expect(dashboard, isNot(contains('DashboardModuloItem')));
  });

  test('Apariencia ya no ofrece Movimientos como pantalla raíz', () {
    final appearance = File(
      'lib/features/configuracion/pages/preferencias_page.dart',
    ).readAsStringSync();
    expect(appearance, contains('start.clamp(0, 3).toInt()'));
    expect(
      appearance,
      isNot(contains("DropdownMenuItem(value: 4, child: Text('Movimientos'))")),
    );
  });
}
