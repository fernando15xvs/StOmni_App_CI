import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/supabase_provider.dart';
import '../application/organization_subscription_gateway.dart';
import '../data/supabase_organization_subscription_gateway.dart';
import '../domain/organization_subscription.dart';

final organizationSubscriptionGatewayProvider = Provider<OrganizationSubscriptionGateway>(
  (ref) => SupabaseOrganizationSubscriptionGateway(ref.watch(supabaseProvider)),
);

final currentOrganizationSubscriptionProvider = FutureProvider<OrganizationSubscription>(
  (ref) => ref.watch(organizationSubscriptionGatewayProvider).getCurrent(),
);
