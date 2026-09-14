import '../domain/business_profile.dart';

abstract interface class BusinessProfileGateway {
  Future<BusinessProfile> load({bool allowOffline = false});
  Future<BusinessProfile> updateCapabilities({
    required String businessId,
    required int expectedRevision,
    required BusinessCapabilities capabilities,
  });
}
