import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const modules = [
    'features/ventas/pages/seleccion_productos_page.dart',
    'features/ventas/pages/venta_page.dart',
    'features/ventas/pages/ver_venta_page.dart',
    'features/Cotizar/pages/nueva_cotizacion_page.dart',
    'features/Cotizar/pages/lista_cotizaciones_page.dart',
    'features/Cotizar/pages/detalle_cotizacion_page.dart',
    'features/Cotizar/pages/ver_cotizacion_page.dart',
    'features/clientes/pages/clientes_page.dart',
    'features/deudas/pages/deudas_page.dart',
    'features/deudas/pages/detalle_deudas_actor_page.dart',
    'features/facturacion/pages/documentos_electronicos_page.dart',
    'features/facturacion/pages/nueva_guia_remision_page.dart',
    'features/facturacion/pages/gestion_transporte_page.dart',
    'features/reportes/pages/reportes_page.dart',
    'features/kardex/pages/kardex_page.dart',
    'features/proveedores/pages/gestion_proveedores_page.dart',
    'features/almacen/pages/nuevo_producto_page.dart',
    'features/balance/pages/caja_chica_page.dart',
    'features/gastos/pages/nuevo_gasto_page.dart',
  ];

  test('Títulos de módulos usan el mismo fondo y texto del tema móvil', () {
    for (final path in modules) {
      final source = File('lib/$path').readAsStringSync();
      expect(
        source,
        contains('backgroundColor: Theme.of(context).scaffoldBackgroundColor'),
        reason: path,
      );
      expect(
        source,
        contains('Theme.of(context).colorScheme.onSurface'),
        reason: path,
      );
    }
  });

  test('Selector de ventas mantiene carrito y acciones con cabecera plana', () {
    final source = File(
      'lib/features/ventas/pages/seleccion_productos_page.dart',
    ).readAsStringSync();
    expect(source, contains('carritoProvider'));
    expect(source, contains('ProductCard('));
    expect(source, contains("'Seleccionar productos'"));
    expect(source, contains('Theme.of(context).cardColor'));
    expect(source, isNot(contains('Colors.greenAccent')));
    expect(source, contains('colorScheme.onSurfaceVariant'));
    expect(source, contains('colorScheme.onPrimary'));
    expect(source, contains('TextOverflow.ellipsis'));
  });

  test('Tarjetas de producto móviles no aplican sombras antiguas', () {
    final source = File(
      'lib/features/shared/widgets/product_card.dart',
    ).readAsStringSync();
    final mobile = source.substring(
      source.indexOf(
        '    return Card(',
        source.indexOf('    if (isDesktop) {'),
      ),
    );
    expect(mobile, contains('elevation: 0,'));
    expect(mobile, contains('color: Theme.of(context).cardColor'));
    expect(mobile, contains('Theme.of(context).colorScheme.outline'));
    expect(source, isNot(contains('Colors.greenAccent')));
    expect(source, contains('colorScheme.onPrimary'));
    expect(source, contains('colorScheme.onSurface'));
  });
}
