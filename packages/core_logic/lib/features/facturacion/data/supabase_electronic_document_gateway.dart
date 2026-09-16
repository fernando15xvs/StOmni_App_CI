import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/facturacion_service.dart';
import '../../../utils/app_time.dart';
import '../application/electronic_document_use_case.dart';

class SupabaseElectronicDocumentGateway implements ElectronicDocumentGateway {
  const SupabaseElectronicDocumentGateway(this.client);

  final SupabaseClient client;

  @override
  Future<List<ElectronicDocumentRecord>> list({
    required DateTime start,
    required DateTime end,
    int page = 0,
    int pageSize = 50,
  }) async {
    final exclusiveEnd = DateTime(
      end.year,
      end.month,
      end.day,
    ).add(const Duration(days: 1));
    final limit = pageSize.clamp(10, 100);
    final offset = (page < 0 ? 0 : page) * limit;
    final raw = await client.rpc(
      'listar_documentos_electronicos_v1',
      params: {
        'p_fecha_inicio': AppTime.toIsoLima(start),
        'p_fecha_fin_exclusiva': AppTime.toIsoLima(exclusiveEnd),
        'p_limite': limit,
        'p_offset': offset,
      },
    );
    if (raw is! List) {
      throw const FormatException('El listado de documentos es inválido.');
    }
    return raw.map(_decode).toList(growable: false);
  }

  @override
  Future<ElectronicDocumentActionResult> consult(
    ElectronicDocumentRecord document, {
    bool consultSunat = true,
  }) async {
    final Map<String, dynamic> raw;
    switch (document.category) {
      case 'factura':
      case 'boleta':
        raw = await FacturacionService.consultarComprobante(
          document.id,
          consultarSunat: consultSunat,
        );
        break;
      case 'nota':
        raw = await FacturacionService.consultarNotaCredito(document.id);
        break;
      case 'guia':
        raw = await FacturacionService.consultarGuiaRemision(
          document.id,
          consultarSunat: consultSunat,
        );
        break;
      default:
        throw ArgumentError('Categoría documental no soportada.');
    }
    return _action(raw);
  }

  @override
  Future<ElectronicDocumentActionResult> retry(
    ElectronicDocumentRecord document,
  ) async {
    final Map<String, dynamic> raw;
    switch (document.category) {
      case 'factura':
      case 'boleta':
        raw = await FacturacionService.reintentarComprobante(document.id);
        break;
      case 'nota':
        raw = await FacturacionService.reintentarNotaCredito(document.id);
        break;
      case 'guia':
        raw = await FacturacionService.reintentarGuiaRemision(document.id);
        break;
      default:
        throw ArgumentError('Categoría documental no soportada.');
    }
    return _action(raw);
  }

  ElectronicDocumentActionResult _action(Map<String, dynamic> raw) {
    return ElectronicDocumentActionResult(
      status: raw['estado']?.toString().trim().toLowerCase() ?? '',
      message: raw['mensaje']?.toString(),
    );
  }

  ElectronicDocumentRecord _decode(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Registro de documento inválido.');
    }
    final map = Map<String, dynamic>.from(raw);
    final id = map['id']?.toString().trim() ?? '';
    final category = map['categoria']?.toString().trim().toLowerCase() ?? '';
    if (id.isEmpty || category.isEmpty) {
      throw const FormatException('Documento sin id o categoría.');
    }
    final rawSaleId = map['venta_id'];
    final saleId = rawSaleId is num
        ? rawSaleId.toInt()
        : int.tryParse(rawSaleId?.toString() ?? '');
    final rawTotal = map['total'];
    final total = rawTotal is num
        ? rawTotal.toDouble()
        : double.tryParse(rawTotal?.toString() ?? '');
    DateTime? date;
    for (final key in const ['fecha_emision', 'fecha', 'created_at']) {
      final parsed = DateTime.tryParse(map[key]?.toString() ?? '');
      if (parsed != null) {
        date = parsed;
        break;
      }
    }
    String? optional(Object? value) {
      final text = value?.toString().trim() ?? '';
      return text.isEmpty ? null : text;
    }

    return ElectronicDocumentRecord(
      id: id,
      category: category,
      number: map['numero']?.toString().trim() ?? id,
      typeLabel: map['tipo_label']?.toString().trim() ?? category,
      status: map['estado']?.toString().trim().toLowerCase() ?? 'pendiente',
      party: map['tercero']?.toString().trim() ?? '',
      sunatDescription: optional(map['descripcion_sunat']),
      saleId: saleId,
      issueDate: date,
      total: total,
    );
  }
}
