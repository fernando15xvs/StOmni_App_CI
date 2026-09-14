import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/supabase_provider.dart';
import '../application/subscription_plan_gateway.dart';
import '../data/supabase_subscription_plan_gateway.dart';
import '../domain/subscription_plan.dart';

final subscriptionPlanGatewayProvider = Provider<SubscriptionPlanGateway>(
  (ref) => SupabaseSubscriptionPlanGateway(ref.watch(supabaseProvider)),
);

final publicSubscriptionPlansProvider = FutureProvider<List<SubscriptionPlan>>(
  (ref) => ref.watch(subscriptionPlanGatewayProvider).listPublicPlans(),
);
