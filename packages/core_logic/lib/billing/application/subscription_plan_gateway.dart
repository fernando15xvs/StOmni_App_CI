import '../domain/subscription_plan.dart';

abstract interface class SubscriptionPlanGateway {
  Future<List<SubscriptionPlan>> listPublicPlans();
}
