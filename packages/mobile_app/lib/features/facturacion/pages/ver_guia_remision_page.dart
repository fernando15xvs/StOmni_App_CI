import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';

import 'package:core_logic/core_logic.dart';
import '../../../core/widgets/resultado_incierto_dialog.dart';
import '../../../core/widgets/estado_tributario_badge.dart';
import 'nueva_guia_remision_page.dart';

class VerGuiaRemisionPage extends ConsumerStatefulWidget {
  final String guiaId;

  const VerGuiaRemisionPage({super.key, required this.guiaId});

  @override
  ConsumerState<VerGuiaRemisionPage> createState() => _VerGuiaRemisionPageState();
}

class _VerGuiaRemisionPageState extends ConsumerState<VerGuiaRemisionPage> {
  bool _cargando = true;
  bool _procesando = false;
  String? _error;
  Map<String, dynamic>? _guia;

  Color get _color => Colors.deepPurple;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar({bool consultarSunat = false}) async {
    if (mounted && !_cargando) {
      setState(() {
        _cargando = true;
        _error = null;
      });
    }

    try {
      final result = await FacturacionService.consultarGuiaRemision(
        widget.guiaId,
        consultarSunat: consultarSunat,
      );
      final raw = result['guia'];
      if (raw is! Map) {
        throw const FacturacionServiceException('La guía no está disponible.');
      }

      if (!mounted) return;
      setState(() {
        _guia = Map<String, dynamic>.from(raw);
        _error = null;
        _cargando = false;
      });
    } catch (e, st) {
      debugPrint('VerGuiaRemisionPage: fallo al cargar ${widget.guiaId}: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;
      setState(() {
        _error = _mensajeCarga(e);
        _cargando = false;
      });
    }
  }

  Future<void> _reintentar({bool forzar = false}) async {
    if (_procesando) return;
    setState(() => _procesando = true);

    try {
      final result = await FacturacionService.reintentarGuiaRemision(
        widget.guiaId,
        forzar: forzar,
      );
      final raw = result['guia'];
      if (raw is Map && mounted) {
        setState(() => _guia = Map<String, dynamic>.from(raw));
      } else {
        await _cargar();
      }
    } catch (e) {
      if (!mounted) return;

      final mensajeDominio = e is FacturacionServiceException
          ? e.message.trim()
          : '';
      if (_esErrorTrasladoVencido(mensajeDominio)) {
        setState(() => _procesando = false);

        final corregir = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Actualiza el inicio del traslado'),
            content: Text(
              '$mensajeDominio\n\n'
              'La guía no se volverá a enviar hasta que selecciones '
              'una fecha y hora futura.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('CANCELAR'),
              ),
              ElevatedButton.icon(
                onPressed: () => Navigator.pop(dialogContext, true),
                icon: const Icon(Icons.edit, color: Colors.white),
                label: const Text(
                  'CORREGIR GUÍA',
                  style: TextStyle(color: Colors.white),
                ),
                style: ElevatedButton.styleFrom(backgroundColor: _color),
              ),
            ],
          ),
        );

        if (corregir == true && mounted) {
          await _corregirDatos();
        }
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(e)),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted && _procesando) {
        setState(() => _procesando = false);
      }
    }
  }

  Future<void> _reconciliarResultadoIncierto() async {
    if (ref.read(rolProvider) != 'admin' || _procesando) return;
    setState(() => _procesando = true);
    try {
      final actualizado = await mostrarReconciliacionResultadoIncierto(
        context: context,
        tipoDocumento: 'guia',
        documentoId: widget.guiaId,
      );
      if (actualizado && mounted) {
        await _cargar();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Decisión de reconciliación registrada.'),
            backgroundColor: Colors.deepPurple,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(e)),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  Future<void> _confirmarReintentoForzado() async {
    if (ref.read(rolProvider) != 'admin' || _procesando) return;
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reintento forzado'),
        content: const Text(
          'Úsalo únicamente después de corregir la causa de un rechazo '
          'definitivo. La guía conservará su serie y correlativo. Los '
          'resultados inciertos se resuelven mediante reconciliación.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCELAR'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('FORZAR', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmar == true) await _reintentar(forzar: true);
  }

  String _mensajeCarga(Object error) {
    if (error is FacturacionServiceException &&
        error.message.trim() == 'La guía no está disponible.') {
      return error.message.trim();
    }
    return ErrorMapper.map(error);
  }

  bool _esErrorTrasladoVencido(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('traslado') &&
        (normalized.contains('venc') ||
            normalized.contains('hora futura') ||
            normalized.contains('fecha y hora futura') ||
            normalized.contains('inicio mínimo'));
  }

  Future<void> _abrirDocumento(String tipo) async {
    await _cargar();
    if (!mounted) return;

    final docs = _guia?['documentos'];
    final url = docs is Map ? docs[tipo]?.toString() : null;
    if (url == null || url.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Documento no disponible.')));
      return;
    }

    final uri = Uri.tryParse(url);
    if (uri == null) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );

    try {
      final response = await http.get(uri);
      if (!mounted) return;
      Navigator.pop(context);

      if (response.statusCode == 200) {
        final tempDir = await getTemporaryDirectory();
        final fileName = '${_guia?['serie'] ?? 'GUIA'}-${_guia?['correlativo'] ?? '0000'}.$tipo';
        final file = File('${tempDir.path}/$fileName');
        await file.writeAsBytes(response.bodyBytes);

        await Share.shareXFiles([XFile(file.path)]);
        return;
      }
    } catch (e) {
      debugPrint('VerGuiaRemisionPage: descarga falló, se usará URL: $e');
      if (mounted) Navigator.pop(context);
    }

    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo abrir ni descargar el documento.'),
        ),
      );
    }
  }

  String? _mensajeRealApi(Map<String, dynamic> guia) {
    final raw = guia['respuesta_json'];
    if (raw is Map) {
      final error = raw['error'];
      if (error is String && error.trim().isNotEmpty) {
        return error.trim();
      }
      if (error is Map) {
        final message = error['message']?.toString().trim() ?? '';
        if (message.isNotEmpty) return message;
      }

      final sunat = raw['sunatResponse'];
      if (sunat is Map) {
        final sunatError = sunat['error'];
        if (sunatError is String && sunatError.trim().isNotEmpty) {
          return sunatError.trim();
        }
        if (sunatError is Map) {
          final message = sunatError['message']?.toString().trim() ?? '';
          if (message.isNotEmpty) return message;
        }
      }

      final message =
          (raw['message'] ?? raw['mensaje'])?.toString().trim() ?? '';
      if (message.isNotEmpty) return message;
    }
    return null;
  }

  Future<void> _corregirDatos() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => NuevaGuiaRemisionPage(guiaId: widget.guiaId),
      ),
    );

    if (!mounted) return;
    if (changed == true) {
      await _cargar();
    }
  }

  Future<void> _confirmarEliminarBorrador() async {
    if (_procesando) return;

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar borrador'),
        content: const Text(
          '¿Seguro que deseas eliminar este borrador? Esta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Eliminar',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );

    if (confirmar == true) {
      await _eliminarBorrador();
    }
  }

  Future<void> _eliminarBorrador() async {
    if (!mounted) return;
    setState(() => _procesando = true);

    try {
      final repo = ref.read(guiasRemisionRepositoryProvider);
      await repo.eliminarBorrador(widget.guiaId);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Borrador eliminado.'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(e)),
          backgroundColor: Colors.red,
        ),
      );
      setState(() => _procesando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Detalle de Guía',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: _color,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_guia != null && _guia!['ticket_sunat'] != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: TextButton.icon(
                onPressed: _procesando
                    ? null
                    : () => _cargar(consultarSunat: true),
                icon: const Icon(Icons.sync, color: Colors.white, size: 18),
                label: const Text(
                  'Consultar SUNAT',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: TextButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.2),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: _cargando
          ? Center(child: CircularProgressIndicator(color: _color))
          : _error != null
          ? _errorView()
          : _contenido(),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 56),
            const SizedBox(height: 12),
            Text(_error ?? 'No se pudo cargar la guía.'),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _cargar,
              icon: const Icon(Icons.refresh, color: Colors.white),
              label: const Text(
                'REINTENTAR',
                style: TextStyle(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(backgroundColor: _color),
            ),
          ],
        ),
      ),
    );
  }

  Widget _contenido() {
    final guia = _guia!;
    final estado =
        guia['estado']?.toString().toLowerCase() ?? 'pendiente_envio';
    final colorEstado = EstadoTributarioBadge.colorDeEstado(estado);
    final esTransbordo = guia['ind_transbordo'] == true;
    final esPublico = guia['modalidad_transporte'] == '01';
    final detallesRaw = guia['detalles'];
    final detalles = detallesRaw is List
        ? List<Map<String, dynamic>>.from(
            detallesRaw.map((e) => Map<String, dynamic>.from(e as Map)),
          )
        : <Map<String, dynamic>>[];
    final docs = guia['documentos'];
    final tienePdf = docs is Map && docs['pdf'] != null;
    final tieneXml = docs is Map && docs['xml'] != null;
    final tieneCdr = docs is Map && docs['cdr'] != null;
    final esAdmin = ref.watch(rolProvider) == 'admin';

    return RefreshIndicator(
      color: _color,
      onRefresh: _cargar,
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: colorEstado.withValues(alpha: 0.1),
                      child: Icon(
                        Icons.local_shipping_rounded,
                        color: colorEstado,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            guia['serie'] == null
                                ? 'BORRADOR SIN NUMERAR'
                                : '${guia['serie']}-${guia['correlativo']}',
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 20,
                            ),
                          ),
                          Text(
                            guia['tipo_guia'] == 'transportista'
                                ? 'GRE Transportista'
                                : 'GRE Remitente',
                            style: TextStyle(color: Colors.grey.shade600),
                          ),
                        ],
                      ),
                    ),
                    EstadoTributarioBadge(estado: estado, fontSize: 10),
                  ],
                ),
                const Divider(height: 28),
                _info(
                  'Destinatario',
                  guia['destinatario_razon_social']?.toString() ?? '-',
                ),
                _info(
                  'Documento',
                  guia['destinatario_numero_documento']?.toString() ?? '-',
                ),
                _info('Motivo', guia['motivo_descripcion']?.toString() ?? '-'),
                _info(
                  'Modalidad',
                  esTransbordo
                      ? 'Privado con transbordo programado'
                      : esPublico
                      ? 'Transporte público'
                      : 'Transporte privado',
                ),
                _info('Inicio del traslado', _fecha(guia['fecha_traslado'])),
                _info(
                  'Peso total',
                  '${NumberFormat('#,##0.###').format((guia['peso_total'] as num?) ?? 0)} kg',
                ),
                if (guia['cantidad_bultos'] != null)
                  _info('Bultos', guia['cantidad_bultos'].toString()),
                if (guia['ticket_sunat'] != null)
                  _info('Ticket', guia['ticket_sunat'].toString()),
                if (guia['codigo_sunat'] != null)
                  _info('Código SUNAT', guia['codigo_sunat'].toString()),
                if (guia['descripcion_sunat'] != null ||
                    _mensajeRealApi(guia) != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _mensajeRealApi(guia) ??
                        guia['descripcion_sunat'].toString(),
                    style: TextStyle(
                      color: estado == 'rechazado'
                          ? Colors.red.shade700
                          : Colors.grey.shade700,
                      fontWeight: estado == 'rechazado'
                          ? FontWeight.w700
                          : FontWeight.normal,
                    ),
                  ),
                ],
                if (estado == 'resultado_incierto')
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.deepOrange.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.deepOrange.withValues(alpha: 0.35),
                      ),
                    ),
                    child: const Text(
                      'No se confirmó si SUNAT recibió la guía. No la vuelvas '
                      'a enviar. Un administrador debe reconciliar el resultado '
                      'antes de habilitar otro intento.',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                if (estado == 'xml_validado_prueba')
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.teal.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.teal.withValues(alpha: 0.35),
                      ),
                    ),
                    child: const Text(
                      'XML generado y validado en modo de prueba. Esta guía no '
                      'fue enviada a SUNAT y no tiene validez tributaria.',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Ruta',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
                ),
                const SizedBox(height: 14),
                _location(
                  Icons.trip_origin,
                  'Partida',
                  guia['partida_direccion']?.toString() ?? '-',
                  guia['partida_ubigeo']?.toString() ?? '-',
                ),
                const SizedBox(height: 14),
                _location(
                  Icons.location_on,
                  'Llegada',
                  guia['llegada_direccion']?.toString() ?? '-',
                  guia['llegada_ubigeo']?.toString() ?? '-',
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Transporte',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
                ),
                const SizedBox(height: 12),
                if (esTransbordo) ...[
                  _info('Tipo', 'Transbordo programado'),
                  const Divider(height: 22),
                  const Text(
                    'Primer tramo · Tu empresa hasta la agencia',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  _info(
                    'Placa',
                    guia['vehiculo_placa_snapshot']?.toString() ?? '-',
                  ),
                  _info(
                    'Conductor',
                    [
                          guia['conductor_nombres_snapshot'],
                          guia['conductor_apellidos_snapshot'],
                        ]
                        .where(
                          (value) =>
                              value != null && value.toString().trim().isNotEmpty,
                        )
                        .join(' '),
                  ),
                  _info(
                    'Licencia',
                    guia['conductor_licencia_snapshot']?.toString() ?? '-',
                  ),
                  _info(
                    'Entrega en agencia',
                    guia['agencia_origen_nombre_snapshot']?.toString() ?? '-',
                  ),
                  _info(
                    'Dirección agencia',
                    guia['agencia_origen_direccion_snapshot']?.toString() ?? '-',
                  ),
                  const Divider(height: 22),
                  const Text(
                    'Segundo tramo · Empresa transportista',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  _info(
                    'Transportista',
                    guia['transportista_transbordo_razon_social_snapshot']
                            ?.toString() ??
                        '-',
                  ),
                  _info(
                    'RUC',
                    guia['transportista_transbordo_ruc_snapshot']?.toString() ??
                        '-',
                  ),
                  _info(
                    'Destino final',
                    guia['destino_entrega_tipo'] == 'agencia'
                        ? guia['agencia_destino_nombre_snapshot']?.toString() ??
                              '-'
                        : 'Dirección del cliente',
                  ),
                  if (guia['destino_entrega_tipo'] == 'agencia')
                    _info(
                      'Dirección destino',
                      guia['agencia_destino_direccion_snapshot']?.toString() ??
                          '-',
                    ),
                  const SizedBox(height: 6),
                  Text(
                    'La GRE Transportista del segundo tramo debe emitirla la '
                    'empresa que presta ese servicio.',
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 12,
                    ),
                  ),
                ] else if (esPublico && guia['tipo_guia'] != 'transportista') ...[
                  _info(
                    'Transportista',
                    guia['transportista_razon_social_snapshot']?.toString() ??
                        '-',
                  ),
                  _info(
                    'RUC',
                    guia['transportista_ruc_snapshot']?.toString() ?? '-',
                  ),
                ] else ...[
                  _info(
                    'Placa',
                    guia['vehiculo_placa_snapshot']?.toString() ?? '-',
                  ),
                  _info(
                    'Conductor',
                    [
                          guia['conductor_nombres_snapshot'],
                          guia['conductor_apellidos_snapshot'],
                        ]
                        .where(
                          (value) =>
                              value != null && value.toString().trim().isNotEmpty,
                        )
                        .join(' '),
                  ),
                  _info(
                    'Documento conductor',
                    guia['conductor_documento_snapshot']?.toString() ?? '-',
                  ),
                  _info(
                    'Licencia',
                    guia['conductor_licencia_snapshot']?.toString() ?? '-',
                  ),
                  _info(
                    'Marca',
                    guia['vehiculo_marca_snapshot']?.toString() ?? '-',
                  ),
                  _info(
                    'Constancia vehicular',
                    guia['vehiculo_constancia_snapshot']?.toString() ?? '-',
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Productos',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
                ),
                const SizedBox(height: 10),
                ...detalles.map(
                  (d) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      d['descripcion']?.toString() ?? 'Producto',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(d['codigo']?.toString() ?? ''),
                    trailing: Text(
                      '${NumberFormat('#,##0.###').format((d['cantidad'] as num?) ?? 0)} ${d['unidad'] ?? ''}',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if ((estado == 'borrador' ||
                      estado == 'rechazado' ||
                      estado == 'pendiente_envio' ||
                      estado == 'pendiente_reintento') &&
                  guia['ticket_sunat'] == null)
                ElevatedButton.icon(
                  onPressed: _procesando ? null : _corregirDatos,
                  icon: const Icon(Icons.edit, color: Colors.white),
                  label: const Text(
                    'CORREGIR DATOS',
                    style: TextStyle(color: Colors.white),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange.shade700,
                  ),
                ),
              if (estado == 'ticket_pendiente')
                OutlinedButton.icon(
                  onPressed: _procesando
                      ? null
                      : () => _cargar(consultarSunat: true),
                  icon: const Icon(Icons.sync),
                  label: const Text('CONSULTAR'),
                ),
              if (estado == 'pendiente_envio' ||
                  estado == 'pendiente_reintento')
                ElevatedButton.icon(
                  onPressed: _procesando ? null : _reintentar,
                  icon: const Icon(Icons.refresh, color: Colors.white),
                  label: const Text(
                    'REINTENTAR',
                    style: TextStyle(color: Colors.white),
                  ),
                  style: ElevatedButton.styleFrom(backgroundColor: _color),
                ),
              if (esAdmin && estado == 'resultado_incierto')
                ElevatedButton.icon(
                  onPressed: _procesando ? null : _reconciliarResultadoIncierto,
                  icon: const Icon(Icons.manage_search, color: Colors.white),
                  label: const Text(
                    'RECONCILIAR',
                    style: TextStyle(color: Colors.white),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepOrange.shade700,
                  ),
                ),
              if (esAdmin &&
                  estado == 'rechazado' &&
                  guia['ticket_sunat'] == null)
                ElevatedButton.icon(
                  onPressed: _procesando ? null : _confirmarReintentoForzado,
                  icon: const Icon(Icons.warning_amber, color: Colors.white),
                  label: const Text(
                    'FORZAR REINTENTO',
                    style: TextStyle(color: Colors.white),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                  ),
                ),
              if (tienePdf)
                _docButton(
                  'PDF',
                  Icons.picture_as_pdf,
                  Colors.red,
                  () => _abrirDocumento('pdf'),
                ),
              if (tieneXml)
                _docButton(
                  'XML',
                  Icons.code,
                  Colors.blue,
                  () => _abrirDocumento('xml'),
                ),
              if (tieneCdr)
                _docButton(
                  'CDR',
                  Icons.verified,
                  Colors.green,
                  () => _abrirDocumento('cdr'),
                ),
            ],
          ),
          if (estado == 'borrador') ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _procesando ? null : _confirmarEliminarBorrador,
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: const Text(
                  'ELIMINAR BORRADOR',
                  style: TextStyle(color: Colors.red),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.redAccent),
                ),
              ),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  String _fecha(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '');
    return date == null ? '-' : AppFormatters.limaDateTimeLong(date);
  }

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(
            color: Color(0x10000000),
            blurRadius: 14,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _info(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _location(
    IconData icon,
    String label,
    String direccion,
    String ubigeo,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: _color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(direccion),
              Text(
                'Ubigeo: $ubigeo',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _docButton(
    String label,
    IconData icon,
    Color color,
    VoidCallback onPressed,
  ) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, color: Colors.white),
      label: Text(label, style: const TextStyle(color: Colors.white)),
      style: ElevatedButton.styleFrom(backgroundColor: color),
    );
  }
}
