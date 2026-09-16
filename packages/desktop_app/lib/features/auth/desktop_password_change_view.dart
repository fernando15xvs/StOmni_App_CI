import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class DesktopPasswordChangeView extends ConsumerStatefulWidget {
  const DesktopPasswordChangeView({super.key, required this.onSessionChanged});

  final VoidCallback onSessionChanged;

  @override
  ConsumerState<DesktopPasswordChangeView> createState() =>
      _DesktopPasswordChangeViewState();
}

class _DesktopPasswordChangeViewState
    extends ConsumerState<DesktopPasswordChangeView> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmation = true;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final changed = await ref
        .read(authControllerProvider.notifier)
        .cambiarPassword(_passwordController.text);
    if (changed && mounted) widget.onSessionChanged();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(40),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(36),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.password_rounded,
                        size: 52,
                        color: colors.primary,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Cambia tu contraseña',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Debes establecer una contraseña nueva antes de '
                        'continuar con la empresa o su configuración.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 28),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        decoration: InputDecoration(
                          labelText: 'Nueva contraseña',
                          suffixIcon: IconButton(
                            onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword,
                            ),
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                        validator: _validatePassword,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _confirmationController,
                        obscureText: _obscureConfirmation,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: 'Confirmar contraseña',
                          suffixIcon: IconButton(
                            onPressed: () => setState(
                              () =>
                                  _obscureConfirmation = !_obscureConfirmation,
                            ),
                            icon: Icon(
                              _obscureConfirmation
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                        validator: (value) => value != _passwordController.text
                            ? 'Las contraseñas no coinciden.'
                            : null,
                      ),
                      if (authState.error != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          authState.error!,
                          style: TextStyle(color: colors.error),
                        ),
                      ],
                      const SizedBox(height: 24),
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
                              : const Icon(Icons.check),
                          label: const Text('Guardar y revalidar sesión'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.length < 8) return 'Mínimo 8 caracteres.';
    if (!RegExp(r'(?=.*[a-z])').hasMatch(password)) {
      return 'Debe contener al menos una minúscula.';
    }
    if (!RegExp(r'(?=.*[A-Z])').hasMatch(password)) {
      return 'Debe contener al menos una mayúscula.';
    }
    if (!RegExp(r'(?=.*\d)').hasMatch(password)) {
      return 'Debe contener al menos un número.';
    }
    return null;
  }
}
