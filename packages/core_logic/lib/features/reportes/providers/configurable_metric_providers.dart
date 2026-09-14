import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/providers/operation_authorizer_provider.dart';
import '../../../providers/supabase_provider.dart';
import '../application/configurable_metrics_use_case.dart';
import '../data/supabase_configurable_metric_gateway.dart';

final configurableMetricGatewayProvider = Provider<ConfigurableMetricGateway>((ref) =>
    SupabaseConfigurableMetricGateway(ref.watch(supabaseProvider)));

final configurableMetricsUseCaseProvider = Provider<ConfigurableMetricsUseCase>((ref) =>
    ConfigurableMetricsUseCase(
      metrics: ref.watch(configurableMetricGatewayProvider),
      authorizer: ref.watch(operationAuthorizerProvider),
    ));
