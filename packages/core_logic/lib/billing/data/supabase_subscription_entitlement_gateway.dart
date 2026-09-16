import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/subscription_entitlement_gateway.dart';
import '../domain/subscription_entitlement.dart';

class SupabaseSubscriptionEntitlementGateway
    implements SubscriptionEntitlementGateway {
  const SupabaseSubscriptionEntitlementGateway(this.client);
  final SupabaseClient client;

  @override
  Future<List<SubscriptionEntitlement>> getCurrentEntitlements() async {
    final raw = await client.rpc('get_my_entitlements_v1');
    if (raw is! List)
      throw const FormatException('Los entitlements son inválidos.');
    return raw
        .map(
          (row) => SubscriptionEntitlement.fromJson(
            Map<String, dynamic>.from(row as Map),
          ),
        )
        .toList(growable: false);
  }
}
