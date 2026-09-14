import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/pages/cambiar_password_page.dart';
import '../../../auth/pages/login_page.dart';
import 'package:core_logic/core_logic.dart';
import '../../../core/utils/navigation_utils.dart';

class PerfilPage extends ConsumerStatefulWidget {
  const PerfilPage({super.key});

  @override
  ConsumerState<PerfilPage> createState() => _PerfilPageState();
}

class _PerfilPageState extends ConsumerState<PerfilPage> {
  Map<String, dynamic>? _empleadoData;
  String? _email;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(perfilRepositoryProvider);
    _email = repo.emailActual;
    _empleadoData = {
      'nombre': _email?.split('@')[0] ?? 'Usuario',
      'rol': ref.read(rolProvider),
    };
    _cargarPerfil();
  }

  Future<void> _cargarPerfil() async {
    try {
      final data = await ref.read(perfilRepositoryProvider).obtenerPerfilActual();
      if (mounted && data != null) {
        setState(() => _empleadoData = data);
      }
    } catch (_) {
      // Sin conexión se conservan los datos locales provisionales.
    }
  }

  Future<void> _salir() async {
    await ref.read(authControllerProvider.notifier).signOut();
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginPage()),
        (route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final accentColor = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Mi Perfil',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 20),
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.person, size: 60, color: accentColor),
            ),
            const SizedBox(height: 24),
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(16),
                boxShadow: Theme.of(context).brightness == Brightness.dark
                    ? []
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.03),
                          blurRadius: 15,
                          offset: const Offset(0, 5),
                        ),
                      ],
              ),
              child: Column(
                children: [
                  _buildInfoRow(
                    context,
                    Icons.badge_outlined,
                    'Nombre',
                    (_empleadoData?['nombre'] ?? 'Sin Nombre').toString(),
                  ),
                  const Divider(height: 1),
                  _buildInfoRow(
                    context,
                    Icons.email_outlined,
                    'Email',
                    _email ?? 'Sin Email',
                  ),
                  const Divider(height: 1),
                  _buildInfoRow(
                    context,
                    Icons.admin_panel_settings_outlined,
                    'Rol',
                    normalizarRolApp(_empleadoData?['rol']?.toString()) == 'admin'
                        ? 'ADMINISTRADOR'
                        : 'OPERADOR DE VENTAS Y ALMACÉN',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.lock_reset_rounded, color: Colors.white),
                onPressed: () {
                  AppNavigator.navegarA(context, const CambiarPasswordPage());
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 2,
                ),
                label: const Text(
                  'CAMBIAR CONTRASEÑA',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 15),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.logout_rounded, color: Colors.red),
                onPressed: _salir,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.red, width: 2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                label: const Text(
                  'CERRAR SESIÓN',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.red,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(
    BuildContext context,
    IconData icon,
    String label,
    String value,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          Icon(icon, color: Colors.grey.shade600, size: 24),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade500,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 16,
                    color:
                        Theme.of(context).textTheme.bodyLarge?.color ??
                        Colors.black87,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
