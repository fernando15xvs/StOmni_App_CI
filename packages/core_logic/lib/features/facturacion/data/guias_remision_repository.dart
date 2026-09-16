import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final guiasRemisionRepositoryProvider = Provider<GuiasRemisionRepository>((
  ref,
) {
  return GuiasRemisionRepository(ref.read(supabaseProvider));
});

class GuiasRemisionRepository {
  final SupabaseClient _client;

  GuiasRemisionRepository(this._client);

  Future<Map<String, dynamic>> cargarBase({
    int? ventaId,
    int? transferenciaId,
    String? guiaId,
  }) async {
    final futures = await Future.wait<dynamic>([
      _client
          .from('configuracion_negocio')
          .select()
          .order('id')
          .limit(1)
          .single(),
      _client.from('almacenes').select().eq('activo', true).order('id'),
      _client
          .from('gre_transportistas')
          .select()
          .eq('activo', true)
          .order('razon_social'),
      _client.from('gre_transportistas_agencias').select().order('nombre'),
      _client
          .from('gre_conductores')
          .select()
          .eq('activo', true)
          .order('nombres'),
      _client.from('gre_vehiculos').select().eq('activo', true).order('placa'),
    ]);

    Map<String, dynamic>? origen;
    Map<String, dynamic>? guiaEdicion;

    if (guiaId != null && guiaId.trim().isNotEmpty) {
      guiaEdicion = await _cargarGuia(guiaId.trim());
    } else if (ventaId != null) {
      origen = await _cargarVenta(ventaId);
    } else if (transferenciaId != null) {
      origen = await _cargarTraslado(transferenciaId);
    }

    return {
      'empresa': Map<String, dynamic>.from(futures[0] as Map),
      'almacenes': List<Map<String, dynamic>>.from(futures[1] as List),
      'transportistas': List<Map<String, dynamic>>.from(futures[2] as List),
      'agencias': List<Map<String, dynamic>>.from(futures[3] as List),
      'conductores': List<Map<String, dynamic>>.from(futures[4] as List),
      'vehiculos': List<Map<String, dynamic>>.from(futures[5] as List),
      // La selección manual usa el buscador general de inventario, que no
      // tiene el límite fijo de 500 productos de la versión anterior.
      'productos': const <Map<String, dynamic>>[],
      'origen': origen,
      'guia_edicion': guiaEdicion,
    };
  }

  Future<Map<String, dynamic>> _cargarGuia(String guiaId) async {
    final values = await Future.wait<dynamic>([
      _client.from('guias_remision').select().eq('id', guiaId).single(),
      _client
          .from('guias_remision_detalles')
          .select(
            '*, productos('
            'id,codigo,nombre,peso_kg,unidad_gre,unidad_medida,'
            'tipo_venta,cantidad_por_caja'
            ')',
          )
          .eq('guia_id', guiaId)
          .order('id'),
    ]);

    return {
      'guia': Map<String, dynamic>.from(values[0] as Map),
      'detalles': List<Map<String, dynamic>>.from(values[1] as List),
    };
  }

  Future<Map<String, dynamic>> _cargarVenta(int ventaId) async {
    final values = await Future.wait<dynamic>([
      _client
          .from('ventas')
          .select('*, clientes(*)')
          .eq('id', ventaId)
          .single(),
      _client
          .from('detalle_ventas')
          .select(
            '*, productos('
            'id,codigo,nombre,peso_kg,unidad_gre,unidad_medida,'
            'tipo_venta,cantidad_por_caja'
            ')',
          )
          .eq('venta_id', ventaId)
          .order('id'),
      _client
          .from('comprobantes_electronicos')
          .select('id,tipo_documento_sunat,serie,correlativo,estado')
          .eq('venta_id', ventaId)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle(),
    ]);

    return {
      'tipo': 'venta',
      'venta': Map<String, dynamic>.from(values[0] as Map),
      'detalles': List<Map<String, dynamic>>.from(values[1] as List),
      'comprobante': values[2] == null
          ? null
          : Map<String, dynamic>.from(values[2] as Map),
    };
  }

