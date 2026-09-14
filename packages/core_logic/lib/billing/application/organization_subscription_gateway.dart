import '../domain/organization_subscription.dart';

abstract interface class OrganizationSubscriptionGateway {
  Future<OrganizationSubscription> getCurrent();
}
