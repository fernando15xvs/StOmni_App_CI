import '../domain/guided_onboarding.dart';

abstract interface class GuidedOnboardingGateway {
  Future<GuidedOnboardingProgress> getProgress();
  Future<GuidedOnboardingProgress> completeStep({
    required int expectedRevision,
    required GuidedOnboardingStep step,
  });
}