  Future<Map<String, dynamic>> _cargarTraslado(int transferenciaId) async {
    final raw = await _client
        .from('transferencias_stock')
        .select(
          '*, productos('
          'id,codigo,nombre,peso_kg,unidad_gre,unidad_medida,'
          'tipo_venta,cantidad_por_caja'
          '), '
          'origen:almacenes!transferencias_stock_almacen_origen_id_fkey(*), '
          'destino:almacenes!transferencias_stock_almacen_destino_id_fkey(*)',
        )
        .eq('id', transferenciaId)
        .single();

    return {'tipo': 'traslado', 'traslado': Map<String, dynamic>.from(raw)};
  }

  Future<void> eliminarBorrador(String guiaId) async {
    await _client.rpc(
      'eliminar_borrador_guia_v1',
      params: {'p_guia_id': guiaId},
    );
  }

  Future<Map<String, dynamic>> guardarGuia({
    String? guiaId,
    required String requestId,
    required bool emitir,
    required String tipoGuia,
    required String origenTipo,
    int? ventaId,
    int? transferenciaId,
    String? guiaRemitenteId,
    String? documentoRelacionadoTipo,
    String? documentoRelacionadoNumero,
    required String motivoCodigo,
    required String motivoDescripcion,
    required String modalidadTransporte,
    required DateTime fechaEmision,
    required DateTime fechaTraslado,
    required Map<String, dynamic> destinatario,
    Map<String, dynamic> remitente = const {},
    required Map<String, dynamic> partida,
    required Map<String, dynamic> llegada,
    int? transportistaId,
    int? conductorId,
    int? vehiculoId,
    bool indTransbordo = false,
    int? transportistaTransbordoId,
    int? agenciaOrigenId,
    int? agenciaDestinoId,
    String destinoEntregaTipo = 'direccion_cliente',
    double? pesoTotal,
    int? cantidadBultos,
    required bool pesoEditado,
    String? observacion,
    required List<Map<String, dynamic>> detalles,
  }) async {
    try {
      final raw = await _client.rpc(
        'guardar_guia_remision_v4',
        params: {
          'p_guia_id': guiaId,
          'p_request_id': requestId,
          'p_emitir': emitir,
          'p_tipo_guia': tipoGuia,
          'p_origen_tipo': origenTipo,
          'p_venta_id': ventaId,
          'p_transferencia_id': transferenciaId,
          'p_guia_remitente_id': guiaRemitenteId,
          'p_documento_relacionado_tipo': documentoRelacionadoTipo,
          'p_documento_relacionado_numero': documentoRelacionadoNumero,
          'p_motivo_codigo': motivoCodigo,
          'p_motivo_descripcion': motivoDescripcion,
          'p_modalidad_transporte': modalidadTransporte,
          'p_fecha_emision': AppTime.toIsoLima(fechaEmision),
          'p_fecha_traslado': AppTime.toIsoLima(fechaTraslado),
          'p_destinatario': destinatario,
          'p_remitente': remitente,
          'p_partida': partida,
          'p_llegada': llegada,
          'p_transportista_id': transportistaId,
          'p_conductor_id': conductorId,
          'p_vehiculo_id': vehiculoId,
          'p_ind_transbordo': indTransbordo,
          'p_transportista_transbordo_id': transportistaTransbordoId,
          'p_agencia_origen_id': agenciaOrigenId,
          'p_agencia_destino_id': agenciaDestinoId,
          'p_destino_entrega_tipo': destinoEntregaTipo,
          'p_peso_total': pesoTotal,
          'p_cantidad_bultos': cantidadBultos,
          'p_peso_editado': pesoEditado,
          'p_observacion': observacion,
          'p_detalles': detalles,
        },
      );

      if (raw is Map<String, dynamic>) return raw;
      if (raw is Map) return Map<String, dynamic>.from(raw);
      throw StateError('Supabase devolvió una respuesta inválida.');
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    }
  }

