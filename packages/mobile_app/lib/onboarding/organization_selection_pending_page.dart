import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/pages/login_page.dart';

/// Safe I3 staging screen. It deliberately does not activate a company:
/// request-scoped selection, offline stores and data caches are not certified.
/// Auth stays signed in, but this screen cannot navigate to business Home.
class OrganizationSelectionPendingPage extends ConsumerWidget {
  const OrganizationSelectionPendingPage({super.key});

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    // Cache NavigatorState before Auth changes: the selection page itself can
    // be disposed during signOut, but the root navigator stays mounted.
    final navigator = Navigator.of(context);
    await ref.read(authControllerProvider.notifier).signOut();
    if (!navigator.mounted) return;
    navigator.pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authUserId = ref.watch(supabaseProvider).auth.currentUser?.id;

    return Scaffold(
      appBar: AppBar(title: const Text('Tus empresas')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.business_outlined, size: 48),
                const SizedBox(height: 16),
                Text(
                  'Selecciona una empresa para continuar',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Tu cuenta tiene varias empresas. Por seguridad, el acceso '
                  'a datos y operaciones permanece bloqueado hasta activar '
                  'la selección aislada por sesión.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (authUserId != null)
                  ref
                      .watch(organizationMembershipsForUserProvider(authUserId))
                      .when(
                        data: (organizations) => Column(
                          children: [
                            for (final organization in organizations)
                              ListTile(
                                leading: const Icon(Icons.store_outlined),
                                title: Text(organization.displayName),
                                subtitle: Text('Rol: ${organization.baseRole}'),
                                // Read-only until I2/I3 session isolation is certified.
                                enabled: false,
                              ),
                          ],
                        ),
                        loading: () => const CircularProgressIndicator(),
                        error: (error, stackTrace) => Column(
                          children: [
                            const Text(
                              'No pudimos verificar tus empresas.',
                              textAlign: TextAlign.center,
                            ),
                            TextButton(
                              onPressed: () => ref.invalidate(
                                organizationMembershipsForUserProvider(
                                  authUserId,
                                ),
                              ),
                              child: const Text('Reintentar'),
                            ),
                          ],
                        ),
                      ),
                const SizedBox(height: 18),
                const Text(
                  'El cambio de empresa estará disponible cuando finalicen '
                  'las pruebas de aislamiento entre organizaciones.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: () => _signOut(context, ref),
                  icon: const Icon(Icons.logout),
                  label: const Text('Cerrar sesión'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
