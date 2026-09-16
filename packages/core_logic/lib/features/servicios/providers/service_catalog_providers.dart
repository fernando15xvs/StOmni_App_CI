import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/providers/operation_authorizer_provider.dart';
import '../../../business/providers/business_profile_providers.dart';
import '../../../providers/supabase_provider.dart';
import '../application/service_catalog_use_case.dart';
import '../data/supabase_service_catalog_gateway.dart';

final serviceCatalogGatewayProvider = Provider<ServiceCatalogGateway>(
  (ref) => SupabaseServiceCatalogGateway(ref.watch(supabaseProvider)),
);

final serviceCatalogUseCaseProvider = Provider<ServiceCatalogUseCase>(
  (ref) => ServiceCatalogUseCase(
    gateway: ref.watch(serviceCatalogGatewayProvider),
    businessProfile: ref.watch(businessProfileGatewayProvider),
    authorizer: ref.watch(operationAuthorizerProvider),
  ),
);
