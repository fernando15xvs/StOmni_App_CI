import 'dart:math' as math;

class AuthUtils {
  /// Formatea un texto ingresado para usarlo como correo electrónico.
  /// Si el input no contiene el símbolo '@', automáticamente le añade '@stomni.com'.
  /// Limpia los espacios y lo convierte a minúsculas para asegurar consistencia.
  static String formatEmail(String input) {
    String cleanInput = input.trim().toLowerCase();

    if (cleanInput.isEmpty) {
      return cleanInput;
    }

    if (!cleanInput.contains('@')) {
      return '$cleanInput@stomni.com';
    }

    return cleanInput;
  }

  /// Genera una contraseña aleatoria de 12 caracteres (incluye mayúsculas, minúsculas, números y símbolos)
  static String generateSecurePassword() {
    final random = math.Random.secure();
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#\$%^&*';
    return List.generate(
      12,
      (index) => chars[random.nextInt(chars.length)],
    ).join();
  }
}
