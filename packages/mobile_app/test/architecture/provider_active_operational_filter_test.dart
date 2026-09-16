import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  test('repositorio separa listado administrativo y proveedores activos', () {
    final repository = coreFile(
      'lib/features/proveedores/data/proveedores_repository.dart',
    ).readAsStringSync();

    expect(repository, contains('Future<List<dynamic>> obtenerProveedores('));
    expect(repository, contains('obtenerProveedoresActivos'));
    expect(
      repository,
      contains("query.eq('estado', 'activo').eq('activo', true)"),
    );
    expect(repository, contains('soloActivos: false'));
    expect(repository, contains('soloActivos: true'));
  });

  test('desactivar proveedor mantiene ambos marcadores coherentes', () {
    final repository = coreFile(
      'lib/features/proveedores/data/proveedores_repository.dart',
    ).readAsStringSync();

    expect(
      repository,
      contains("update({'estado': 'inactivo', 'activo': false})"),
    );
    expect(repository, isNot(contains(".from('proveedores').delete()")));
  });

  test('nuevos gastos solo cargan proveedores habilitados', () {
    final repository = coreFile(
      'lib/features/gastos/data/gastos_repository.dart',
    ).readAsStringSync();

    expect(repository, contains(".eq('estado', 'activo')"));
    expect(repository, contains(".eq('activo', true)"));
  });
}
