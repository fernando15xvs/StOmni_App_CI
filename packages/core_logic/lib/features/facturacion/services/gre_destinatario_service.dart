import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';

final greDestinatarioServiceProvider = Provider<GreDestinatarioService>((ref) {
  return GreDestinatarioService(ref.watch(personaLookupRepositoryProvider));
});

class GreDestinatarioData {
  const GreDestinatarioData({
    required this.tipoDocumentoSunat,
    required this.nombre,
    required this.direccion,
    required this.ubigeo,
  });

  final String tipoDocumentoSunat;
  final String nombre;
  final String direccion;
  final String ubigeo;

  factory GreDestinatarioData.fromLookup({
    required String tipo,
    required Map<String, dynamic> data,
  }) {
    final apiData = data['data'];
    final api = apiData is Map ? apiData : const <String, dynamic>{};

    final direccion = api['direccion']?.toString().trim() ?? '';
    final ubigeoRaw =
        (api['ubigeo'] ?? api['ubigeo_sunat'] ?? api['codigo_ubigeo'])
            ?.toString()
            .trim() ??
        '';

    final ubigeo = RegExp(r'^[0-9]{6}$').hasMatch(ubigeoRaw) ? ubigeoRaw : '';

    return GreDestinatarioData(
      tipoDocumentoSunat: tipo == 'dni' ? '1' : '6',
      nombre: tipo == 'dni'
          ? data['nombre_completo']?.toString() ?? ''
          : data['razon_social']?.toString() ?? '',
      direccion: direccion,
      ubigeo: ubigeo,
    );
  }
}

class GreDestinatarioPolicy {
  const GreDestinatarioPolicy._();

  /// Retorna true cuando el punto de llegada todavía es una copia de los
  /// datos del destinatario anterior y, por tanto, debe seguir al consultar
  /// un nuevo DNI/RUC.
  ///
  /// Si existe una agencia de destino o la llegada fue modificada manualmente,
  /// se conserva tal como está.
  static bool debeActualizarLlegada({
    required String direccionDestinatarioAnterior,
    required String ubigeoDestinatarioAnterior,
    required String direccionLlegadaActual,
    required String ubigeoLlegadaActual,
    required bool usaAgenciaDestino,
  }) {
    if (usaAgenciaDestino) return false;

    return direccionLlegadaActual.trim() ==
            direccionDestinatarioAnterior.trim() &&
        ubigeoLlegadaActual.trim() == ubigeoDestinatarioAnterior.trim();
  }
}

class GreDestinatarioService {
  GreDestinatarioService(this._personas);

  final PersonaLookupRepository _personas;

  Future<GreDestinatarioData?> consultar(String numero) async {
    final doc = numero.trim();
    if (doc.isEmpty) {
      throw const FormatException('Ingresa un DNI o RUC para buscar.');
    }

    final tipo = doc.length == 8 ? 'dni' : 'ruc';
    final data = await _personas.consultar(numero: doc, tipo: tipo);
    if (data == null) return null;

    return GreDestinatarioData.fromLookup(tipo: tipo, data: data);
  }
}
