import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/appearance_controller.dart';

/// Local mobile appearance settings. No server permissions or business data
/// are changed by choosing a visual preference.
class PreferenciasPage extends ConsumerStatefulWidget {
  const PreferenciasPage({super.key});

  @override
  ConsumerState<PreferenciasPage> createState() => _PreferenciasPageState();
}

class _PreferenciasPageState extends ConsumerState<PreferenciasPage> {
  AppearanceSettings? _draft;
  String? _themeDraft;
  int? _startDraft;

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(preferencesProvider);
    final saved = ref.watch(appearanceProvider);
    final selection = _draft ?? saved;
    final theme = _themeDraft ?? prefs.themeMode;
    final start = _startDraft ?? prefs.startScreen;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Apariencia')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 30),
          children: [
            Text('Personaliza la apariencia de la aplicación.',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 20),
            _section(context, title: 'Tema', icon: Icons.light_mode_outlined, children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'light', label: Text('Claro'),
                      icon: Icon(Icons.light_mode_outlined)),
                  ButtonSegment(value: 'dark', label: Text('Oscuro'),
                      icon: Icon(Icons.dark_mode_outlined)),
                  ButtonSegment(value: 'system', label: Text('Auto'),
                      icon: Icon(Icons.phone_android_outlined)),
                ],
                selected: {theme},
                onSelectionChanged: (value) =>
                    setState(() => _themeDraft = value.first),
              ),
            ]),
            const SizedBox(height: 14),
            _section(context, title: 'Color de acento', icon: Icons.palette_outlined, children: [
              Wrap(
                spacing: 10,
                runSpacing: 14,
                alignment: WrapAlignment.spaceAround,
                children: [
                  for (var i = 0; i < AccentPalette.colors.length; i++)
                    InkWell(
                      onTap: () => setState(() =>
                          _draft = selection.copyWith(accentIndex: i)),
                      borderRadius: BorderRadius.circular(12),
                      child: SizedBox(
                        width: 68,
                        child: Column(
                          children: [
                            Container(
                              width: 43,
                              height: 43,
                              decoration: BoxDecoration(
                                color: AccentPalette.colors[i],
                                shape: BoxShape.circle,
                                border: selection.accentIndex == i
                                    ? Border.all(color: scheme.onSurface, width: 3)
                                    : null,
                              ),
                              child: selection.accentIndex == i
                                  ? const Icon(Icons.check, color: Colors.white)
                                  : null,
                            ),
                            const SizedBox(height: 6),
                            Text(AccentPalette.names[i], maxLines: 1,
                                style: const TextStyle(fontSize: 10),
                                overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ]),
            const SizedBox(height: 14),
            _section(context, title: 'Vista previa', icon: Icons.visibility_outlined,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AccentPalette.colorAt(selection.accentIndex)
                        .withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.home_rounded,
                          color: AccentPalette.colorAt(selection.accentIndex)),
                      const SizedBox(width: 12),
                      const Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('StOmni', style: TextStyle(fontWeight: FontWeight.w800)),
                          Text('Vista previa del acento elegido'),
                        ],
                      )),
                      Icon(Icons.check_circle,
                          color: AccentPalette.colorAt(selection.accentIndex)),
                    ],
                  ),
                ),
              ]),
            const SizedBox(height: 14),
            _section(context, title: 'Opciones adicionales',
              icon: Icons.tune_rounded, children: [
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Usar color en navegación'),
                  subtitle: const Text('Resaltar las pestañas activas'),
                  value: selection.colorNavigation,
                  onChanged: (v) => setState(() =>
                      _draft = selection.copyWith(colorNavigation: v)),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Contraste mejorado'),
                  value: selection.highContrast,
                  onChanged: (v) => setState(() =>
                      _draft = selection.copyWith(highContrast: v)),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Reducir transparencia'),
                  value: selection.reduceTransparency,
                  onChanged: (v) => setState(() =>
                      _draft = selection.copyWith(reduceTransparency: v)),
                ),
              ]),
            const SizedBox(height: 14),
            _section(context, title: 'Pantalla de inicio',
              icon: Icons.home_outlined, children: [
                DropdownButtonFormField<int>(
                  initialValue: start.clamp(0, 4),
                  decoration: const InputDecoration(labelText: 'Abrir al iniciar'),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Inicio')),
                    DropdownMenuItem(value: 1, child: Text('Balance')),
                    DropdownMenuItem(value: 2, child: Text('Inventario')),
                    DropdownMenuItem(value: 3, child: Text('Centro')),
                    DropdownMenuItem(value: 4, child: Text('Movimientos')),
                  ],
                  onChanged: (v) => setState(() => _startDraft = v),
                ),
              ]),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () async {
                await ref.read(appearanceProvider.notifier).apply(selection);
                await ref.read(preferencesProvider.notifier).setThemeMode(theme);
                if (_startDraft != null) {
                  await ref.read(preferencesProvider.notifier)
                      .setStartScreen(_startDraft!);
                }
                if (!context.mounted) return;
                setState(() {
                  _draft = null;
                  _themeDraft = null;
                  _startDraft = null;
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Apariencia actualizada')),
                );
              },
              icon: const Icon(Icons.check_rounded),
              label: const Text('Aplicar cambios'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, {
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(title, style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }
}
