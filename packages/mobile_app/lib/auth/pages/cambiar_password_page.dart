import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/widgets/app_text_field.dart';
import 'package:core_logic/core_logic.dart';
import 'login_page.dart';

class CambiarPasswordPage extends ConsumerStatefulWidget {
  final bool forzado;
  const CambiarPasswordPage({super.key, this.forzado = false});

  @override
  ConsumerState<CambiarPasswordPage> createState() =>
      _CambiarPasswordPageState();
}

class _CambiarPasswordPageState extends ConsumerState<CambiarPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _nuevaPasswordController = TextEditingController();
  final _confirmarPasswordController = TextEditingController();

  @override
  void dispose() {
    _nuevaPasswordController.dispose();
    _confirmarPasswordController.dispose();
    super.dispose();
  }

  Future<void> _cambiarContrasena() async {
    if (!_formKey.currentState!.validate()) return;

    final exito = await ref
        .read(authControllerProvider.notifier)
        .cambiarPassword(_nuevaPasswordController.text);

    if (mounted) {
      if (exito) {
        if (widget.forzado) {
          // Delegar el cierre de sesión al core_logic para preservar el
          // principio de cero acoplamiento: signOut() limpia el caché offline
          // y resetea el rolProvider antes de revocar la sesión de Supabase.
          await ref.read(authControllerProvider.notifier).signOut();
          if (mounted) {
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (c) => AlertDialog(
                title: const Text('Contraseña Actualizada'),
                content: const Text(
                  'Por favor, inicia sesión de nuevo con tu nueva contraseña.',
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(c);
                      Navigator.pushAndRemoveUntil(
                        context,
                        MaterialPageRoute(builder: (_) => const LoginPage()),
                        (route) => false,
                      );
                    },
                    child: const Text('Iniciar Sesión'),
                  ),
                ],
              ),
            );
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Contraseña actualizada correctamente.'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context);
        }
      } else {
        final error = ref.read(authControllerProvider).error;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error ?? 'Error al actualizar la contraseña.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    final primaryColor = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Cambiar Contraseña',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        automaticallyImplyLeading: !widget.forzado,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Ingresa tu nueva contraseña",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "Asegúrate de que tenga al menos 8 caracteres, incluyendo mayúsculas, minúsculas y números para mayor seguridad.",
                style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
              ),
              const SizedBox(height: 30),

              AppTextField(
                controller: _nuevaPasswordController,
                label: 'Nueva Contraseña',
                icon: Icons.lock_outline,
                obscureText: true,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Campo obligatorio';
                  }
                  if (value.trim().length < 8) {
                    return 'Mínimo 8 caracteres';
                  }
                  if (!RegExp(r'(?=.*[a-z])').hasMatch(value)) {
                    return 'Debe contener al menos una minúscula';
                  }
                  if (!RegExp(r'(?=.*[A-Z])').hasMatch(value)) {
                    return 'Debe contener al menos una mayúscula';
                  }
                  if (!RegExp(r'(?=.*\d)').hasMatch(value)) {
                    return 'Debe contener al menos un número';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),

              AppTextField(
                controller: _confirmarPasswordController,
                label: 'Confirmar Contraseña',
                icon: Icons.lock_reset_rounded,
                obscureText: true,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Campo obligatorio';
                  }
                  if (value != _nuevaPasswordController.text) {
                    return 'Las contraseñas no coinciden';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 40),

              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton(
                  onPressed: authState.isLoading ? null : _cambiarContrasena,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  child: authState.isLoading
                      ? const SizedBox(
                          height: 25,
                          width: 25,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 3,
                          ),
                        )
                      : const Text(
                          "ACTUALIZAR",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 1.2,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
