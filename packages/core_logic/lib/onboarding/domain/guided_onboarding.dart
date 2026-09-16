enum GuidedOnboardingStep {
  businessProfile('business_profile'),
  modules('modules'),
  operations('operations'),
  review('review');

  const GuidedOnboardingStep(this.wireName);
  final String wireName;

  static GuidedOnboardingStep fromWire(String value) => switch (value) {
    'business_profile' => GuidedOnboardingStep.businessProfile,
    'modules' => GuidedOnboardingStep.modules,
    'operations' => GuidedOnboardingStep.operations,
    'review' => GuidedOnboardingStep.review,
    _ => throw FormatException('Paso de onboarding desconocido: $value'),
  };
}

class GuidedOnboardingProgress {
  const GuidedOnboardingProgress({
    required this.completed,
    required this.completedSteps,
    required this.revision,
    required this.startedAt,
    this.completedAt,
    this.nextStep,
  });

  final bool completed;
  final List<GuidedOnboardingStep> completedSteps;
  final int revision;
  final DateTime startedAt;
  final DateTime? completedAt;
  final GuidedOnboardingStep? nextStep;

  factory GuidedOnboardingProgress.fromJson(Map<String, dynamic> json) {
    final rawSteps = json['completed_steps'];
    if (rawSteps is! List) {
      throw const FormatException(
        'Los pasos completados del onboarding son inválidos.',
      );
    }
    final next = json['next_step'] as String?;
    return GuidedOnboardingProgress(
      completed: json['status'] == 'completed',
      completedSteps: rawSteps
          .map((value) => GuidedOnboardingStep.fromWire(value as String))
          .toList(growable: false),
      revision: (json['revision'] as num).toInt(),
      startedAt: DateTime.parse(json['started_at'] as String),
      completedAt: json['completed_at'] == null
          ? null
          : DateTime.parse(json['completed_at'] as String),
      nextStep: next == null ? null : GuidedOnboardingStep.fromWire(next),
    );
  }
}
