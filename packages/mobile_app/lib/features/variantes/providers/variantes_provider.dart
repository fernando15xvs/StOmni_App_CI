import 'package:core_logic/business/providers/business_profile_providers.dart';
import 'package:core_logic/core_logic.dart';
import 'package:core_logic/features/catalogo/application/product_variant_use_case.dart';
import 'package:core_logic/features/catalogo/data/supabase_product_variant_gateway.dart';
import 'package:core_logic/features/catalogo/domain/product_variant_group.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../almacen/presentation/providers/inventory_use_case_providers.dart';

final productVariantUseCaseProvider = Provider<ProductVariantUseCase>((ref) {
  return ProductVariantUseCase(
    gateway: SupabaseProductVariantGateway(ref.read(supabaseProvider)),
    businessProfile: ref.read(businessProfileGatewayProvider),
    authorizer: ref.read(operationAuthorizerProvider),
  );
});

final productVariantGroupsProvider = FutureProvider.autoDispose<List<ProductVariantGroup>>((ref) {
  return ref.watch(productVariantUseCaseProvider).list();
});

final variantProductCatalogProvider = FutureProvider.autoDispose((ref) {
  return ref.watch(inventoryCatalogUseCaseProvider).loadInitial();
});
