import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final productUnitConfigurationGatewayProvider =
    Provider<ProductUnitConfigurationGateway>((ref) {
  return SupabaseProductUnitConfigurationGateway(ref.watch(supabaseProvider));
});

final saveProductUnitConfigurationUseCaseProvider =
    Provider<SaveProductUnitConfigurationUseCase>((ref) {
  return SaveProductUnitConfigurationUseCase(
    gateway: ref.watch(productUnitConfigurationGatewayProvider),
    authorizer: ref.watch(operationAuthorizerProvider),
  );
});

/// Mantiene la sincronización de infraestructura fuera de la página. La
/// configuración ya fue confirmada aunque este refresco local falle.
final refreshProductUnitCatalogProvider =
    Provider<Future<void> Function(int)>((ref) {
  final repository = ref.read(almacenRepositoryProvider);
  return (productId) => repository.sincronizarProductoLocal(
        productId,
        propagarError: true,
      );
});
