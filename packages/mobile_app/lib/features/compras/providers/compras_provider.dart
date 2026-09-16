import 'package:core_logic/business/providers/business_profile_providers.dart';
import 'package:core_logic/features/almacen/application/merchandise_entry_catalog_use_case.dart';
import 'package:core_logic/features/compras/application/purchase_order_use_case.dart';
import 'package:core_logic/features/compras/data/supabase_purchase_order_gateway.dart';
import 'package:core_logic/features/compras/domain/purchase_order.dart';
import 'package:core_logic/features/shared/models/producto_busqueda.dart';
import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../almacen/presentation/providers/inventory_use_case_providers.dart';

final purchaseOrderUseCaseProvider = Provider<PurchaseOrderUseCase>((ref) {
  return PurchaseOrderUseCase(
    gateway: SupabasePurchaseOrderGateway(ref.read(supabaseProvider)),
    businessProfile: ref.read(businessProfileGatewayProvider),
    authorizer: ref.read(operationAuthorizerProvider),
  );
});

final purchaseOrdersProvider =
    FutureProvider.autoDispose<List<PurchaseOrderRecord>>((ref) {
      return ref.watch(purchaseOrderUseCaseProvider).list();
    });

final purchaseCatalogProvider =
    FutureProvider.autoDispose<MerchandiseEntryCatalog>((ref) {
      return ref.watch(loadMerchandiseEntryCatalogUseCaseProvider).execute();
    });

final purchaseProductSearchProvider = FutureProvider.autoDispose
    .family<List<ProductoBusqueda>, String>((ref, query) {
      return ref.watch(searchProductsUseCaseProvider)(query.trim());
    });
