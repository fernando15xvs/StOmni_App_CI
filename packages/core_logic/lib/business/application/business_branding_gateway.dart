import '../domain/business_branding.dart';

abstract interface class BusinessBrandingGateway {
  /// Carga la marca del tenant derivado por el backend desde Auth.
  Future<BusinessBranding> load({bool allowOffline = false});
}
