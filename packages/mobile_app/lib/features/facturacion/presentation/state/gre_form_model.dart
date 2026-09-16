import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:core_logic/core_logic.dart';

class GreFormModel {
  GreFormModel() {
    final ahora = AppTime.now();
    fechaEmision = ahora;
    fechaTraslado = GreFormRules.redondearHaciaArribaAlMinuto(
      ahora.add(const Duration(minutes: 5)),
    );
  }

  String requestId = const Uuid().v4();
  String? serieOriginal;
  int? correlativoOriginal;
  String origenTipoGuardado = 'manual';
  int? ventaIdGuardada;
  int? transferenciaIdGuardada;

  Map<String, dynamic>? empresa;
  List<Map<String, dynamic>> almacenes = [];
  List<Map<String, dynamic>> transportistas = [];
  List<Map<String, dynamic>> agencias = [];
  List<Map<String, dynamic>> conductores = [];
  List<Map<String, dynamic>> vehiculos = [];
  List<Map<String, dynamic>> productos = [];
  final List<Map<String, dynamic>> detalles = [];

  String tipoGuia = 'remitente';
  String motivoCodigo = '01';
  String modalidad = '02';
  late DateTime fechaEmision;
  late DateTime fechaTraslado;

  int? almacenPartidaId;
  int? transportistaId;
  int? conductorId;
  int? vehiculoId;
  bool indTransbordo = false;
  int? transportistaTransbordoId;
  int? agenciaOrigenId;
  int? agenciaDestinoId;
  String destinoEntregaTipo = 'agencia';

  String destTipo = '6';
  final destDocCtrl = TextEditingController();
  final destNombreCtrl = TextEditingController();
  final destDireccionCtrl = TextEditingController();
  final destUbigeoCtrl = TextEditingController();

  String remTipo = '6';
  final remDocCtrl = TextEditingController();
  final remNombreCtrl = TextEditingController();

  final partidaDireccionCtrl = TextEditingController();
  final partidaUbigeoCtrl = TextEditingController();
  final llegadaDireccionCtrl = TextEditingController();
  final llegadaUbigeoCtrl = TextEditingController();

  String? documentoTipo;
  final documentoNumeroCtrl = TextEditingController();
  final pesoTotalCtrl = TextEditingController();
  final cantidadBultosCtrl = TextEditingController();
  final observacionCtrl = TextEditingController();
  bool pesoEditado = false;

  String origenTipo({int? ventaId, int? transferenciaId}) {
    if (ventaId != null) return 'venta';
    if (transferenciaId != null) return 'traslado';
    return origenTipoGuardado;
  }

  bool esEdicion(String? guiaId) => guiaId != null && guiaId.trim().isNotEmpty;

  void cargarDesdeBase(Map<String, dynamic> data) {
    empresa = Map<String, dynamic>.from(data['empresa'] as Map);
    almacenes = List<Map<String, dynamic>>.from(data['almacenes'] as List);
    transportistas = List<Map<String, dynamic>>.from(
      data['transportistas'] as List,
    );
    agencias = List<Map<String, dynamic>>.from(
      data['agencias'] as List? ?? const [],
    );
    conductores = List<Map<String, dynamic>>.from(data['conductores'] as List);
    vehiculos = List<Map<String, dynamic>>.from(data['vehiculos'] as List);
    productos = List<Map<String, dynamic>>.from(data['productos'] as List);

    final guiaEdicion = data['guia_edicion'];
    final origen = data['origen'];

    if (guiaEdicion is Map) {
      aplicarGuiaExistente(Map<String, dynamic>.from(guiaEdicion));
    } else if (origen is Map) {
      aplicarOrigen(Map<String, dynamic>.from(origen));
    } else if (almacenes.isNotEmpty) {
      seleccionarAlmacen((almacenes.first['id'] as num).toInt());
    }

    recalcularPeso();
  }

