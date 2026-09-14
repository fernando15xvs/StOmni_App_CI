import 'package:core_logic/core_logic.dart';

/// Dobles exclusivos de pruebas; nunca se exportan desde lib.
class TestOperationAuthorizer implements OperationAuthorizer {
  TestOperationAuthorizer({this.user = 'user-1', this.role = 'admin'});
  String? user;
  String? role;
  bool? lastAllowOffline;
  @override
  String? get currentAuthUserId => user;
  @override
  Future<String> require(Set<AppPermission> permissions, {bool allowOffline = false}) async {
    lastAllowOffline = allowOffline;
    if (user == null || !RolePermissionPolicy.forRole(role).containsAll(permissions)) {
      throw const UserFacingException('No autorizado.');
    }
    return user!;
  }
}

class TestBusinessProfiles implements BusinessProfileGateway {
  BusinessProfile profile = const BusinessProfile(
    businessId: '1', displayName: 'Pruebas', capabilities: BusinessCapabilities(),
    revision: 0, supportsCapabilitySettings: true,
  );
  int writes = 0;
  bool? lastAllowOffline;
  @override
  Future<BusinessProfile> load({bool allowOffline = false}) async {
    lastAllowOffline = allowOffline;
    return profile;
  }
  @override
  Future<BusinessProfile> updateCapabilities({required String businessId,
    required int expectedRevision, required BusinessCapabilities capabilities}) async {
    if (profile.revision != expectedRevision || profile.businessId != businessId) {
      throw StateError('Revisión obsoleta.');
    }
    writes++;
    return profile = BusinessProfile(
      businessId: businessId, displayName: profile.displayName,
      capabilities: capabilities, revision: expectedRevision + 1,
      supportsCapabilitySettings: true,
    );
  }
}
