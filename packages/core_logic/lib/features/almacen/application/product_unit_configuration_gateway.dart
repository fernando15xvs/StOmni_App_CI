import '../domain/commercial_presentation.dart';
import '../domain/product_unit_configuration.dart';

class ProductUnitSettings {
  const ProductUnitSettings({required this.supported, this.configuration});
  final bool supported;
  final ProductUnitConfiguration? configuration;
}

abstract interface class ProductUnitConfigurationGateway {
  Future<ProductUnitSettings> load(int productId);
  Future<ProductUnitConfiguration> save({
    required int productId,
    required int expectedRevision,
    required ProductUnitProfile profile,
  });
}
