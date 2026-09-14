import 'package:flutter/material.dart';

/// Centralización de estilos y decoraciones reutilizables en todo el app
class AppStyles {
  // ============ COLORES CORPORATIVOS ============
  static const Color primaryGreen = Color(0xFF0F9D58);
  static const Color primaryRed = Color(0xFFD32F2F);
  static const Color primaryOrange = Color(0xFFF59E0B);
  static const Color darkGrey = Color(0xFF1E293B);
  static const Color lightGrey = Color(0xFFF3F4F6);
  static const Color borderGrey = Color(0xFFE2E8F0);

  // ============ DECORACIONES DE CAJA ============
  /// Estilo de tarjeta estándar (sombra + border redondeado)
  static BoxDecoration cardDecoration({Color? backgroundColor}) {
    return BoxDecoration(
      color: backgroundColor ?? Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withAlpha(13),
          blurRadius: 10,
          offset: const Offset(0, 4),
        ),
      ],
    );
  }

  /// Decoración de entrada con borde y radio
  static BoxDecoration inputBoxDecoration({
    double radius = 12,
    Color? backgroundColor,
    Color? borderColor,
  }) {
    return BoxDecoration(
      color: backgroundColor ?? Colors.white,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: borderColor ?? borderGrey),
    );
  }

  /// Decoración circular para iconos
  static BoxDecoration circleDecoration({
    required Color bgColor,
    double size = 50,
  }) {
    return BoxDecoration(
      color: bgColor.withValues(alpha: 0.1),
      shape: BoxShape.circle,
    );
  }

  // ============ DECORACIONES DE ENTRADA ============
  /// InputDecoration estándar para campos de texto
  static InputDecoration standardInputDecoration({
    required String label,
    required IconData icon,
    String? hintText,
    Color? focusColor,
    Color? fillColor,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hintText,
      prefixIcon: Icon(icon, color: Colors.grey),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: fillColor ?? Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: borderGrey),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: borderGrey),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: focusColor ?? primaryGreen, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
    );
  }

  static InputDecoration inputDecoration({
    required String label,
    Widget? prefixIcon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      prefixIcon: prefixIcon,
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF0F9D58), width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
    );
  }

  /// InputDecoration compacta (sin label visible, hint apenas visible)
  static InputDecoration compactInputDecoration({
    String? hintText,
    Color? fillColor,
  }) {
    return InputDecoration(
      hintText: hintText,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: borderGrey),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: borderGrey),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: primaryGreen, width: 2),
      ),
      filled: true,
      fillColor: fillColor ?? Colors.white,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
    );
  }

  // ============ ESTILOS DE BOTONES ============
  /// ButtonStyle estándar para ElevatedButton
  static ButtonStyle primaryButtonStyle({
    Color? backgroundColor,
    double borderRadius = 15,
  }) {
    return ElevatedButton.styleFrom(
      backgroundColor: backgroundColor ?? primaryGreen,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      elevation: 2,
    );
  }

  /// ButtonStyle para botones destructivos (rojo)
  static ButtonStyle dangerButtonStyle({double borderRadius = 15}) {
    return ElevatedButton.styleFrom(
      backgroundColor: primaryRed,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }

  // ============ ESTILOS DE TEXTO ============
  /// TextStyle para títulos grandes (AppBar, secciones)
  static const TextStyle titleLarge = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.bold,
    color: darkGrey,
  );

  /// TextStyle para títulos medianos (cards, headers)
  static const TextStyle titleMedium = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    color: darkGrey,
  );

  /// TextStyle para subtítulos
  static const TextStyle subtitleText = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: Colors.grey,
  );

  /// TextStyle para moneda (precios)
  static const TextStyle currencyText = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w900,
    color: darkGrey,
  );

  /// TextStyle para label pequeño
  static const TextStyle labelSmall = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: Colors.grey,
  );

  // ============ SOMBRAS ============
  static List<BoxShadow> cardShadow = [
    BoxShadow(
      color: Colors.black.withAlpha(13),
      blurRadius: 10,
      offset: const Offset(0, 4),
    ),
  ];

  static List<BoxShadow> smallShadow = [
    BoxShadow(
      color: Colors.black.withAlpha(8),
      blurRadius: 5,
      offset: const Offset(0, 2),
    ),
  ];

  // ============ ESPACIOS COMUNES ============
  static const SizedBox verticalSmall = SizedBox(height: 8);
  static const SizedBox verticalMedium = SizedBox(height: 16);
  static const SizedBox verticalLarge = SizedBox(height: 24);

  static const SizedBox horizontalSmall = SizedBox(width: 8);
  static const SizedBox horizontalMedium = SizedBox(width: 16);
  static const SizedBox horizontalLarge = SizedBox(width: 24);

  // ============ MÉTODO AUXILIAR PARA TabBar ============
  /// TabBar decoration estándar
  static BoxDecoration tabBarDecoration({Color? activeColor}) {
    return BoxDecoration(
      color: Colors.grey[100],
      borderRadius: BorderRadius.circular(12),
    );
  }

  static BoxDecoration tabIndicator({Color? color}) {
    return BoxDecoration(
      color: color ?? primaryGreen,
      borderRadius: BorderRadius.circular(12),
      boxShadow: [
        BoxShadow(
          color: (color ?? primaryGreen).withValues(alpha: 0.3),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ],
    );
  }
}
