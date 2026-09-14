import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _readRequiredFile(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'No existe el archivo esperado: $path');
  return file.readAsStringSync();
}

void main() {
  test('NuevoProductoController delega el guardado de producto a core_logic', () {
    final controller = _readRequiredFile(
      'lib/features/almacen/presentation/controllers/nuevo_producto_controller.dart',
    );
    final useCase = _readRequiredFile(
      '../core_logic/lib/features/almacen/application/save_product_use_case.dart',
    );
    final useCaseProvider = _readRequiredFile(
      'lib/features/almacen/presentation/providers/save_product_use_case_provider.dart',
    );

    expect(controller, contains('saveProductUseCaseProvider'));
    expect(controller, contains('SaveProductCommand('));
    expect(controller, contains('await useCase.execute('));
    expect(useCaseProvider, contains('Provider<SaveProductUseCase>'));
    expect(useCaseProvider, contains('almacenRepositoryProvider'));
    expect(useCaseProvider, contains('productoAdminRepositoryProvider'));
    expect(useCaseProvider, contains('uuid: const Uuid()'));

    const businessDetailsThatMustNotReturnToPresentation = <String>[
      'supabase_flutter',
      'Supabase.instance',
      ".from('productos')",
      "storage.from('",
      'StockUtils.',
      'existeCodigoEnOtroProducto(',
      'existeNombreEquivalente(',
      'subirImagen(',
      'crearProductoConStock(',
      'guardarProductoNuevoOEditado(',
    ];

    for (final forbidden in businessDetailsThatMustNotReturnToPresentation) {
      expect(
        controller,
        isNot(contains(forbidden)),
        reason: 'La presentación móvil volvió a asumir lógica de negocio: $forbidden',
      );
    }

    expect(useCase, contains('class SaveProductCommand'));
    expect(useCase, contains('class SaveProductUseCase'));
    expect(useCase, contains('existeCodigoEnOtroProducto('));
    expect(useCase, contains('existeNombreEquivalente('));
    expect(useCase, contains('StockUtils.'));
    expect(useCase, contains('crearProductoConStock('));
    expect(useCase, contains('guardarProductoNuevoOEditado('));
  });

  test('SaveProductUseCase no conoce APIs de presentación Flutter', () {
    final useCase = _readRequiredFile(
      '../core_logic/lib/features/almacen/application/save_product_use_case.dart',
    );

    const presentationApis = <String>[
      'package:flutter/material.dart',
      'package:flutter/widgets.dart',
      'BuildContext',
      'Navigator.',
      'AlertDialog',
      'ScaffoldMessenger',
      'showDialog(',
    ];

    for (final forbidden in presentationApis) {
      expect(
        useCase,
        isNot(contains(forbidden)),
        reason: 'Un caso de uso de core_logic no debe depender de UI: $forbidden',
      );
    }

    expect(
      useCase,
      isNot(contains('package:flutter_riverpod/flutter_riverpod.dart')),
      reason: 'La composición con Riverpod pertenece a la aplicación cliente.',
    );
    expect(
      useCase,
      isNot(contains('saveProductUseCaseProvider')),
      reason: 'Los providers de Riverpod no deben vivir dentro del caso de uso.',
    );
    expect(useCase, contains('required Uuid uuid'));
    expect(useCase, contains('String createRequestId() => _uuid.v4();'));
  });

  test('la composición del catálogo de producto vive en mobile_app', () {
    final controller = _readRequiredFile(
      'lib/features/almacen/presentation/controllers/nuevo_producto_controller.dart',
    );
    final gateway = _readRequiredFile(
      '../core_logic/lib/features/almacen/data/'
      'almacen_product_form_catalog_gateway.dart',
    );
    final provider = _readRequiredFile(
      'lib/features/almacen/presentation/providers/'
      'product_form_catalog_use_case_provider.dart',
    );

    expect(controller, contains('loadProductFormCatalogUseCaseProvider'));
    expect(provider, contains('Provider<ProductFormCatalogGateway>'));
    expect(provider, contains('AlmacenProductFormCatalogGateway('));
    expect(provider, contains('almacenRepositoryProvider'));
    expect(provider, contains('Provider<LoadProductFormCatalogUseCase>'));
    expect(provider, contains('productFormCatalogGatewayProvider'));

    expect(gateway, isNot(contains('package:flutter_riverpod/flutter_riverpod.dart')));
    expect(gateway, isNot(contains('productFormCatalogGatewayProvider')));
    expect(gateway, isNot(contains('loadProductFormCatalogUseCaseProvider')));
  });

  test('el controlador conserva idempotencia de reintentos en presentación', () {
    final controller = _readRequiredFile(
      'lib/features/almacen/presentation/controllers/nuevo_producto_controller.dart',
    );

    expect(controller, contains('String? _currentRequestId;'));
    expect(controller, contains('_currentRequestId ??= useCase.createRequestId();'));
    expect(controller, contains('requestId: _currentRequestId!'));
    expect(controller, contains('_currentRequestId = null;'));
  });
}
