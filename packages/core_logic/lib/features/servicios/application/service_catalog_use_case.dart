import '../../../auth/application/operation_authorizer.dart';
import '../../../auth/domain/app_permission.dart';
import '../../../business/application/business_profile_gateway.dart';
import '../../../errors/user_facing_exception.dart';
import '../domain/service_record.dart';

abstract interface class ServiceCatalogGateway {
  Future<List<ServiceRecord>> list({bool includeInactive = false});
  Future<ServiceRecord> save(ServiceDraft draft);
  Future<void> deactivate(int serviceId);
}

class ServiceCatalogUseCase {
  const ServiceCatalogUseCase({
    required ServiceCatalogGateway gateway,
    required BusinessProfileGateway businessProfile,
    required OperationAuthorizer authorizer,
  }) : _gateway = gateway,
       _businessProfile = businessProfile,
       _authorizer = authorizer;

  final ServiceCatalogGateway _gateway;
  final BusinessProfileGateway _businessProfile;
  final OperationAuthorizer _authorizer;

  Future<List<ServiceRecord>> list({bool includeInactive = false}) async {
    await _requireEnabled();
    return _gateway.list(includeInactive: includeInactive);
  }

  Future<ServiceRecord> save(ServiceDraft draft) async {
    await _requireEnabled();
    final code = draft.code.trim().toUpperCase();
    final name = draft.name.trim();
    if (code.isEmpty ||
        code.length > 80 ||
        name.isEmpty ||
        name.length > 200 ||
        !draft.unitPrice.isFinite ||
        draft.unitPrice < 0 ||
        !draft.purchasePrice.isFinite ||
        draft.purchasePrice < 0) {
      throw const UserFacingException('Completa un servicio válido.');
    }
    final user = await _authorizer.require({
      draft.isNew ? AppPermission.productsCreate : AppPermission.productsUpdate,
      AppPermission.productsChangePrice,
    });
    final saved = await _gateway.save(
      ServiceDraft(
        serviceId: draft.serviceId,
        code: code,
        name: name,
        description: draft.description.trim(),
        unitPrice: draft.unitPrice,
        purchasePrice: draft.purchasePrice,
      ),
    );
    _checkSession(user);
    return saved;
  }

  Future<void> deactivate(int serviceId) async {
    await _requireEnabled();
    if (serviceId <= 0) throw ArgumentError('Servicio inválido.');
    final user = await _authorizer.require({AppPermission.productsUpdate});
    await _gateway.deactivate(serviceId);
    _checkSession(user);
  }

  Future<void> _requireEnabled() async {
    final profile = await _businessProfile.load();
    if (!profile.capabilities.services) {
      throw const UserFacingException(
        'Los servicios no están habilitados para este negocio.',
      );
    }
  }

  void _checkSession(String user) {
    if (_authorizer.currentAuthUserId != user) {
      throw const UserFacingException('La sesión cambió durante la operación.');
    }
  }
}
