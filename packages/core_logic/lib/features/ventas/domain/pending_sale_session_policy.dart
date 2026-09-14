/// Política pura para evitar que una venta offline sea atribuida a otra sesión.
class PendingSaleSessionPolicy {
  const PendingSaleSessionPolicy._();

  /// Los registros históricos sin `auth_user_id` mantienen compatibilidad.
  /// Los nuevos solo pueden sincronizarse con la misma sesión que los creó.
  static bool puedeSincronizar({
    required String? authUserIdOrigen,
    required String? authUserIdActual,
  }) {
    final origen = authUserIdOrigen?.trim();
    if (origen == null || origen.isEmpty) return true;

    final actual = authUserIdActual?.trim();
    return actual != null && actual.isNotEmpty && actual == origen;
  }
}
