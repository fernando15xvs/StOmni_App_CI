import '../domain/subscription_entitlement.dart';

abstract interface class SubscriptionEntitlementGateway {
  Future<List<SubscriptionEntitlement>> getCurrentEntitlements();
}
