import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core_logic/core_logic.dart';

import 'solicitar_baja_tributaria_page.dart';

import '../../../core/widgets/resultado_incierto_dialog.dart';
import '../../../core/widgets/estado_tributario_badge.dart';

class VerNotaCreditoPage extends ConsumerStatefulWidget {
  final String notaCreditoId;

  const VerNotaCreditoPage({super.key, required this.notaCreditoId});

  @override
  ConsumerState<VerNotaCreditoPage> createState() => _VerNotaCreditoPageState();
}

class _VerNotaCreditoPageState extends ConsumerState<VerNotaCreditoPage> {
  bool _cargando = true;
  bool _procesando = false;
  Map<String, dynamic>? _nota;
  String? _error;

  Color get _colorPrincipal => Colors.deepPurple;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    if (mounted && !_cargando) {
      setState(() {
        _cargando = true;
        _error = null;
      });
    }

    try {
      final result = await FacturacionService.consultarNotaCredito(
        widget.notaCreditoId,
      );
      final raw = result['nota_credito'];
      if (raw is! Map) {
        throw const FacturacionServiceException(
          'La nota de crédito no está disponible.',
        );
      }

      final nota = Map<String, dynamic>.from(raw);

      if (!mounted) return;
      setState(() {
        _nota = nota;
        _error = null;
        _cargando = false;
      });
    } catch (e, st) {
      debugPrint('VerNotaCreditoPage: fallo al cargar ${widget.notaCreditoId}: $e');
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
      final result = await FacturacionService.reintentarNotaCredito(
        widget.notaCreditoId,
        forzar: forzar,
      );
      final raw = result['nota_credito'];
      if (raw is Map && mounted) {
        setState(() => _nota = Map<String, dynamic>.from(raw));
      } else {
        await _cargar();
      }

      if (!mounted) return;
      final estado = result['estado']?.toString().toLowerCase() ?? '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            estado == 'aceptado'
                ? 'Nota de crédito aceptada por SUNAT.'
                : result['mensaje']?.toString() ??
                      'La nota continúa pendiente de envío.',
          ),
          backgroundColor: estado == 'aceptado'
              ? Colors.green
              : estado == 'rechazado'
              ? Colors.red
              : Colors.orange,
        ),
      );
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

  Future<void> _reconciliarResultadoIncierto() async {
    if (ref.read(rolProvider) != 'admin' || _procesando) return;

    setState(() => _procesando = true);
    try {
      final actualizado = await mostrarReconciliacionResultadoIncierto(
        context: context,
        tipoDocumento: 'nota_credito',
        documentoId: widget.notaCreditoId,
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

  Future<void> _solicitarBajaTributaria() async {
    if (ref.read(rolProvider) != 'admin') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Solo el administrador puede solicitar una baja tributaria.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final nota = _nota;
    if (nota == null) return;
    final estado = nota['estado']?.toString().toLowerCase() ?? '';
    final estadoBaja =
        nota['estado_baja_tributaria']?.toString().toLowerCase() ?? 'ninguna';
    if (estado != 'aceptado' || estadoBaja != 'ninguna') return;

    final tipoAfectado = nota['tipo_doc_afectado']?.toString() ?? '';
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SolicitarBajaTributariaPage(
          tipoOrigen: 'nota_credito',
          origenId: widget.notaCreditoId,
          numeroDocumento: '${nota['serie']}-${nota['correlativo']}',
          tipoProcesoEsperado: tipoAfectado == '03'
              ? 'resumen_boletas'
              : 'comunicacion_baja',
        ),
      ),
    );
    if (result == true && mounted) await _cargar();
  }

  Future<void> _abrirDocumento(String tipo) async {
    await _cargar();
    if (!mounted) return;

    final documentos = _nota?['documentos'];
    final url = documentos is Map ? documentos[tipo]?.toString() : null;
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
        final fileName = '${_nota?['serie'] ?? 'DOC'}-${_nota?['correlativo'] ?? '0000'}.$tipo';
        final file = File('${tempDir.path}/$fileName');
        await file.writeAsBytes(response.bodyBytes);

        await Share.shareXFiles([XFile(file.path)]);
        return;
      }
    } catch (e) {
      debugPrint('VerNotaCreditoPage: descarga falló, se usará URL: $e');
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

  String _mensajeCarga(Object error) {
    if (error is FacturacionServiceException &&
        error.message.trim() == 'La nota de crédito no está disponible.') {
      return error.message.trim();
    }
    return ErrorMapper.map(error);
  }

  String _motivo(String codigo, String descripcion) {
    const nombres = {
      '01': 'Anulación total',
      '03': 'Corrección de descripción',
      '04': 'Descuento posterior',
      '07': 'Devolución parcial',
    };
    final nombre = nombres[codigo] ?? 'Nota de crédito';
    return descripcion.trim().isEmpty ? nombre : '$nombre · $descripcion';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Detalle de Nota de Crédito',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: _colorPrincipal,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: const [],
      ),
      body: _cargando
          ? Center(child: CircularProgressIndicator(color: _colorPrincipal))
          : _error != null
          ? _buildError()
          : _buildContenido(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 54, color: Colors.red),
            const SizedBox(height: 12),
            Text(
              _error ?? 'No se pudo cargar la nota.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _cargar,
              icon: const Icon(Icons.refresh, color: Colors.white),
              label: const Text(
                'REINTENTAR',
                style: TextStyle(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(backgroundColor: _colorPrincipal),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContenido() {
    final nota = _nota!;
    final estado =
        nota['estado']?.toString().toLowerCase() ?? 'pendiente_envio';
    final estadoBaja =
        nota['estado_baja_tributaria']?.toString().toLowerCase() ?? 'ninguna';
    final total = (nota['total'] as num?)?.toDouble() ?? 0;
    final codigoMotivo = nota['motivo_codigo']?.toString() ?? '';
    final descripcionMotivo = nota['motivo_descripcion']?.toString() ?? '';
    final documentos = nota['documentos'];
    final detallesRaw = nota['detalles'];
    final detalles = detallesRaw is List
        ? List<Map<String, dynamic>>.from(
            detallesRaw.map((e) => Map<String, dynamic>.from(e as Map)),
          )
        : <Map<String, dynamic>>[];

    final esAdmin = ref.watch(rolProvider) == 'admin';
    final puedeReintentar =
        estado == 'pendiente_envio' || estado == 'pendiente_reintento';
    final puedeForzar = esAdmin && estado == 'rechazado';
    final puedeReconciliar = esAdmin && estado == 'resultado_incierto';
    final tienePdf = documentos is Map && documentos['pdf'] != null;
    final tieneXml = documentos is Map && documentos['xml'] != null;
    final tieneCdr = documentos is Map && documentos['cdr'] != null;

    return RefreshIndicator(
      color: Colors.deepPurple,
      onRefresh: () => _cargar(),
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
                      backgroundColor: EstadoTributarioBadge.colorDeEstado(
                        estado,
                      ).withValues(alpha: 0.1),
                      child: Icon(
                        Icons.receipt_long,
                        color: EstadoTributarioBadge.colorDeEstado(estado),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${nota['serie'] ?? ''}-${nota['correlativo'] ?? ''}',
                            style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            'Afecta: ${nota['serie_afectada'] ?? ''}-${nota['correlativo_afectado'] ?? ''}',
                            style: TextStyle(
                              color: Colors.grey.shade600,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    EstadoTributarioBadge(estado: estado, fontSize: 11),
                  ],
                ),
                const Divider(height: 28),
                _infoRow('Motivo', _motivo(codigoMotivo, descripcionMotivo)),
                _infoRow('Fecha', _formatDate(nota['fecha_emision'])),
                _infoRow(
                  'Total',
                  'S/ ${NumberFormat('#,##0.00').format(total)}',
                ),
                if (estadoBaja != 'ninguna')
                  _infoRow('Baja tributaria', estadoBaja.toUpperCase()),
                _infoRow(
                  'Stock',
                  nota['reponer_stock'] == true
                      ? nota['stock_aplicado'] == true
                            ? 'Repuesto correctamente'
                            : estado == 'aceptado'
                            ? 'Pendiente de reposición automática'
                            : 'Se repondrá al ser aceptada'
                      : 'No modifica el stock',
                ),
                if (estado == 'aceptado' &&
                    nota['reponer_stock'] == true &&
                    nota['stock_aplicado'] != true)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Text(
                      (nota['stock_error']?.toString() ?? '').trim().isEmpty
                          ? 'SUNAT aceptó la nota, pero la reposición del stock continúa pendiente. Al actualizar se volverá a intentar automáticamente.'
                          : 'SUNAT aceptó la nota. La reposición del stock falló y se volverá a intentar: ${nota['stock_error']}',
                      style: TextStyle(
                        color: Colors.orange.shade900,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
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
                      'No se recibió un resultado tributario final. No vuelvas a enviar '
                      'la nota. Un administrador debe consultar y registrar una '
                      'reconciliación antes de habilitar cualquier reintento.',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                if ((nota['codigo_sunat']?.toString() ?? '').isNotEmpty)
                  _infoRow('Código SUNAT', nota['codigo_sunat'].toString()),
                if ((nota['descripcion_sunat']?.toString() ?? '')
                    .trim()
                    .isNotEmpty)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: EstadoTributarioBadge.colorDeEstado(
                        estado,
                      ).withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      nota['descripcion_sunat'].toString(),
                      style: TextStyle(
                        color: estado == 'rechazado'
                            ? (Theme.of(context).brightness == Brightness.dark
                                  ? Colors.red.shade300
                                  : Colors.red.shade800)
                            : (Theme.of(context).brightness == Brightness.dark
                                  ? Colors.white
                                  : Colors.grey.shade800),
                        fontWeight: estado == 'rechazado'
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Detalle',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                if (detalles.isEmpty)
                  const Text('No hay líneas registradas.')
                else
                  ...detalles.map(_buildDetalle),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _card(
            child: _procesando
                ? const Padding(
                    padding: EdgeInsets.all(18),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Wrap(
                    spacing: 9,
                    runSpacing: 9,
                    children: [
                      if (puedeReintentar)
                        ElevatedButton.icon(
                          onPressed: _reintentar,
                          icon: const Icon(
                            Icons.cloud_upload,
                            color: Colors.white,
                          ),
                          label: const Text(
                            'REINTENTAR',
                            style: TextStyle(color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.orange.shade700,
                          ),
                        ),
                      if (puedeReconciliar)
                        ElevatedButton.icon(
                          onPressed: _reconciliarResultadoIncierto,
                          icon: const Icon(
                            Icons.manage_search,
                            color: Colors.white,
                          ),
                          label: const Text(
                            'RECONCILIAR',
                            style: TextStyle(color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.deepOrange.shade700,
                          ),
                        ),
                      if (puedeForzar)
                        ElevatedButton.icon(
                          onPressed: () => _confirmarReintentoForzado(),
                          icon: const Icon(
                            Icons.warning_amber,
                            color: Colors.white,
                          ),
                          label: const Text(
                            'REVISAR Y FORZAR',
                            style: TextStyle(color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                          ),
                        ),
                      if (esAdmin &&
                          estado == 'aceptado' &&
                          estadoBaja == 'ninguna')
                        OutlinedButton.icon(
                          onPressed: _solicitarBajaTributaria,
                          icon: const Icon(Icons.cancel_schedule_send),
                          label: const Text('COMUNICAR BAJA'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red.shade700,
                          ),
                        ),
                      if (tienePdf)
                        ElevatedButton.icon(
                          onPressed: () => _abrirDocumento('pdf'),
                          icon: const Icon(
                            Icons.picture_as_pdf,
                            color: Colors.white,
                          ),
                          label: const Text(
                            'PDF',
                            style: TextStyle(color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                          ),
                        ),
                      if (tieneXml)
                        ElevatedButton.icon(
                          onPressed: () => _abrirDocumento('xml'),
                          icon: const Icon(Icons.code, color: Colors.white),
                          label: const Text(
                            'XML',
                            style: TextStyle(color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                          ),
                        ),
                      if (tieneCdr)
                        ElevatedButton.icon(
                          onPressed: () => _abrirDocumento('cdr'),
                          icon: const Icon(Icons.verified, color: Colors.white),
                          label: const Text(
                            'CDR',
                            style: TextStyle(color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Future<void> _confirmarReintentoForzado() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reintento forzado'),
        content: const Text(
          'Úsalo únicamente después de corregir la causa de un rechazo '
          'definitivo. La nota conservará la misma serie y correlativo. '
          'Los resultados inciertos se resuelven mediante reconciliación.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('FORZAR', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm == true) await _reintentar(forzar: true);
  }

  Widget _buildDetalle(Map<String, dynamic> detalle) {
    final cantidad = (detalle['cantidad_visual'] as num?)?.toInt() ?? 0;
    final subtotal = (detalle['subtotal'] as num?)?.toDouble() ?? 0;
    final descripcion =
        (detalle['descripcion_corregida'] ?? detalle['descripcion_original'])
            ?.toString() ??
        'Producto';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  descripcion,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 3),
                Text(
                  '$cantidad ${detalle['tipo_unidad'] ?? ''}',
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            'S/ ${NumberFormat('#,##0.00').format(subtotal)}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(18),
        boxShadow: Theme.of(context).brightness == Brightness.dark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 12,
                  offset: const Offset(0, 5),
                ),
              ],
      ),
      child: child,
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(dynamic value) {
    if (value == null) return '-';
    final parsed = DateTime.tryParse(value.toString());
    if (parsed == null) return value.toString();
    return AppFormatters.limaDateOnly(parsed);
  }
}
