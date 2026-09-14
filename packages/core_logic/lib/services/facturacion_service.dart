abstract interface class FacturacionGateway {
  Future<Map<String, dynamic>> emitirComprobante(String comprobanteId);

  Future<Map<String, dynamic>> reintentarComprobante(
    String comprobanteId, {
    bool forzar = false,
  });

  Future<Map<String, dynamic>> consultarComprobante(
    String comprobanteId, {
    bool consultarSunat = false,
  });

  Future<Map<String, dynamic>> reintentarPendientes({int limite = 10});

  Future<Map<String, dynamic>> emitirNotaCredito(String notaCreditoId);

  Future<Map<String, dynamic>> reintentarNotaCredito(
    String notaCreditoId, {
    bool forzar = false,
  });

  Future<Map<String, dynamic>> consultarNotaCredito(String notaCreditoId);

  Future<Map<String, dynamic>> reintentarNotasCreditoPendientes({
    int limite = 10,
  });

  Future<Map<String, dynamic>> ejecutarResumenDiario({int limite = 500});

  Future<Map<String, dynamic>> procesarBajasTributarias({
    String? tipoProceso,
    int limite = 500,
  });

  Future<Map<String, dynamic>> consultarProcesoTributario(
    String procesoId, {
    bool consultarSunat = false,
  });

  Future<Map<String, dynamic>> reintentarProcesoTributario(
    String procesoId, {
    bool forzar = false,
  });

  Future<Map<String, dynamic>> reintentarProcesosTributariosPendientes({
    int limite = 20,
  });

  Future<Map<String, dynamic>> emitirGuiaRemision(String guiaId);

  Future<Map<String, dynamic>> consultarGuiaRemision(
    String guiaId, {
    bool consultarSunat = false,
  });

  Future<Map<String, dynamic>> reintentarGuiaRemision(
    String guiaId, {
    bool forzar = false,
  });

  Future<Map<String, dynamic>> reintentarGuiasPendientes({int limite = 1});

  Future<Map<String, dynamic>> resolverResultadoIncierto({
    required String tipoDocumento,
    required String documentoId,
    required String decision,
    required String motivo,
    String? referenciaExterna,
  });
}

class FacturacionServiceException implements Exception {
  final String message;
  const FacturacionServiceException(this.message);

  @override
  String toString() => message;
}

/// Fachada neutral usada por la aplicación.
///
/// `core` conoce únicamente el contrato [FacturacionGateway]. La implementación
/// concreta de Supabase vive en `features/facturacion` y se conecta desde el
/// composition root (`lib/app/app_dependencies.dart`).
class FacturacionService {
  static FacturacionGateway? _gateway;

  static void configure(FacturacionGateway gateway) {
    _gateway = gateway;
  }

  static FacturacionGateway get _api {
    final gateway = _gateway;
    if (gateway == null) {
      throw StateError(
        'FacturacionService no fue configurado. Inicializa las dependencias de la app.',
      );
    }
    return gateway;
  }

  static Future<Map<String, dynamic>> emitirComprobante(String comprobanteId) {
    return _api.emitirComprobante(comprobanteId);
  }

  static Future<Map<String, dynamic>> reintentarComprobante(
    String comprobanteId, {
    bool forzar = false,
  }) {
    return _api.reintentarComprobante(comprobanteId, forzar: forzar);
  }

  static Future<Map<String, dynamic>> consultarComprobante(
    String comprobanteId, {
    bool consultarSunat = false,
  }) {
    return _api.consultarComprobante(
      comprobanteId,
      consultarSunat: consultarSunat,
    );
  }

  static Future<Map<String, dynamic>> reintentarPendientes({int limite = 10}) {
    return _api.reintentarPendientes(limite: limite);
  }

  static Future<Map<String, dynamic>> emitirNotaCredito(String notaCreditoId) {
    return _api.emitirNotaCredito(notaCreditoId);
  }

  static Future<Map<String, dynamic>> reintentarNotaCredito(
    String notaCreditoId, {
    bool forzar = false,
  }) {
    return _api.reintentarNotaCredito(notaCreditoId, forzar: forzar);
  }

  static Future<Map<String, dynamic>> consultarNotaCredito(
    String notaCreditoId,
  ) {
    return _api.consultarNotaCredito(notaCreditoId);
  }

  static Future<Map<String, dynamic>> reintentarNotasCreditoPendientes({
    int limite = 10,
  }) {
    return _api.reintentarNotasCreditoPendientes(limite: limite);
  }

  static Future<Map<String, dynamic>> ejecutarResumenDiario({
    int limite = 500,
  }) {
    return _api.ejecutarResumenDiario(limite: limite);
  }

  static Future<Map<String, dynamic>> procesarBajasTributarias({
    String? tipoProceso,
    int limite = 500,
  }) {
    return _api.procesarBajasTributarias(
      tipoProceso: tipoProceso,
      limite: limite,
    );
  }

  static Future<Map<String, dynamic>> consultarProcesoTributario(
    String procesoId, {
    bool consultarSunat = false,
  }) {
    return _api.consultarProcesoTributario(
      procesoId,
      consultarSunat: consultarSunat,
    );
  }

  static Future<Map<String, dynamic>> reintentarProcesoTributario(
    String procesoId, {
    bool forzar = false,
  }) {
    return _api.reintentarProcesoTributario(procesoId, forzar: forzar);
  }

  static Future<Map<String, dynamic>> reintentarProcesosTributariosPendientes({
    int limite = 20,
  }) {
    return _api.reintentarProcesosTributariosPendientes(limite: limite);
  }

  static Future<Map<String, dynamic>> emitirGuiaRemision(String guiaId) {
    return _api.emitirGuiaRemision(guiaId);
  }

  static Future<Map<String, dynamic>> consultarGuiaRemision(
    String guiaId, {
    bool consultarSunat = false,
  }) {
    return _api.consultarGuiaRemision(guiaId, consultarSunat: consultarSunat);
  }

  static Future<Map<String, dynamic>> reintentarGuiaRemision(
    String guiaId, {
    bool forzar = false,
  }) {
    return _api.reintentarGuiaRemision(guiaId, forzar: forzar);
  }

  static Future<Map<String, dynamic>> reintentarGuiasPendientes({
    int limite = 1,
  }) {
    return _api.reintentarGuiasPendientes(limite: limite);
  }

  static Future<Map<String, dynamic>> resolverResultadoIncierto({
    required String tipoDocumento,
    required String documentoId,
    required String decision,
    required String motivo,
    String? referenciaExterna,
  }) {
    return _api.resolverResultadoIncierto(
      tipoDocumento: tipoDocumento,
      documentoId: documentoId,
      decision: decision,
      motivo: motivo,
      referenciaExterna: referenciaExterna,
    );
  }
}