  void aplicarGuiaExistente(Map<String, dynamic> data) {
    final guia = Map<String, dynamic>.from(data['guia'] as Map);
    final detalleRows = List<Map<String, dynamic>>.from(
      data['detalles'] as List? ?? const [],
    );

    requestId = guia['request_id']?.toString() ?? const Uuid().v4();
    serieOriginal = guia['serie']?.toString();
    correlativoOriginal = (guia['correlativo'] as num?)?.toInt();
    origenTipoGuardado = guia['origen_tipo']?.toString() ?? 'manual';
    ventaIdGuardada = (guia['venta_id'] as num?)?.toInt();
    transferenciaIdGuardada = (guia['transferencia_id'] as num?)?.toInt();

    tipoGuia = guia['tipo_guia']?.toString() ?? 'remitente';
    motivoCodigo = guia['motivo_codigo']?.toString() ?? '01';
    modalidad = guia['modalidad_transporte']?.toString() ?? '02';

    fechaEmision = _desdeSupabaseALima(guia['fecha_emision']);
    fechaTraslado = _desdeSupabaseALima(
      guia['fecha_traslado'],
      fallback: AppTime.now().add(const Duration(minutes: 5)),
    );

    transportistaId = (guia['transportista_id'] as num?)?.toInt();
    conductorId = (guia['conductor_id'] as num?)?.toInt();
    vehiculoId = (guia['vehiculo_id'] as num?)?.toInt();
    indTransbordo = guia['ind_transbordo'] == true;
    transportistaTransbordoId = (guia['transportista_transbordo_id'] as num?)
        ?.toInt();
    agenciaOrigenId = (guia['agencia_origen_id'] as num?)?.toInt();
    agenciaDestinoId = (guia['agencia_destino_id'] as num?)?.toInt();
    destinoEntregaTipo =
        guia['destino_entrega_tipo']?.toString() ?? 'direccion_cliente';

    destTipo = guia['destinatario_tipo_documento']?.toString() ?? '6';
    destDocCtrl.text = guia['destinatario_numero_documento']?.toString() ?? '';
    destNombreCtrl.text = guia['destinatario_razon_social']?.toString() ?? '';
    destDireccionCtrl.text = guia['destinatario_direccion']?.toString() ?? '';
    destUbigeoCtrl.text = guia['destinatario_ubigeo']?.toString() ?? '';

    remTipo = guia['remitente_tipo_documento']?.toString() ?? '6';
    remDocCtrl.text = guia['remitente_numero_documento']?.toString() ?? '';
    remNombreCtrl.text = guia['remitente_razon_social']?.toString() ?? '';

    partidaDireccionCtrl.text = guia['partida_direccion']?.toString() ?? '';
    partidaUbigeoCtrl.text = guia['partida_ubigeo']?.toString() ?? '';
    llegadaDireccionCtrl.text = guia['llegada_direccion']?.toString() ?? '';
    llegadaUbigeoCtrl.text = guia['llegada_ubigeo']?.toString() ?? '';

    documentoTipo = guia['documento_relacionado_tipo']?.toString();
    documentoNumeroCtrl.text =
        guia['documento_relacionado_numero']?.toString() ?? '';
    pesoTotalCtrl.text = (guia['peso_total'] as num?)?.toString() ?? '';
    cantidadBultosCtrl.text =
        (guia['cantidad_bultos'] as num?)?.toInt().toString() ?? '';
    pesoEditado = guia['peso_editado'] == true;
    observacionCtrl.text = guia['observacion']?.toString() ?? '';

    detalles
      ..clear()
      ..addAll(
        detalleRows.map((item) {
          final productoRaw = item['productos'];
          final producto = productoRaw is Map
              ? Map<String, dynamic>.from(productoRaw)
              : <String, dynamic>{};
          return {
            ...item,
            if (producto.isNotEmpty) 'producto_data': producto,
            'cantidad': (item['cantidad'] as num?)?.toDouble() ?? 0,
            'piezas_reales': (item['piezas_reales'] as num?)?.toInt() ?? 0,
            'peso_unitario_kg':
                (item['peso_unitario_kg'] as num?)?.toDouble() ?? 0,
            'peso_total_kg': (item['peso_total_kg'] as num?)?.toDouble() ?? 0,
          };
        }),
      );

    final almacenIds = detalles
        .map((item) => (item['almacen_id'] as num?)?.toInt())
        .whereType<int>()
        .toSet();
    if (almacenIds.length == 1) almacenPartidaId = almacenIds.first;
  }

  void aplicarOrigen(Map<String, dynamic> origen) {
    if (origen['tipo'] == 'venta') {
      _aplicarVenta(origen);
    } else if (origen['tipo'] == 'traslado') {
      _aplicarTraslado(origen);
    }
  }

  void _aplicarVenta(Map<String, dynamic> origen) {
    final venta = Map<String, dynamic>.from(origen['venta'] as Map);
    final clienteRaw = venta['clientes'];
    if (clienteRaw is Map) {
      final cliente = Map<String, dynamic>.from(clienteRaw);
      final doc = cliente['dni_ruc']?.toString() ?? '';
      destTipo = doc.length == 8 ? '1' : '6';
      destDocCtrl.text = doc;
      destNombreCtrl.text = cliente['nombre']?.toString() ?? '';
      destDireccionCtrl.text = cliente['direccion']?.toString() ?? '';
      llegadaDireccionCtrl.text = cliente['direccion']?.toString() ?? '';
    }

    final comprobanteRaw = origen['comprobante'];
    if (comprobanteRaw is Map) {
      final comprobante = Map<String, dynamic>.from(comprobanteRaw);
      if (comprobante['estado']?.toString().toLowerCase() == 'aceptado') {
        final tipo = comprobante['tipo_documento_sunat']?.toString();
        documentoTipo = tipo == 'factura' || tipo == '01' ? '01' : '03';
        documentoNumeroCtrl.text =
            '${comprobante['serie']}-${comprobante['correlativo']}';
      }
    }

    final detallesRaw = origen['detalles'];
    if (detallesRaw is List) {
      for (final raw in detallesRaw) {
        final item = Map<String, dynamic>.from(raw as Map);
        final producto = item['productos'] is Map
            ? Map<String, dynamic>.from(item['productos'] as Map)
            : <String, dynamic>{};
        detalles.add(GreItemMapper.desdeVenta(item, producto));
      }
    }

    final almacenIds = detalles
        .map((item) => item['almacen_id'])
        .whereType<int>()
        .toSet();
    if (almacenIds.length == 1) {
      seleccionarAlmacen(almacenIds.first);
    } else if (almacenes.isNotEmpty) {
      seleccionarAlmacen((almacenes.first['id'] as num).toInt());
    }
  }

