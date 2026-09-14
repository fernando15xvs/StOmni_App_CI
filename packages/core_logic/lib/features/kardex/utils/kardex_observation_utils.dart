class KardexObservationUtils {
  const KardexObservationUtils._();

  static bool esVentaCredito(Map<String, dynamic> venta) {
    final estado = venta['estado']?.toString().trim().toLowerCase() ?? '';
    final saldoRaw = venta['saldo'];
    final saldo = saldoRaw is num
        ? saldoRaw.toDouble()
        : double.tryParse(saldoRaw?.toString() ?? '') ?? 0.0;

    return estado == 'pendiente' || saldo > 0.01;
  }

  static String etiquetarCredito(
    String observacion, {
    required bool esCredito,
  }) {
    final texto = observacion.trim();
    if (!esCredito || texto.isEmpty || !texto.startsWith('Venta #')) {
      return observacion;
    }

    if (texto.toLowerCase().contains('· crédito') ||
        texto.toLowerCase().contains('· credito')) {
      return texto;
    }

    return '$texto · Crédito';
  }
}
