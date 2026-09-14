import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/supabase_provider.dart';
import '../application/guided_onboarding_gateway.dart';
import '../application/guided_onboarding_use_case.dart';
import '../data/supabase_guided_onboarding_gateway.dart';
import '../domain/guided_onboarding.dart';

final guidedOnboardingGatewayProvider = Provider<GuidedOnboardingGateway>(
  (ref) => SupabaseGuidedOnboardingGateway(ref.watch(supabaseProvider)),
);

final guidedOnboardingUseCaseProvider = Provider<GuidedOnboardingUseCase>(
  (ref) => GuidedOnboardingUseCase(
    ref.watch(guidedOnboardingGatewayProvider),
  ),
);

/// El progreso nunca sobrevive sin listeners: evita reutilizar el onboarding
/// de una empresa anterior después de logout/login en el mismo proceso.
final guidedOnboardingProgressProvider =
    FutureProvider.autoDispose<GuidedOnboardingProgress>(
      (ref) => ref.watch(guidedOnboardingUseCaseProvider).getProgress(),
    );
