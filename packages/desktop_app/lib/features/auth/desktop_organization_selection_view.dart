import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Multi-company Auth remains valid, but operational tenant selection is
/// deliberately disabled until per-session context and caches are certified.
class DesktopOrganizationSelectionView extends ConsumerWidget {
  const DesktopOrganizationSelectionView({super.key, required this.onSignOut});

  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authUserId = ref.watch(supabaseProvider).auth.currentUser?.id;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.business_outlined, size: 48),
                const SizedBox(height: 20),
                Text(
                  'Selecciona tu empresa',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Tu cuenta tiene varias empresas activas. El acceso al '
                  'escritorio operativo permanecerá bloqueado hasta que '
                  'se certifique la selección aislada por sesión.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
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
                                enabled: false,
                              ),
                          ],
                        ),
                        loading: () => const CircularProgressIndicator(),
                        error: (error, stackTrace) => Column(
                          children: [
                            const Text(
                              'No se pudo cargar el listado de empresas.',
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
                const SizedBox(height: 20),
                FilledButton.tonalIcon(
                  onPressed: onSignOut,
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
