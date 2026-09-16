import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  test('sync remoto usa columnas explícitas y cursor estable por id', () {
    final repository = coreFile(
      'lib/features/almacen/data/almacen_repository.dart',
    ).readAsStringSync();

    expect(repository, contains('AlmacenSyncContract.productoSelect'));
    expect(repository, contains('AlmacenSyncContract.almacenSelect'));
    expect(repository, contains('AlmacenSyncContract.proveedorSelect'));
    expect(repository, contains(".gt('id', ultimoId)"));
    expect(repository, contains(".order('id')"));
    expect(repository, contains('.limit(AlmacenSyncContract.productPageSize)'));
    expect(repository, isNot(contains('.range(offset')));
    expect(repository, isNot(contains("select('*, inventario_almacen")));
  });

  test('todo dato que entra al cache pasa por allowlist', () {
    final repository = coreFile(
      'lib/features/almacen/data/almacen_repository.dart',
    ).readAsStringSync();

    expect(repository, contains('AlmacenSyncContract.productoParaCache'));
    expect(repository, contains('AlmacenSyncContract.almacenParaCache'));
    expect(repository, contains('AlmacenSyncContract.proveedorParaCache'));
  });

  test('repositorio general ya no conserva DELETE físico de almacenes', () {
    final repository = coreFile(
      'lib/features/almacen/data/almacen_repository.dart',
    ).readAsStringSync();

    expect(repository, isNot(contains('Future<void> eliminarAlmacen(')));
    expect(repository, isNot(contains(".from('almacenes').delete()")));
  });

  test('cache vacío y sync silenciosa conservan recuperación local-first', () {
    final repository = coreFile(
      'lib/features/almacen/data/almacen_repository.dart',
    ).readAsStringSync();

    expect(repository, contains('if (cache.isEmpty && start == 0)'));
    expect(repository, contains('await sincronizarConSupabase();'));
    expect(
      repository,
      contains('_programarSincronizacionSilenciosaSiCorresponde'),
    );
    expect(repository, contains('Future.delayed(const Duration(seconds: 3)'));
    expect(repository, contains('ultima_sincronizacion_productos'));
  });
}
