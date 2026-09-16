import 'package:core_logic/business/providers/business_profile_providers.dart';
import 'package:core_logic/features/compras/application/purchase_order_use_case.dart';
import 'package:core_logic/features/compras/data/supabase_purchase_order_gateway.dart';
import 'package:core_logic/features/compras/domain/purchase_order.dart';
import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final desktopPurchaseOrderUseCaseProvider = Provider<PurchaseOrderUseCase>((
  ref,
) {
  return PurchaseOrderUseCase(
    gateway: SupabasePurchaseOrderGateway(ref.read(supabaseProvider)),
    businessProfile: ref.read(businessProfileGatewayProvider),
    authorizer: ref.read(operationAuthorizerProvider),
  );
});

final desktopPurchaseOrdersProvider =
    FutureProvider.autoDispose<List<PurchaseOrderRecord>>((ref) {
      return ref.watch(desktopPurchaseOrderUseCaseProvider).list();
    });

final desktopPurchaseSuppliersProvider =
    FutureProvider.autoDispose<List<SupplierRecord>>((ref) {
      return SupplierUseCase(
        SupabaseSupplierGateway(ref.read(supabaseProvider)),
      ).list(activeOnly: true);
    });