  void _aplicarTraslado(Map<String, dynamic> origen) {
    final traslado = Map<String, dynamic>.from(origen['traslado'] as Map);
    final producto = traslado['productos'] is Map
        ? Map<String, dynamic>.from(traslado['productos'] as Map)
        : <String, dynamic>{};
    final origenAlmacen = traslado['origen'] is Map
        ? Map<String, dynamic>.from(traslado['origen'] as Map)
        : <String, dynamic>{};
    final destinoAlmacen = traslado['destino'] is Map
        ? Map<String, dynamic>.from(traslado['destino'] as Map)
        : <String, dynamic>{};

    motivoCodigo = '04';
    detalles.add(GreItemMapper.desdeTraslado(traslado, producto));
    almacenPartidaId = (traslado['almacen_origen_id'] as num?)?.toInt();
    aplicarDireccionAlmacen(origenAlmacen, partida: true);
    aplicarDireccionAlmacen(destinoAlmacen, partida: false);

    destTipo = '6';
    destDocCtrl.text = empresa?['ruc']?.toString() ?? '';
    destNombreCtrl.text = empresa?['razon_social']?.toString() ?? '';
    destDireccionCtrl.text = destinoAlmacen['direccion']?.toString() ?? '';
    destUbigeoCtrl.text = destinoAlmacen['ubigeo']?.toString() ?? '';
  }

  void seleccionarAlmacen(int? id) {
    almacenPartidaId = id;
    if (id == null) return;
    final almacen = almacenes.cast<Map<String, dynamic>?>().firstWhere(
      (item) => (item?['id'] as num?)?.toInt() == id,
      orElse: () => null,
    );
    if (almacen != null) aplicarDireccionAlmacen(almacen, partida: true);
  }

  void aplicarDireccionAlmacen(
    Map<String, dynamic> almacen, {
    required bool partida,
  }) {
    if (partida) {
      partidaDireccionCtrl.text = almacen['direccion']?.toString() ?? '';
      partidaUbigeoCtrl.text = almacen['ubigeo']?.toString() ?? '';
    } else {
      llegadaDireccionCtrl.text = almacen['direccion']?.toString() ?? '';
      llegadaUbigeoCtrl.text = almacen['ubigeo']?.toString() ?? '';
    }
  }

  Map<String, dynamic>? productoPorId(dynamic rawId) {
    final id = (rawId as num?)?.toInt();
    if (id == null) return null;
    for (final producto in productos) {
      if ((producto['id'] as num?)?.toInt() == id) return producto;
    }
    return null;
  }

  void recalcularPeso() {
    if (pesoEditado) return;
    final total = detalles.fold<double>(
      0,
      (sum, item) => sum + ((item['peso_total_kg'] as num?)?.toDouble() ?? 0),
    );
    pesoTotalCtrl.text = total > 0 ? total.toStringAsFixed(3) : '';
  }

  void usarDireccionClienteComoLlegada() {
    agenciaDestinoId = null;
    llegadaDireccionCtrl.text = destDireccionCtrl.text.trim();
    if (destUbigeoCtrl.text.trim().isNotEmpty) {
      llegadaUbigeoCtrl.text = destUbigeoCtrl.text.trim();
    }
  }

  void aplicarAgenciaDestino(int? id) {
    agenciaDestinoId = id;
    final agencia = GreTransportRules.agenciaPorId(agencias, id);
    if (agencia == null) return;
    llegadaDireccionCtrl.text = agencia['direccion']?.toString() ?? '';
    llegadaUbigeoCtrl.text = agencia['ubigeo']?.toString() ?? '';
  }

  void actualizarTipoDestinatarioDesdeDocumento() {
    final doc = destDocCtrl.text.trim();
    if (doc.length == 8) {
      destTipo = '1';
    } else if (doc.length == 11) {
      destTipo = '6';
    }
  }

  void dispose() {
    for (final controller in [
      destDocCtrl,
      destNombreCtrl,
      destDireccionCtrl,
      destUbigeoCtrl,
      remDocCtrl,
      remNombreCtrl,
      partidaDireccionCtrl,
      partidaUbigeoCtrl,
      llegadaDireccionCtrl,
      llegadaUbigeoCtrl,
      documentoNumeroCtrl,
      pesoTotalCtrl,
      cantidadBultosCtrl,
      observacionCtrl,
    ]) {
      controller.dispose();
    }
  }

  DateTime _desdeSupabaseALima(dynamic value, {DateTime? fallback}) {
    return GreFormRules.desdeSupabaseALima(value) ?? fallback ?? AppTime.now();
  }
}
