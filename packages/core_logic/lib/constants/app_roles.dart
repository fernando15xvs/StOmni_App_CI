/// Roles técnicos válidos dentro de StOmni.
///
/// No usar nombres alternativos como `administrador`, `vendedor` o
/// `almacenero` como valores técnicos en Flutter.
abstract final class AppRoles {
  static const String admin = 'admin';
  static const String operador = 'operador';

  static const Set<String> values = {admin, operador};

  static String? normalize(String? value) {
    final role = (value ?? '').trim().toLowerCase();
    return values.contains(role) ? role : null;
  }

  static bool isAdmin(String? value) => normalize(value) == admin;
  static bool isOperador(String? value) => normalize(value) == operador;
}