  Future<int> guardarTransportista({
    required String ruc,
    required String razonSocial,
    String? registroMtc,
    String? direccion,
    int? id,
  }) async {
    final values = {
      'ruc': ruc.trim(),
      'razon_social': razonSocial.trim(),
      'registro_mtc': registroMtc?.trim(),
      'direccion': direccion?.trim(),
      'activo': true,
    };

    if (id == null) {
      final row = await _client
          .from('gre_transportistas')
          .insert(values)
          .select('id')
          .single();
      return (row['id'] as num).toInt();
    }

    await _client.from('gre_transportistas').update(values).eq('id', id);
    return id;
  }

  Future<int> guardarAgencia({
    required int transportistaId,
    required String nombre,
    required String direccion,
    required String ubigeo,
    String? departamento,
    String? provincia,
    String? distrito,
    String? telefono,
    String? codigoInterno,
    bool permiteOrigen = true,
    bool permiteDestino = true,
    int? id,
  }) async {
    final values = {
      'transportista_id': transportistaId,
      'nombre': nombre.trim(),
      'direccion': direccion.trim(),
      'ubigeo': ubigeo.trim(),
      'departamento': departamento?.trim(),
      'provincia': provincia?.trim(),
      'distrito': distrito?.trim(),
      'telefono': telefono?.trim(),
      'codigo_interno': codigoInterno?.trim(),
      'permite_origen': permiteOrigen,
      'permite_destino': permiteDestino,
      'activo': true,
    };

    if (id == null) {
      final row = await _client
          .from('gre_transportistas_agencias')
          .insert(values)
          .select('id')
          .single();
      return (row['id'] as num).toInt();
    }

    await _client
        .from('gre_transportistas_agencias')
        .update(values)
        .eq('id', id);
    return id;
  }

  Future<int> guardarConductor({
    required String tipoDocumento,
    required String numeroDocumento,
    required String nombres,
    String? apellidos,
    String? licencia,
    String? telefono,
    int? id,
  }) async {
    final values = {
      'tipo_documento': tipoDocumento,
      'numero_documento': numeroDocumento.trim(),
      'nombres': nombres.trim(),
      'apellidos': apellidos?.trim(),
      'numero_licencia': licencia?.trim(),
      'telefono': telefono?.trim(),
      'activo': true,
    };

    if (id == null) {
      final row = await _client
          .from('gre_conductores')
          .insert(values)
          .select('id')
          .single();
      return (row['id'] as num).toInt();
    }

    await _client.from('gre_conductores').update(values).eq('id', id);
    return id;
  }

  Future<int> guardarVehiculo({
    required String placa,
    String? marca,
    String? modelo,
    String? constanciaInscripcion,
    int? transportistaId,
    int? id,
  }) async {
    final values = {
      'placa': placa.trim().toUpperCase(),
      'marca': marca?.trim(),
      'modelo': modelo?.trim(),
      'constancia_inscripcion': constanciaInscripcion?.trim(),
      'transportista_id': transportistaId,
      'activo': true,
    };

    if (id == null) {
      final row = await _client
          .from('gre_vehiculos')
          .insert(values)
          .select('id')
          .single();
      return (row['id'] as num).toInt();
    }

    await _client.from('gre_vehiculos').update(values).eq('id', id);
    return id;
  }

  Future<void> desactivarAgencia(int id) async {
    await _client
        .from('gre_transportistas_agencias')
        .update({'activo': false})
        .eq('id', id);
  }

  Future<void> desactivarConductor(int id) async {
    await _client
        .from('gre_conductores')
        .update({'activo': false})
        .eq('id', id);
  }

  Future<void> desactivarTransportista(int id) async {
    await _client
        .from('gre_transportistas')
        .update({'activo': false})
        .eq('id', id);
  }

  Future<void> desactivarVehiculo(int id) async {
    await _client.from('gre_vehiculos').update({'activo': false}).eq('id', id);
  }
}
