import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/core/theme/stomni_mobile_theme.dart';

void main() {
  const subpages = [
    'almacen/pages/config_almacenes_page.dart',
    'balance/pages/historial_caja_page.dart',
    'configuracion/pages/configuracion_negocio_page.dart',
    'empleados/pages/gestion_empleados_page.dart',
    'empleados/pages/historial_pagos_empleado_page.dart',
    'empleados/pages/nuevo_pago_empleado_page.dart',
    'empleados/pages/ver_pago_empleado_page.dart',
    'facturacion/pages/emitir_nota_credito_page.dart',
    'facturacion/pages/gestion_tributaria_page.dart',
    'facturacion/pages/solicitar_baja_tributaria_page.dart',
    'facturacion/pages/ver_guia_remision_page.dart',
    'facturacion/pages/ver_nota_credito_page.dart',
    'facturacion/pages/ver_proceso_tributario_page.dart',
    'gastos/pages/ver_gasto_page.dart',
    'reportes/pages/detalle_balance_page.dart',
    'reportes/pages/exportar_inventario_pdf_page.dart',
    'reportes/pages/exportar_reportes_page.dart',
  ];

  test('Pantallas internas emplean la cabecera del tema unificado', () {
    for (final path in subpages) {
      final source = File('lib/features/$path').readAsStringSync();
      expect(
        source,
        contains('backgroundColor: Theme.of(context).scaffoldBackgroundColor'),
        reason: path,
      );
      expect(
        source,
        contains('foregroundColor: Theme.of(context).colorScheme.onSurface'),
        reason: path,
      );
    }
  });

  test('Acciones de historial y SUNAT usan contraste del tema', () {
    final history = File(
      'lib/features/balance/pages/historial_caja_page.dart',
    ).readAsStringSync();
    final guide = File(
      'lib/features/facturacion/pages/ver_guia_remision_page.dart',
    ).readAsStringSync();
    expect(history, contains('dropdownColor: Theme.of(context).cardColor'));
    expect(
      guide,
      contains('foregroundColor: Theme.of(context).colorScheme.onSurface'),
    );
    expect(guide, contains('surfaceContainerHighest'));
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets('Título compartido legible en modo $brightness', (
      tester,
    ) async {
      final theme = StOmniMobileTheme.create(
        accent: const Color(0xFF1473E6),
        brightness: brightness,
        highContrast: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            appBar: AppBar(title: const Text('Subpantalla de trabajo')),
            body: const SizedBox(),
          ),
        ),
      );
      expect(find.text('Subpantalla de trabajo'), findsOneWidget);
      expect(theme.appBarTheme.foregroundColor, theme.colorScheme.onSurface);
      expect(theme.appBarTheme.backgroundColor, theme.scaffoldBackgroundColor);
    });
  }
}
