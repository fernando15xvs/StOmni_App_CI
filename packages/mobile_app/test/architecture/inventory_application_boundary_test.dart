import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _withoutComments(String source) {
  return source
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .replaceAll(RegExp(r'//[^\r\n]*'), '');
}

void main() {
  test('controllers de almacén delegan persistencia en casos de uso', () {
    final directory = Directory(
      'lib/features/almacen/presentation/controllers',
    );
    expect(directory.existsSync(), isTrue);

    const forbiddenMarkers = <String>[
      'almacenRepositoryProvider',
      'almacenAdminRepositoryProvider',
      'productoAdminRepositoryProvider',
      'InventarioService.',
      'OfflineService.',
    ];
    final violations = <String>[];

    for (final file in directory.listSync().whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final source = _withoutComments(file.readAsStringSync());
      for (final marker in forbiddenMarkers) {
        if (source.contains(marker)) {
          violations.add('${file.path} -> $marker');
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Los controllers de almacén deben coordinar estado de UI y llamar '
          'casos de uso. Repositorios/servicios concretos se componen sólo en '
          'presentation/providers.\n${violations.join('\n')}',
    );
  });

  test('composición de inventario mantiene infraestructura fuera de controllers', () {
    final file = File(
      'lib/features/almacen/presentation/providers/'
      'inventory_use_case_providers.dart',
    );
    expect(file.existsSync(), isTrue);
    final source = file.readAsStringSync();

    expect(source, contains('InventoryCatalogUseCase'));
    expect(source, contains('RegisterStockMovementUseCase'));
    expect(source, contains('RegisterMerchandiseEntryUseCase'));
    expect(source, contains('ProductLifecycleUseCase'));
    expect(source, contains('WarehouseAdminUseCase'));
    expect(source, contains('AlmacenRepository'));
    expect(source, contains('InventarioService.registrarIngresoMercaderia'));
  });
}
