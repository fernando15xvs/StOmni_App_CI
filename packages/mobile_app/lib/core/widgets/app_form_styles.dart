import 'package:flutter/material.dart';

class AppFormStyles {
  /// Retorna un InputDecoration estandarizado para la aplicación.
  /// Si [primaryColor] es nulo, usa el color primario del tema actual.
  static InputDecoration inputDecor(
    BuildContext context,
    String label, {
    IconData? icon,
    Color? primaryColor,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeColor = primaryColor ?? Theme.of(context).colorScheme.primary;

    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(
        color: isDark ? Colors.grey.shade400 : Colors.grey.shade700,
      ),
      floatingLabelStyle: TextStyle(
        color: themeColor,
        fontWeight: FontWeight.bold,
      ),
      prefixIcon: icon != null
          ? Icon(
              icon,
              color: isDark ? Colors.white54 : Colors.grey.shade600,
              size: 20,
            )
          : null,
      filled: true,
      fillColor: isDark
          ? Colors.white.withValues(alpha: 0.04)
          : Colors.grey.shade50,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.grey.shade300,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.grey.shade300,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: themeColor, width: 2),
      ),
    );
  }

  /// Retorna una tarjeta estandarizada para seccionar contenido en los formularios.
  static Widget buildSeccionCard(
    BuildContext context, {
    required String titulo,
    required IconData icono,
    required Widget contenido,
    Color? primaryColor,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final themeColor = primaryColor ?? Theme.of(context).colorScheme.primary;

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.grey.shade200,
        ),
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.02),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icono, color: themeColor, size: 22),
                const SizedBox(width: 10),
                Text(
                  titulo,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
              ],
            ),
            const Divider(height: 30),
            contenido,
          ],
        ),
      ),
    );
  }
}
