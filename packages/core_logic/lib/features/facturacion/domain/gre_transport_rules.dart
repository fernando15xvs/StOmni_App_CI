class GreTransportRules {
  const GreTransportRules._();

  static String flujo({
    required String tipoGuia,
    required String modalidad,
    required bool indTransbordo,
  }) {
    if (tipoGuia == 'transportista') return 'transportista';
    if (indTransbordo) return 'transbordo';
    return modalidad == '01' ? 'publico' : 'privado';
  }

  static List<Map<String, dynamic>> agenciasDelTransportista({
    required List<Map<String, dynamic>> agencias,
    required int? transportistaId,
    required bool origen,
    int? agenciaOrigenId,
    int? agenciaDestinoId,
  }) {
    if (transportistaId == null) return const [];

    return agencias.where((item) {
      final pertenece =
          (item['transportista_id'] as num?)?.toInt() == transportistaId;
      final habilitada = origen
          ? item['permite_origen'] == true
          : item['permite_destino'] == true;
      final id = (item['id'] as num?)?.toInt();
      final seleccionada = id == agenciaOrigenId || id == agenciaDestinoId;

      return pertenece &&
          (habilitada || seleccionada) &&
          (item['activo'] == true || seleccionada);
    }).toList();
  }

  static Map<String, dynamic>? agenciaPorId(
    List<Map<String, dynamic>> agencias,
    int? id,
  ) {
    if (id == null) return null;
    for (final item in agencias) {
      if ((item['id'] as num?)?.toInt() == id) return item;
    }
    return null;
  }

  static String textoAgencia(Map<String, dynamic> item) {
    final nombre = item['nombre']?.toString() ?? 'Agencia';
    final distrito = item['distrito']?.toString().trim() ?? '';
    return distrito.isEmpty ? nombre : '$nombre · $distrito';
  }
}
