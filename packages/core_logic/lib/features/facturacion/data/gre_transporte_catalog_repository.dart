import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final greTransporteCatalogRepositoryProvider =
    Provider<GreTransporteCatalogRepository>((ref) {
      return GreTransporteCatalogRepository(ref.watch(supabaseProvider));
    });

class GreTransporteCatalogRepository {
  GreTransporteCatalogRepository(this._client);

  final SupabaseClient _client;

  Future<GreTransportePrivadoCatalog> cargarPrivado() async {
    final values = await Future.wait<dynamic>([
      _client
          .from('gre_conductores')
          .select()
          .eq('activo', true)
          .order('nombres'),
      _client
          .from('gre_vehiculos')
          .select()
          .eq('activo', true)
          .order('placa'),
    ]);

    return GreTransportePrivadoCatalog(
      conductores: List<Map<String, dynamic>>.from(values[0] as List),
      vehiculos: List<Map<String, dynamic>>.from(values[1] as List),
    );
  }

  Future<GreTransportePublicoCatalog> cargarPublico() async {
    final values = await Future.wait<dynamic>([
      _client
          .from('gre_transportistas')
          .select()
          .eq('activo', true)
          .order('razon_social'),
      _client
          .from('gre_transportistas_agencias')
          .select()
          .eq('activo', true)
          .order('nombre'),
    ]);

    return GreTransportePublicoCatalog(
      transportistas: List<Map<String, dynamic>>.from(values[0] as List),
      agencias: List<Map<String, dynamic>>.from(values[1] as List),
    );
  }
}

class GreTransportePrivadoCatalog {
  const GreTransportePrivadoCatalog({
    required this.conductores,
    required this.vehiculos,
  });

  final List<Map<String, dynamic>> conductores;
  final List<Map<String, dynamic>> vehiculos;
}

class GreTransportePublicoCatalog {
  const GreTransportePublicoCatalog({
    required this.transportistas,
    required this.agencias,
  });

  final List<Map<String, dynamic>> transportistas;
  final List<Map<String, dynamic>> agencias;

  List<Map<String, dynamic>> agenciasDe(int transportistaId) {
    return agencias
        .where(
          (item) =>
              (item['transportista_id'] as num?)?.toInt() == transportistaId,
        )
        .toList(growable: false);
  }
}
