import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core_logic/core_logic.dart';
import '../../onboarding/saas_entry_gate.dart';
import '../pages/cambiar_password_page.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool _recordarUsuario = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _cargarDatosGuardados();
  }

  Future<void> _cargarDatosGuardados() async {
    final email = await ref
        .read(authControllerProvider.notifier)
        .loadSavedEmail();
    final recordar = await ref
        .read(authControllerProvider.notifier)
        .loadRememberState();
    if (mounted) {
      setState(() {
        _recordarUsuario = recordar;
        if (email != null) {
          emailController.text = email;
        }
      });
    }
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Por favor, ingresa tu usuario y contraseña.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final exito = await ref
        .read(authControllerProvider.notifier)
        .signIn(
          emailController.text,
          passwordController.text,
          _recordarUsuario,
        );

    if (!mounted || !exito) return;

    final authState = ref.read(authControllerProvider);
    final route = const SaasEntryRoutingPolicy().resolve(
      sessionStatus: authState.sessionStatus,
    );
    if (route == SaasEntryRoute.signedOut) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => route == SaasEntryRoute.passwordChangeRequired
            ? const CambiarPasswordPage(forzado: true)
            : MobileSaasEntryGate(initialTab: PreferencesService.startScreen),
      ),
    );
  }

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);
    final primaryColor = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF1F2937);
    final subtitleColor = isDark ? Colors.grey[400]! : Colors.grey;
    final bgColor = isDark
        ? Theme.of(context).scaffoldBackgroundColor
        : Colors.white;
    final cardBgColor = isDark
        ? Theme.of(context).colorScheme.surface
        : Colors.grey.shade50;
    final borderColor = isDark ? Colors.grey[700]! : Colors.grey.shade300;

    return Scaffold(
      backgroundColor: bgColor,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(30),
          child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: primaryColor.withValues(alpha: isDark ? 0.2 : 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.storefront, size: 80, color: primaryColor),
                ),
                const SizedBox(height: 30),
                Text(
                  'Bienvenido',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
                Text(
                  'Gestiona tu negocio fácilmente',
                  style: TextStyle(color: subtitleColor),
                ),
                const SizedBox(height: 30),
                TextFormField(
                  controller: emailController,
                  style: TextStyle(color: textColor),
                  decoration: InputDecoration(
                    labelText: 'Usuario o Correo',
                    hintText: 'ej. juan o juan@stomni.com',
                    labelStyle: TextStyle(color: subtitleColor),
                    hintStyle: TextStyle(color: subtitleColor),
                    prefixIcon: Icon(
                      Icons.alternate_email,
                      color: subtitleColor,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: primaryColor, width: 2),
                    ),
                    filled: true,
                    fillColor: cardBgColor,
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Usuario o correo obligatorio';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 15),
                TextFormField(
                  controller: passwordController,
                  obscureText: _obscurePassword,
                  style: TextStyle(color: textColor),
                  decoration: InputDecoration(
                    labelText: 'Contraseña',
                    hintText: 'Contraseña',
                    labelStyle: TextStyle(color: subtitleColor),
                    hintStyle: TextStyle(color: subtitleColor),
                    prefixIcon: Icon(Icons.lock_outline, color: subtitleColor),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility
                            : Icons.visibility_off,
                        color: subtitleColor,
                      ),
                      onPressed: () {
                        setState(() {
                          _obscurePassword = !_obscurePassword;
                        });
                      },
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: primaryColor, width: 2),
                    ),
                    filled: true,
                    fillColor: cardBgColor,
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Contraseña obligatoria';
                    }
                    if (value.trim().length < 6) {
                      return 'Mínimo 6 caracteres';
                    }
                    return null;
                  },
                ),
                Row(
                  children: [
                    Checkbox(
                      value: _recordarUsuario,
                      activeColor: primaryColor,
                      checkColor: isDark ? Colors.black : Colors.white,
                      side: BorderSide(color: subtitleColor),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      onChanged: (val) {
                        setState(() {
                          _recordarUsuario = val ?? false;
                        });
                      },
                    ),
                    Text(
                      'Recordar usuario',
                      style: TextStyle(color: textColor),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                if (authState.error != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.red.withValues(alpha: 0.1)
                          : Colors.red.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isDark
                            ? Colors.red.withValues(alpha: 0.5)
                            : Colors.red.shade200,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: isDark ? Colors.red.shade300 : Colors.red,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            authState.error!,
                            style: TextStyle(
                              color: isDark ? Colors.red.shade300 : Colors.red,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                SizedBox(
                  width: double.infinity,
                  height: 55,
                  child: ElevatedButton(
                    onPressed: authState.isLoading ? null : _signIn,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryColor,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
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
                            'INICIAR SESIÓN',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 1.2,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
