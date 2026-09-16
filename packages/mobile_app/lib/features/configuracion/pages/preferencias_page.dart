import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core_logic/core_logic.dart';

class PreferenciasPage extends ConsumerWidget {
  const PreferenciasPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(preferencesProvider);
    final notifier = ref.read(preferencesProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuración Local'),
        backgroundColor: Colors.blueGrey,
        foregroundColor: Colors.white,
      ),
      body: Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(
            primary: Theme.of(context).brightness == Brightness.dark
                ? Colors.blueGrey.shade300
                : Colors.blueGrey,
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            // Sección de Apariencia
            _buildSectionHeader(context, Icons.color_lens, 'Apariencia (Tema)'),
            Card(
              child: RadioGroup<String>(
                groupValue: prefs.themeMode,
                onChanged: (val) {
                  if (val != null) notifier.setThemeMode(val);
                },
                child: const Column(
                  children: [
                    RadioListTile<String>(
                      title: Text('Modo Claro'),
                      value: 'light',
                    ),
                    RadioListTile<String>(
                      title: Text('Modo Oscuro'),
                      value: 'dark',
                    ),
                    RadioListTile<String>(
                      title: Text('Automático (Sistema)'),
                      value: 'system',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Pantalla de Inicio
            _buildSectionHeader(context, Icons.home, 'Pantalla de Inicio'),
            Card(
              child: RadioGroup<int>(
                groupValue: prefs.startScreen,
                onChanged: (val) {
                  if (val != null) notifier.setStartScreen(val);
                },
                child: const Column(
                  children: [
                    RadioListTile<int>(
                      title: Text('Inicio (Dashboard)'),
                      value: 0,
                    ),
                    RadioListTile<int>(
                      title: Text('Balance (Punto de Venta)'),
                      value: 1,
                    ),
                    RadioListTile<int>(title: Text('Almacén'), value: 2),
                    RadioListTile<int>(title: Text('Movimientos'), value: 3),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(
    BuildContext context,
    IconData icon,
    String title,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final headerColor = isDark
        ? Colors.blueGrey.shade300
        : Colors.blueGrey.shade700;
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 8),
      child: Row(
        children: [
          Icon(icon, color: headerColor, size: 20),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: headerColor,
            ),
          ),
        ],
      ),
    );
  }
}
