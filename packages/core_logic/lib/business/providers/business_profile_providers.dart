import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/operation_authorizer_provider.dart';
import '../../providers/supabase_provider.dart';
import '../application/business_profile_gateway.dart';
import '../application/business_sale_policy.dart';
import '../application/update_business_capabilities_use_case.dart';
import '../data/supabase_business_profile_gateway.dart';

final businessProfileGatewayProvider = Provider<BusinessProfileGateway>(
  (ref) => SupabaseBusinessProfileGateway(
    ref.watch(supabaseProvider),
    cacheNamespace: const String.fromEnvironment('SUPABASE_URL'),
  ),
);

final businessSalePolicyProvider = Provider<BusinessSalePolicy>(
  (ref) =>
      ConfiguredBusinessSalePolicy(ref.watch(businessProfileGatewayProvider)),
);

final updateBusinessCapabilitiesUseCaseProvider =
    Provider<UpdateBusinessCapabilitiesUseCase>(
      (ref) => UpdateBusinessCapabilitiesUseCase(
        gateway: ref.watch(businessProfileGatewayProvider),
        authorizer: ref.watch(operationAuthorizerProvider),
      ),
    );
