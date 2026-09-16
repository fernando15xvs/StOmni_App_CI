import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/providers/operation_authorizer_provider.dart';
import '../../../providers/supabase_provider.dart';
import '../application/authoritative_price_sale_line_use_case.dart';
import '../application/sale_pricing_use_case.dart';
import '../data/supabase_sale_pricing_gateway.dart';

final salePricingGatewayProvider = Provider<SalePricingGateway>(
  (ref) => SupabaseSalePricingGateway(ref.watch(supabaseProvider)),
);

final resolveSalePriceUseCaseProvider = Provider<ResolveSalePriceUseCase>(
  (ref) => ResolveSalePriceUseCase(ref.watch(salePricingGatewayProvider)),
);

final authoritativePriceSaleLineUseCaseProvider =
    Provider<AuthoritativePriceSaleLineUseCase>(
      (ref) => AuthoritativePriceSaleLineUseCase(
        ref.watch(resolveSalePriceUseCaseProvider),
      ),
    );

final manageSalePriceRulesUseCaseProvider =
    Provider<ManageSalePriceRulesUseCase>(
      (ref) => ManageSalePriceRulesUseCase(
        gateway: ref.watch(salePricingGatewayProvider),
        authorizer: ref.watch(operationAuthorizerProvider),
      ),
    );
