import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/supabase_provider.dart';
import '../application/validate_session_use_case.dart';
import '../data/supabase_session_validation_gateway.dart';

final sessionValidationGatewayProvider = Provider<SessionValidationGateway>(
  (ref) => SupabaseSessionValidationGateway(ref.watch(supabaseProvider)),
);

final validateSessionUseCaseProvider = Provider<ValidateSessionUseCase>(
  (ref) => ValidateSessionUseCase(gateway: ref.watch(sessionValidationGatewayProvider)),
);
