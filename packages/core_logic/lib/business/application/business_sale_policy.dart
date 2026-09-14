import '../../errors/user_facing_exception.dart';
import 'business_profile_gateway.dart';

abstract interface class BusinessSalePolicy {
  Future<void> validate({
    required bool isCredit,
    required bool requiresElectronicEmission,
    bool allowOffline = false,
  });
}

class ConfiguredBusinessSalePolicy implements BusinessSalePolicy {
  const ConfiguredBusinessSalePolicy(this.profiles);
  final BusinessProfileGateway profiles;

  @override
  Future<void> validate({
    required bool isCredit,
    required bool requiresElectronicEmission,
    bool allowOffline = false,
  }) async {
    final profile = await profiles.load(allowOffline: allowOffline);
    if (isCredit && !profile.capabilities.creditSales) {
      throw const UserFacingException('Las ventas a crédito están deshabilitadas para este negocio.');
    }
    if (requiresElectronicEmission && !profile.capabilities.electronicInvoicing) {
      throw const UserFacingException('La emisión electrónica está deshabilitada para este negocio.');
    }
  }
}
