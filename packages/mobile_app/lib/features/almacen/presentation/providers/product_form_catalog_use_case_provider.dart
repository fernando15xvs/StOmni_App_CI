import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Compone el gateway de catálogo con la infraestructura de la aplicación móvil.
/// El caso de uso y sus tipos permanecen independientes de Riverpod.
final productFormCatalogGatewayProvider = Provider<ProductFormCatalogGateway>((
  ref,
) {
  return AlmacenProductFormCatalogGateway(ref.read(almacenRepositoryProvider));
});

final loadProductFormCatalogUseCaseProvider =
    Provider<LoadProductFormCatalogUseCase>((ref) {
      return LoadProductFormCatalogUseCase(
        ref.read(productFormCatalogGatewayProvider),
      );
    });
