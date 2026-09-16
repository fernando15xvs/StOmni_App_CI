import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/subscription_plan_gateway.dart';
import '../domain/subscription_plan.dart';

class SupabaseSubscriptionPlanGateway implements SubscriptionPlanGateway {
  const SupabaseSubscriptionPlanGateway(this.client);

  final SupabaseClient client;

  @override
  Future<List<SubscriptionPlan>> listPublicPlans() async {
    final raw = await client.rpc('list_subscription_plans_v1');
    if (raw is! List) {
      throw const FormatException('El catálogo de planes es inválido.');
    }
    return raw
        .map(
          (row) =>
              SubscriptionPlan.fromJson(Map<String, dynamic>.from(row as Map)),
        )
        .toList(growable: false);
  }
}
