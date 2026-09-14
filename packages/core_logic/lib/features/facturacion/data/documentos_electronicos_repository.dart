import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final documentosElectronicosRepositoryProvider =
    Provider<DocumentosElectronicosRepository>((ref) {
      return DocumentosElectronicosRepository(ref.read(supabaseProvider));
    });

class DocumentosElectronicosRepository {
  final SupabaseClient _client;

  DocumentosElectronicosRepository(this._client);

  Future<List<Map<String, dynamic>>> listar({
    required DateTime fechaInicio,
    required DateTime fechaFin,
    int pagina = 0,
    int porPagina = 50,
  }) async {
    final finExclusivo = DateTime(
      fechaFin.year,
      fechaFin.month,
      fechaFin.day,
    ).add(const Duration(days: 1));

    final limite = porPagina.clamp(10, 100).toInt();
    final offset = pagina < 0 ? 0 : pagina * limite;

    final result = await _client.rpc(
      'listar_documentos_electronicos_v1',
      params: {
        'p_fecha_inicio': AppTime.toIsoLima(fechaInicio),
        'p_fecha_fin_exclusiva': AppTime.toIsoLima(finExclusivo),
        'p_limite': limite,
        'p_offset': offset,
      },
    );

    if (result is! List) {
      throw StateError(
        'listar_documentos_electronicos_v1 devolvió una respuesta inválida.',
      );
    }

    return List<Map<String, dynamic>>.from(
      result.map((item) => Map<String, dynamic>.from(item as Map)),
    );
  }
}
