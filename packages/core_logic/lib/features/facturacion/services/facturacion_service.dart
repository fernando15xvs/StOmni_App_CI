import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

/// Implementación Supabase del contrato tributario definido en core.
class SupabaseFacturacionGateway implements FacturacionGateway {
  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<Map<String, dynamic>> emitirComprobante(String comprobanteId) {
    return _invoke('emitir-comprobante', {'comprobante_id': comprobanteId});
  }

  @override
  Future<Map<String, dynamic>> reintentarComprobante(
    String comprobanteId, {
    bool forzar = false,
  }) {
    return _invoke('reintentar-comprobante', {
      'comprobante_id': comprobanteId,
      'forzar': forzar,
    });
  }

  @override
  Future<Map<String, dynamic>> consultarComprobante(
    String comprobanteId, {
    bool consultarSunat = false,
  }) {
    return _invoke('consultar-comprobante', {
      'comprobante_id': comprobanteId,
      'consultar_sunat': consultarSunat,
    });
  }

  @override
  Future<Map<String, dynamic>> reintentarPendientes({int limite = 10}) {
    return _invoke('reintentar-comprobantes-pendientes', {'limite': limite});
  }

  @override
  Future<Map<String, dynamic>> emitirNotaCredito(String notaCreditoId) {
    return _invoke('emitir-nota-credito', {'nota_credito_id': notaCreditoId});
  }

  @override
  Future<Map<String, dynamic>> reintentarNotaCredito(
    String notaCreditoId, {
    bool forzar = false,
  }) {
    return _invoke('reintentar-nota-credito', {
      'nota_credito_id': notaCreditoId,
      'forzar': forzar,
    });
  }

  @override
  Future<Map<String, dynamic>> consultarNotaCredito(String notaCreditoId) {
    return _invoke('consultar-nota-credito', {
      'nota_credito_id': notaCreditoId,
    });
  }

  @override
  Future<Map<String, dynamic>> reintentarNotasCreditoPendientes({
    int limite = 10,
  }) {
    return _invoke('reintentar-notas-credito-pendientes', {'limite': limite});
  }

  @override
  Future<Map<String, dynamic>> ejecutarResumenDiario({int limite = 500}) {
    return _invoke('ejecutar-resumen-diario', {'limite': limite});
  }

  @override
  Future<Map<String, dynamic>> procesarBajasTributarias({
    String? tipoProceso,
    int limite = 500,
  }) {
    return _invoke('procesar-bajas-tributarias', {
      'limite': limite,
      if (tipoProceso != null && tipoProceso.trim().isNotEmpty)
        'tipo_proceso': tipoProceso,
    });
  }

  @override
  Future<Map<String, dynamic>> consultarProcesoTributario(
    String procesoId, {
    bool consultarSunat = false,
  }) {
    return _invoke('consultar-proceso-tributario', {
      'proceso_id': procesoId,
      'consultar_sunat': consultarSunat,
    });
  }

  @override
  Future<Map<String, dynamic>> reintentarProcesoTributario(
    String procesoId, {
    bool forzar = false,
  }) {
    return _invoke('reintentar-proceso-tributario', {
      'proceso_id': procesoId,
      'forzar': forzar,
    });
  }

  @override
  Future<Map<String, dynamic>> reintentarProcesosTributariosPendientes({
    int limite = 20,
  }) {
    return _invoke('reintentar-procesos-tributarios-pendientes', {
      'limite': limite,
    });
  }

  @override
  Future<Map<String, dynamic>> emitirGuiaRemision(String guiaId) {
    return _invoke('emitir-guia-remision', {'guia_id': guiaId});
  }

  @override
  Future<Map<String, dynamic>> consultarGuiaRemision(
    String guiaId, {
    bool consultarSunat = false,
  }) {
    return _invoke('consultar-guia-remision', {
      'guia_id': guiaId,
      'consultar_sunat': consultarSunat,
    });
  }

  @override
  Future<Map<String, dynamic>> reintentarGuiaRemision(
    String guiaId, {
    bool forzar = false,
  }) {
    return _invoke('reintentar-guia-remision', {
      'guia_id': guiaId,
      'forzar': forzar,
    });
  }

  @override
  Future<Map<String, dynamic>> reintentarGuiasPendientes({int limite = 1}) {
    return _invoke('reintentar-guias-pendientes', {'limite': limite});
  }

  @override
  Future<Map<String, dynamic>> resolverResultadoIncierto({
    required String tipoDocumento,
    required String documentoId,
    required String decision,
    required String motivo,
    String? referenciaExterna,
  }) {
    return _invoke('resolver-resultado-incierto', {
      'tipo_documento': tipoDocumento,
      'documento_id': documentoId,
      'decision': decision,
      'motivo': motivo,
      if (referenciaExterna != null && referenciaExterna.trim().isNotEmpty)
        'referencia_externa': referenciaExterna.trim(),
    });
  }

  Future<Map<String, dynamic>> _invoke(
    String functionName,
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await _client.functions.invoke(functionName, body: body);

      final data = response.data;
      if (data is! Map) {
        throw const FacturacionServiceException(
          'La función de facturación devolvió una respuesta inválida.',
        );
      }

      final result = Map<String, dynamic>.from(data);
      if (result['success'] == false && result['estado'] == null) {
        throw FacturacionServiceException(
          result['error']?.toString() ??
              result['mensaje']?.toString() ??
              'No se pudo procesar el comprobante.',
        );
      }

      return result;
    } on FunctionException catch (e) {
      debugPrint('Error Edge Function $functionName: ${e.details}');
      final details = e.details;
      if (details is Map) {
        final map = Map<String, dynamic>.from(details);
        throw FacturacionServiceException(
          map['error']?.toString() ?? e.reasonPhrase ?? e.toString(),
        );
      }
      throw FacturacionServiceException(e.reasonPhrase ?? e.toString());
    } on FacturacionServiceException {
      rethrow;
    } catch (e) {
      throw FacturacionServiceException(
        'No se pudo conectar con el servicio de facturación: $e',
      );
    }
  }
}
