import '../../../auth/application/operation_authorizer.dart';
import '../../../auth/domain/app_permission.dart';
import '../../../errors/user_facing_exception.dart';
import '../domain/commercial_presentation.dart';
import '../domain/product_unit_configuration.dart';
import 'product_unit_configuration_gateway.dart';

class SaveProductUnitConfigurationUseCase {
  const SaveProductUnitConfigurationUseCase({
    required this.gateway,
    required this.authorizer,
  });

  final ProductUnitConfigurationGateway gateway;
  final OperationAuthorizer authorizer;

  Future<ProductUnitConfiguration> execute({
    required int productId,
    required ProductUnitSettings current,
    required ProductUnitProfile profile,
  }) async {
    if (productId <= 0 || !current.supported) {
      throw const UserFacingException(
        'La base de datos todavía no admite editar presentaciones.',
      );
    }
    PresentationPolicy.validate(profile);
    final previous = current.configuration;
    if (previous != null &&
        previous.profile.baseUnit.code != profile.baseUnit.code) {
      throw const UserFacingException(
        'La unidad base no se puede sustituir: eso requiere convertir todo el inventario.',
      );
    }
    final user = await authorizer.require({AppPermission.productsUpdate});
    if (authorizer.currentAuthUserId != user) {
      throw const UserFacingException('La sesión cambió. Vuelve a intentarlo.');
    }
    return gateway.save(
      productId: productId,
      expectedRevision: previous?.revision ?? 0,
      profile: profile,
    );
  }
}
