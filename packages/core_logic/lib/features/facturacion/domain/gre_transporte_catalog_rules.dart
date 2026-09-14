class GreTransporteCatalogRules {
  const GreTransporteCatalogRules._();

  static bool dniValido(String value) => RegExp(r'^[0-9]{8}$').hasMatch(value);

  static bool rucValido(String value) => RegExp(r'^[0-9]{11}$').hasMatch(value);

  static bool placaValida(String value) =>
      RegExp(r'^[A-Z0-9-]{5,10}$').hasMatch(value.trim().toUpperCase());

  static bool ubigeoValido(String value) =>
      RegExp(r'^[0-9]{6}$').hasMatch(value.trim());

  static bool conductorValido({
    required String dni,
    required String nombres,
    required String apellidos,
    required String licencia,
  }) {
    return dniValido(dni.trim()) &&
        nombres.trim().isNotEmpty &&
        apellidos.trim().isNotEmpty &&
        licencia.trim().isNotEmpty;
  }

  static bool vehiculoValido({
    required String placa,
    required String marca,
    required String constancia,
  }) {
    return placaValida(placa) &&
        marca.trim().isNotEmpty &&
        constancia.trim().isNotEmpty;
  }

  static bool transportistaValido({
    required String ruc,
    required String razonSocial,
  }) {
    return rucValido(ruc.trim()) && razonSocial.trim().isNotEmpty;
  }

  static bool agenciaValida({
    required String nombre,
    required String direccion,
    required String ubigeo,
    required bool permiteOrigen,
    required bool permiteDestino,
  }) {
    return nombre.trim().length >= 2 &&
        direccion.trim().length >= 5 &&
        ubigeoValido(ubigeo) &&
        (permiteOrigen || permiteDestino);
  }

  static GreNombreConductor separarNombreLegacy(
    String nombres,
    String apellidos,
  ) {
    final safeNombres = nombres.trim();
    final safeApellidos = apellidos.trim();
    if (safeApellidos.isNotEmpty || !safeNombres.contains(' ')) {
      return GreNombreConductor(safeNombres, safeApellidos);
    }

    final words = safeNombres.split(RegExp(r'\s+'));
    if (words.length >= 3) {
      return GreNombreConductor(
        words.sublist(0, words.length - 2).join(' '),
        '${words[words.length - 2]} ${words[words.length - 1]}',
      );
    }
    if (words.length == 2) {
      return GreNombreConductor(words.first, words.last);
    }
    return GreNombreConductor(safeNombres, safeApellidos);
  }
}

class GreNombreConductor {
  const GreNombreConductor(this.nombres, this.apellidos);

  final String nombres;
  final String apellidos;
}
