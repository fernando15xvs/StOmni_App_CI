import '../../auth/application/operation_authorizer.dart';
import '../../auth/domain/app_permission.dart';
import '../../errors/user_facing_exception.dart';
import '../domain/business_profile.dart';
import 'business_profile_gateway.dart';

class UpdateBusinessCapabilitiesUseCase {
  const UpdateBusinessCapabilitiesUseCase({
    required this.gateway,
    required this.authorizer,
  });
  final BusinessProfileGateway gateway;
  final OperationAuthorizer authorizer;

  Future<BusinessProfile> execute(
    BusinessProfile current,
    BusinessCapabilities next,
  ) async {
    if (!current.supportsCapabilitySettings) {
      throw const UserFacingException(
        'El servidor requiere la migración de capacidades.',
      );
    }
    if (!next.supportedByCurrentBackend) {
      throw const UserFacingException(
        'Esta capacidad todavía no tiene un flujo compatible.',
      );
    }
    final user = await authorizer.require({AppPermission.businessConfigure});
    if (authorizer.currentAuthUserId != user) {
      throw const UserFacingException(
        'La sesión cambió antes de guardar la configuración.',
      );
    }
    return gateway.updateCapabilities(
      businessId: current.businessId,
      expectedRevision: current.revision,
      capabilities: next,
    );
  }
}
