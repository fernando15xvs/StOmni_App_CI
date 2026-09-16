import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/providers/operation_authorizer_provider.dart';
import '../../../business/providers/business_profile_providers.dart';
import '../../../providers/supabase_provider.dart';
import '../application/inventory_traceability_use_case.dart';
import '../data/supabase_inventory_traceability_gateway.dart';

final inventoryTraceabilityGatewayProvider =
    Provider<InventoryTraceabilityGateway>(
      (ref) =>
          SupabaseInventoryTraceabilityGateway(ref.watch(supabaseProvider)),
    );

final inventoryTraceabilityUseCaseProvider =
    Provider<InventoryTraceabilityUseCase>(
      (ref) => InventoryTraceabilityUseCase(
        gateway: ref.watch(inventoryTraceabilityGatewayProvider),
        businessProfile: ref.watch(businessProfileGatewayProvider),
        authorizer: ref.watch(operationAuthorizerProvider),
      ),
    );
