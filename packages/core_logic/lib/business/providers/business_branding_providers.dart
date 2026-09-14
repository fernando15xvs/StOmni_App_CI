import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/supabase_provider.dart';
import '../application/business_branding_gateway.dart';
import '../data/supabase_business_branding_gateway.dart';
import '../domain/business_branding.dart';

final businessBrandingGatewayProvider = Provider<BusinessBrandingGateway>(
  (ref) => SupabaseBusinessBrandingGateway(
    ref.watch(supabaseProvider),
    cacheNamespace: const String.fromEnvironment('SUPABASE_URL'),
  ),
);

final businessBrandingProvider =
    FutureProvider.autoDispose.family<BusinessBranding, bool>(
      (ref, allowOffline) => ref
          .watch(businessBrandingGatewayProvider)
          .load(allowOffline: allowOffline),
    );
