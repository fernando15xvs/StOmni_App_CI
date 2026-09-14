import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/guided_onboarding_gateway.dart';
import '../domain/guided_onboarding.dart';

class SupabaseGuidedOnboardingGateway implements GuidedOnboardingGateway {
  const SupabaseGuidedOnboardingGateway(this.client);
  final SupabaseClient client;

  @override
  Future<GuidedOnboardingProgress> getProgress() async {
    final raw=await client.rpc('get_my_onboarding_progress_v1');
    if(raw is! Map){
      throw const FormatException('El progreso de onboarding es inválido.');
    }
    return GuidedOnboardingProgress.fromJson(Map<String,dynamic>.from(raw));
  }

  @override
  Future<GuidedOnboardingProgress> completeStep({
    required int expectedRevision,
    required GuidedOnboardingStep step,
  }) async {
    final raw=await client.rpc(
      'complete_my_onboarding_step_v1',
      params:<String,dynamic>{
        'p_expected_revision':expectedRevision,
        'p_step':step.wireName,
      },
    );
    if(raw is! Map){
      throw const FormatException('El progreso actualizado de onboarding es inválido.');
    }
    return GuidedOnboardingProgress.fromJson(Map<String,dynamic>.from(raw));
  }
}
