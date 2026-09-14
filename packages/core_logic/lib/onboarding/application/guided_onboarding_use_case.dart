import '../domain/guided_onboarding.dart';
import 'guided_onboarding_gateway.dart';

class GuidedOnboardingUseCase {
  const GuidedOnboardingUseCase(this.gateway);
  final GuidedOnboardingGateway gateway;

  Future<GuidedOnboardingProgress> getProgress() => gateway.getProgress();

  Future<GuidedOnboardingProgress> completeCurrentStep(
    GuidedOnboardingProgress progress,
  ) {
    final step = progress.nextStep;
    if (progress.completed || step == null) {
      return Future.value(progress);
    }
    return gateway.completeStep(
      expectedRevision: progress.revision,
      step: step,
    );
  }
}
