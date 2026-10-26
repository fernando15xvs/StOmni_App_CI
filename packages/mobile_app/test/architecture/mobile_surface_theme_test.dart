import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Ordenar inventario respeta el tema y el acento configurado', () {
    final source = File(
      'lib/features/almacen/pages/almacen_page.dart',
    ).readAsStringSync();

    expect(source, contains('Theme.of(context).colorScheme.onSurface'));
    expect(source, contains('Theme.of(context).colorScheme.primary'));
    expect(source, isNot(contains('AppColors.primary')));
    expect(source, isNot(contains('Colors.black87')));
    expect(source, isNot(contains('Colors.greenAccent')));
  });

  test('Balance presenta superficie y filtro compatibles con claro y oscuro', () {
    final source = File(
      'lib/features/balance/pages/balance_page.dart',
    ).readAsStringSync();

    expect(source, contains("'Balance financiero'"));
    expect(source, contains('"Hoy · '));
    expect(source, contains('Theme.of(context).cardColor'));
    expect(source, contains('colorScheme.surfaceContainerHighest'));
  });

  test('Carga del inicio y logotipo no fuerzan superficies blancas', () {
    final source = File(
      'lib/home/widgets/dashboard_tab.dart',
    ).readAsStringSync();
    final loading = source.substring(
      source.indexOf('Widget _buildShimmerLoading()'),
    );
    expect(loading, contains('scheme.surfaceContainerHighest'));
    expect(loading, isNot(contains('Colors.white')));
  });
}
