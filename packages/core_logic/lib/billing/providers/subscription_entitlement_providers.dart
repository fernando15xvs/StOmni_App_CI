import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/supabase_provider.dart';
import '../application/subscription_entitlement_gateway.dart';
import '../data/supabase_subscription_entitlement_gateway.dart';
import '../domain/subscription_entitlement.dart';

final subscriptionEntitlementGatewayProvider = Provider<SubscriptionEntitlementGateway>(
  (ref)=>SupabaseSubscriptionEntitlementGateway(ref.watch(supabaseProvider)),
);

final currentSubscriptionEntitlementsProvider = FutureProvider<List<SubscriptionEntitlement>>(
  (ref)=>ref.watch(subscriptionEntitlementGatewayProvider).getCurrentEntitlements(),
);
