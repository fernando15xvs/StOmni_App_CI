import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/organization_subscription_gateway.dart';
import '../domain/organization_subscription.dart';

class SupabaseOrganizationSubscriptionGateway implements OrganizationSubscriptionGateway {
  const SupabaseOrganizationSubscriptionGateway(this.client);
  final SupabaseClient client;

  @override
  Future<OrganizationSubscription> getCurrent() async {
    final raw=await client.rpc('get_my_subscription_v1');
    if(raw is! Map){
      throw const FormatException('La suscripción actual es inválida.');
    }
    return OrganizationSubscription.fromJson(Map<String,dynamic>.from(raw));
  }
}
