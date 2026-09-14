import 'package:core_logic/core_logic.dart';
import 'package:core_logic/onboarding/providers/guided_onboarding_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../home/desktop_home_shell.dart';
import '../onboarding/desktop_saas_onboarding.dart';
import 'desktop_password_change_view.dart';

class DesktopAuthGate extends ConsumerStatefulWidget {
  const DesktopAuthGate({super.key});

  @override
  ConsumerState<DesktopAuthGate> createState() => _DesktopAuthGateState();
}

class _DesktopAuthGateState extends ConsumerState<DesktopAuthGate> {
  static const _routing = SaasEntryRoutingPolicy();

  bool _checkingSession = true;
  SessionValidationStatus _sessionStatus = SessionValidationStatus.signedOut;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreSession());
  }

  Future<void> _restoreSession() async {
    if (mounted) setState(() => _checkingSession = true);
    final result = await ref
        .read(authControllerProvider.notifier)
        .restoreSession();
    if (!mounted) return;
    setState(() {
      _checkingSession = false;
      _sessionStatus = result.status;
    });
  }

  Future<void> _signOut() async {
    await ref.read(authControllerProvider.notifier).signOut();
    if (!mounted) return;
    setState(() {
      _sessionStatus = SessionValidationStatus.signedOut;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSession) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final route = _routing.resolve(sessionStatus: _sessionStatus);
    switch (route) {
      case SaasEntryRoute.passwordChangeRequired:
        return DesktopPasswordChangeView(onSessionChanged: _restoreSession);
      case SaasEntryRoute.organizationSetupRequired:
        return DesktopOrganizationSetupView(onReady: _restoreSession);
      case SaasEntryRoute.signedOut:
        return DesktopLoginView(onSessionChanged: _restoreSession);
      case SaasEntryRoute.offlineAuthorized:
        return DesktopHomeShell(
          offlineAuthorization: true,
          onSignOut: _signOut,
        );
      case SaasEntryRoute.onboardingRequired:
      case SaasEntryRoute.authorized:
        return _buildOnlineEntry();
    }
  }

  Widget _buildOnlineEntry() {
    final progress = ref.watch(guidedOnboardingProgressProvider);
    return progress.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stackTrace) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 52),
              const SizedBox(height: 16),
              const Text('No pudimos cargar la configuración inicial.'),
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
      data: (value) {
        final resolved = _routing.resolve(
          sessionStatus: _sessionStatus,
          onboardingCompleted: value.completed,
        );
        if (resolved == SaasEntryRoute.authorized) {
          return DesktopHomeShell(
            offlineAuthorization: false,
            onSignOut: _signOut,
          );
        }
        return DesktopGuidedOnboardingView(
          progress: value,
          onCompleted: () =>
              ref.invalidate(guidedOnboardingProgressProvider),
        );
      },
    );
  }
}

class DesktopLoginView extends ConsumerStatefulWidget {
  const DesktopLoginView({
    super.key,
    required this.onSessionChanged,
  });

  final VoidCallback onSessionChanged;

  @override
  ConsumerState<DesktopLoginView> createState() => _DesktopLoginViewState();
}

class _DesktopLoginViewState extends ConsumerState<DesktopLoginView> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _remember = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
  }

  Future<void> _loadSavedCredentials() async {
    final controller = ref.read(authControllerProvider.notifier);
    final results = await Future.wait<dynamic>([
      controller.loadSavedEmail(),
      controller.loadRememberState(),
    ]);
    if (!mounted) return;
    setState(() {
      _emailController.text = results[0] as String? ?? '';
      _remember = results[1] as bool? ?? false;
    });
  }

  Future<void> _submit() async {
    final success = await ref
        .read(authControllerProvider.notifier)
        .signIn(
          _emailController.text,
          _passwordController.text,
          _remember,
        );
    if (success && mounted) widget.onSessionChanged();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Row(
        children: [
          Expanded(
            flex: 5,
            child: Container(
              color: colorScheme.primaryContainer,
              padding: const EdgeInsets.all(56),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.inventory_2_outlined,
                    size: 64,
                    color: colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'StOmni Desktop',
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Gestión compartida de ventas, inventario y operación desde '
                    'un cliente optimizado para escritorio.',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            flex: 4,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 430),
                child: Padding(
                  padding: const EdgeInsets.all(40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Iniciar sesión',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _emailController,
                        enabled: !authState.isLoading,
                        keyboardType: TextInputType.emailAddress,
                        onSubmitted: (_) => _submit(),
                        decoration: const InputDecoration(
                          labelText: 'Correo o usuario',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _passwordController,
                        enabled: !authState.isLoading,
                        obscureText: _obscurePassword,
                        onSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: 'Contraseña',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            onPressed: () => setState(
                              () =>
                                  _obscurePassword = !_obscurePassword,
                            ),
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _remember,
                        onChanged: authState.isLoading
                            ? null
                            : (value) =>
                                  setState(() => _remember = value ?? false),
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('Recordar usuario'),
                      ),
                      if (authState.error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          authState.error!,
                          style: TextStyle(color: colorScheme.error),
                        ),
                      ],
                      const SizedBox(height: 18),
                      SizedBox(
                        height: 48,
                        child: FilledButton.icon(
                          onPressed: authState.isLoading ? null : _submit,
                          icon: authState.isLoading
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.login),
                          label: const Text('Entrar'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
