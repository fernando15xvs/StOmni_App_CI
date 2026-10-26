import 'package:flutter/material.dart';

/// Small live previews for dark and light mode. They use the draft color so
/// people can compare appearances before tapping "Aplicar cambios".
class AppearanceThemePreview extends StatelessWidget {
  const AppearanceThemePreview({
    super.key,
    required this.accent,
    required this.selectedTheme,
  });

  final Color accent;
  final String selectedTheme;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _sample(Brightness.dark, 'Modo oscuro', 'dark')),
            const SizedBox(width: 10),
            Expanded(child: _sample(Brightness.light, 'Modo claro', 'light')),
          ],
        ),
        if (selectedTheme == 'system') ...[
          const SizedBox(height: 10),
          Text(
            'Automático: se utilizará el tema del dispositivo.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }

  Widget _sample(Brightness brightness, String title, String value) {
    final isDark = brightness == Brightness.dark;
    final background = isDark
        ? const Color(0xFF12171A)
        : const Color(0xFFF2F5F7);
    final surface = isDark ? const Color(0xFF222A2E) : Colors.white;
    final foreground = isDark
        ? const Color(0xFFF2F7F8)
        : const Color(0xFF19272C);
    final secondary = isDark
        ? const Color(0xFFB7C5CA)
        : const Color(0xFF51616A);
    final selected = selectedTheme == value;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected ? accent : secondary.withValues(alpha: 0.28),
          width: selected ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(
                isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                color: foreground,
                size: 16,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ingresos',
                  style: TextStyle(color: secondary, fontSize: 11),
                ),
                const SizedBox(height: 5),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'S/ 0.00',
                    style: TextStyle(
                      color: foreground,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.circle, color: accent, size: 10),
                    const SizedBox(width: 5),
                    Text(
                      'Ingresos',
                      style: TextStyle(
                        color: accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
