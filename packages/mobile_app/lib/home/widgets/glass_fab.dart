import 'package:flutter/material.dart';

/// Theme-aware quick-action button. The secondary variant uses a border
/// instead of a fixed black fill, which was invisible on dark backgrounds.
class GlassFab extends StatelessWidget {
  const GlassFab({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    required this.baseColor,
    this.outlined = false,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String label;
  final Color baseColor;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = outlined
        ? theme.colorScheme.onSurface
        : ThemeData.estimateBrightnessForColor(baseColor) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Material(
      color: Colors.transparent,
      child: Ink(
        height: 50,
        decoration: BoxDecoration(
          color: outlined ? theme.cardColor : baseColor,
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: outlined ? theme.colorScheme.outline : baseColor,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(15),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: foreground, size: 19),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
