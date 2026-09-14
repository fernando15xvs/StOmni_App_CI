import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/operation_authorizer_provider.dart';
import '../../providers/supabase_provider.dart';
import '../application/business_assistant_gateway.dart';
import '../application/business_assistant_use_case.dart';
import '../data/supabase_business_assistant_gateway.dart';

final businessAssistantGatewayProvider = Provider<BusinessAssistantGateway>((ref) =>
    SupabaseBusinessAssistantGateway(ref.watch(supabaseProvider)));

final businessAssistantUseCaseProvider = Provider<BusinessAssistantUseCase>((ref) =>
    BusinessAssistantUseCase(
      gateway: ref.watch(businessAssistantGatewayProvider),
      authorizer: ref.watch(operationAuthorizerProvider),
    ));
