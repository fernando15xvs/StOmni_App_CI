import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ingreso carga almacenes y proveedores activos en paralelo', () {
    final page = File(
      'lib/features/almacen/pages/ingreso_mercaderia_page.dart',
    ).readAsStringSync();

    expect(page, contains('Future.wait<dynamic>'));
    expect(page, contains('obtenerAlmacenesDirecto()'));
    expect(page, contains('obtenerProveedoresActivos()'));
    expect(page, contains('if (!mounted) return;'));
  });

  test('ingreso muestra error recuperable y no expone excepción cruda', () {
    final page = File(
      'lib/features/almacen/pages/ingreso_mercaderia_page.dart',
    ).readAsStringSync();
    final controller = File(
      'lib/features/almacen/presentation/controllers/'
      'ingreso_mercaderia_controller.dart',
    ).readAsStringSync();

    expect(page, contains('_errorCarga = ErrorMapper.map('));
    expect(page, contains("label: const Text('Reintentar')"));
    expect(controller, contains('error: ErrorMapper.map('));
    expect(page, contains('content: Text(next.error!)'));
    expect(page, isNot(contains('Text(error.toString())')));
    expect(controller, isNot(contains('error: e.toString()')));
  });

  test('selector de fecha protege mounted después del await', () {
    final page = File(
      'lib/features/almacen/pages/ingreso_mercaderia_page.dart',
    ).readAsStringSync();

    final fechaStart = page.indexOf('Future<void> _seleccionarFecha()');
    expect(fechaStart, greaterThanOrEqualTo(0));
    final nextMethod = page.indexOf(
      'List<Map<String, dynamic>> _allocations()',
      fechaStart,
    );
    expect(nextMethod, greaterThan(fechaStart));
    final section = page.substring(fechaStart, nextMethod);

    expect(section, contains('await showDatePicker'));
    expect(
      section,
      anyOf(
        contains('if (!mounted) return;'),
        contains('value != null && mounted'),
      ),
    );
    expect(section, contains('setState(() => _fecha = value)'));
  });
}
