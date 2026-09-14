import 'package:core_logic/auth/domain/session_authorization.dart';
import 'package:core_logic/onboarding/application/saas_entry_routing_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = SaasEntryRoutingPolicy();

  test('sesión pre-tenant sólo abre alta y nunca Home', () {
    final route = policy.resolve(
      sessionStatus: SessionValidationStatus.organizationSetupRequired,
      onboardingCompleted: true,
    );

    expect(route, SaasEntryRoute.organizationSetupRequired);
    expect(route.opensBusinessHome, isFalse);
  });

  test('cambio obligatorio de contraseña tiene prioridad', () {
    final route = policy.resolve(
      sessionStatus: SessionValidationStatus.passwordChangeRequired,
      onboardingCompleted: true,
    );

    expect(route, SaasEntryRoute.passwordChangeRequired);
    expect(route.opensBusinessHome, isFalse);
  });

  test('sesión online incompleta abre configuración guiada', () {
    final route = policy.resolve(
      sessionStatus: SessionValidationStatus.online,
      onboardingCompleted: false,
    );

    expect(policy.requiresGuidedOnboarding(SessionValidationStatus.online), isTrue);
    expect(route, SaasEntryRoute.onboardingRequired);
    expect(route.opensBusinessHome, isFalse);
  });

  test('sesión online completa abre Home', () {
    final route = policy.resolve(
      sessionStatus: SessionValidationStatus.online,
      onboardingCompleted: true,
    );

    expect(route, SaasEntryRoute.authorized);
    expect(route.opensBusinessHome, isTrue);
  });

  test('autorización offline válida abre Home sin consultar onboarding', () {
    final route = policy.resolve(
      sessionStatus: SessionValidationStatus.offline,
      onboardingCompleted: false,
    );

    expect(
      policy.requiresGuidedOnboarding(SessionValidationStatus.offline),
      isFalse,
    );
    expect(route, SaasEntryRoute.offlineAuthorized);
    expect(route.opensBusinessHome, isTrue);
  });

  test('estados no autorizados vuelven al acceso', () {
    const deniedStatuses = <SessionValidationStatus>[
      SessionValidationStatus.signedOut,
      SessionValidationStatus.denied,
      SessionValidationStatus.unavailable,
      SessionValidationStatus.offlineAuthorizationMissing,
      SessionValidationStatus.sessionChanged,
      SessionValidationStatus.failed,
    ];

    for (final status in deniedStatuses) {
      final route = policy.resolve(
        sessionStatus: status,
        onboardingCompleted: true,
      );
      expect(route, SaasEntryRoute.signedOut, reason: status.name);
      expect(route.opensBusinessHome, isFalse, reason: status.name);
    }
  });
}
