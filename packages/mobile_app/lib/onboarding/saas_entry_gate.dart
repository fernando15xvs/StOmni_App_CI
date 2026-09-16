import 'package:core_logic/core_logic.dart';
import 'package:core_logic/onboarding/providers/guided_onboarding_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/notification_navigation.dart';
import '../home/home_page.dart';
import 'guided_onboarding_page.dart';
import 'organization_setup_page.dart';

/// Punto único post-auth para Android, iOS y Web.
///
/// Orden: Auth sin tenant -> alta F8.1 -> onboarding F8.2 -> Home.
/// Una autorización offline ya validada no consulta el RPC de onboarding.
class MobileSaasEntryGate extends ConsumerWidget {
  const MobileSaasEntryGate({super.key, this.initialTab = 0});

  final int initialTab;

  static const _routing = SaasEntryRoutingPolicy();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);
    final route = _routing.resolve(sessionStatus: authState.sessionStatus);

    if (route == SaasEntryRoute.organizationSetupRequired) {
      return OrganizationSetupPage(
        onOrganizationCreated: () {
          ref.invalidate(guidedOnboardingProgressProvider);
        },
      );
    }

    if (route == SaasEntryRoute.offlineAuthorized) {
      return _home();
    }

    if (!_routing.requiresGuidedOnboarding(authState.sessionStatus)) {
      return const _BlockedEntryView();
    }

    final progress = ref.watch(guidedOnboardingProgressProvider);
    return progress.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (error, stackTrace) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off_outlined, size: 52),
                  const SizedBox(height: 16),
                  const Text(
                    'No pudimos cargar el estado de configuración de tu empresa.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () =>
                        ref.invalidate(guidedOnboardingProgressProvider),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reintentar'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      data: (value) {
        final resolved = _routing.resolve(
          sessionStatus: authState.sessionStatus,
          onboardingCompleted: value.completed,
        );
        if (resolved == SaasEntryRoute.authorized) return _home();
        return GuidedOnboardingPage(
          initialProgress: value,
          onCompleted: () => ref.invalidate(guidedOnboardingProgressProvider),
        );
      },
    );
  }

  Widget _home() =>
      StockAlertNotificationHost(child: HomePage(pestanaInicial: initialTab));
}

class _BlockedEntryView extends StatelessWidget {
  const _BlockedEntryView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'La sesión debe validarse nuevamente antes de continuar.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
