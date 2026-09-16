import '../../auth/domain/session_authorization.dart';

/// Destino de entrada compartido por Android, iOS, Web y Desktop.
///
/// `checking` permanece como un estado visual de cada cliente. Las decisiones
/// de seguridad y de acceso se concentran en esta política.
enum SaasEntryRoute {
  signedOut,
  passwordChangeRequired,
  organizationSetupRequired,
  onboardingRequired,
  authorized,
  offlineAuthorized,
}

extension SaasEntryRouteAccess on SaasEntryRoute {
  bool get opensBusinessHome =>
      this == SaasEntryRoute.authorized ||
      this == SaasEntryRoute.offlineAuthorized;
}

class SaasEntryRoutingPolicy {
  const SaasEntryRoutingPolicy();

  bool requiresGuidedOnboarding(SessionValidationStatus status) =>
      status == SessionValidationStatus.online;

  SaasEntryRoute resolve({
    required SessionValidationStatus sessionStatus,
    bool? onboardingCompleted,
  }) {
    return switch (sessionStatus) {
      SessionValidationStatus.passwordChangeRequired =>
        SaasEntryRoute.passwordChangeRequired,
      SessionValidationStatus.organizationSetupRequired =>
        SaasEntryRoute.organizationSetupRequired,
      SessionValidationStatus.online =>
        onboardingCompleted == true
            ? SaasEntryRoute.authorized
            : SaasEntryRoute.onboardingRequired,
      SessionValidationStatus.offline => SaasEntryRoute.offlineAuthorized,
      _ => SaasEntryRoute.signedOut,
    };
  }
}
