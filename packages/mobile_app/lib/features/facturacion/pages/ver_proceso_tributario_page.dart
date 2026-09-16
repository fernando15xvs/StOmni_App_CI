import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:core_logic/core_logic.dart';
import '../../../core/widgets/resultado_incierto_dialog.dart';
import '../../../core/widgets/estado_tributario_badge.dart';

class VerProcesoTributarioPage extends ConsumerStatefulWidget {
  final String procesoId;

  const VerProcesoTributarioPage({super.key, required this.procesoId});

  @override
  ConsumerState<VerProcesoTributarioPage> createState() =>
      _VerProcesoTributarioPageState();
}

class _VerProcesoTributarioPageState
    extends ConsumerState<VerProcesoTributarioPage> {
  bool _cargando = true;
  bool _procesando = false;
  String? _error;
  Map<String, dynamic>? _proceso;

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
      final result = await FacturacionService.consultarProcesoTributario(
        widget.procesoId,
        consultarSunat: consultarSunat,
      );
      final raw = result['proceso'];
      if (raw is! Map) {
        throw const FacturacionServiceException(
          'El proceso tributario no está disponible.',
        );
      }
      if (!mounted) return;
      setState(() {
        _proceso = Map<String, dynamic>.from(raw);
        _error = null;
        _cargando = false;
      });
    } catch (e, st) {
      debugPrint(
        'VerProcesoTributarioPage: fallo al cargar ${widget.procesoId}: $e',
      );
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
      final result = await FacturacionService.reintentarProcesoTributario(
        widget.procesoId,
        forzar: forzar,
      );
      final raw = result['proceso'];
      if (raw is Map && mounted) {
        setState(() => _proceso = Map<String, dynamic>.from(raw));
      } else {
        await _cargar();
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

  Future<void> _reconciliarResultadoIncierto() async {
    if (ref.read(rolProvider) != 'admin' || _procesando) return;
    setState(() => _procesando = true);
    try {
      final actualizado = await mostrarReconciliacionResultadoIncierto(
        context: context,
        tipoDocumento: 'proceso',
        documentoId: widget.procesoId,
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
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reintento forzado'),
        content: const Text(
          'Úsalo únicamente después de corregir la causa del rechazo. '
          'El proceso conservará el mismo identificador tributario.',
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
    if (confirmar == true) await _reintentar(forzar: true);
  }

  String _mensajeCarga(Object error) {
    if (error is FacturacionServiceException &&
        error.message.trim() == 'El proceso tributario no está disponible.') {
      return error.message.trim();
    }
    return ErrorMapper.map(error);
  }

  Future<void> _abrir(String tipo) async {
    await _cargar();
    if (!mounted) return;
    final docs = _proceso?['documentos'];
    final url = docs is Map ? docs[tipo]?.toString() : null;
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Documento no disponible.')));
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir el documento.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Detalle tributario',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: _color,
        iconTheme: const IconThemeData(color: Colors.white),
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
            Text(
              _error ?? 'No se pudo cargar el proceso tributario.',
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
              style: ElevatedButton.styleFrom(backgroundColor: _color),
            ),
          ],
        ),
      ),
    );
  }

  Widget _contenido() {
    final p = _proceso!;
    final estado = p['estado']?.toString().toLowerCase() ?? '';
    final colorEstado = EstadoTributarioBadge.colorDeEstado(estado);
    final detallesRaw = p['detalles'];
    final detalles = detallesRaw is List
        ? List<Map<String, dynamic>>.from(
            detallesRaw.map((e) => Map<String, dynamic>.from(e as Map)),
          )
        : <Map<String, dynamic>>[];
    final docs = p['documentos'];
    final tieneTicket =
        (p['ticket_sunat']?.toString().trim().isNotEmpty ?? false);
    final esAdmin = ref.watch(rolProvider) == 'admin';

    return RefreshIndicator(
      color: _color,
      onRefresh: () => _cargar(consultarSunat: tieneTicket),
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.account_balance_rounded, color: colorEstado),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        p['identificador']?.toString() ?? 'Proceso tributario',
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    EstadoTributarioBadge(estado: estado, fontSize: 10),
                  ],
                ),
                const Divider(height: 28),
                _row(
                  'Tipo',
                  p['tipo_proceso'] == 'resumen_boletas'
                      ? 'Anulación de boleta o nota'
                      : 'Comunicación de baja',
                ),
                _row('Fecha de referencia', _fecha(p['fecha_referencia'])),
                _row('Documentos', '${detalles.length}'),
                if (tieneTicket)
                  _row('Ticket SUNAT', p['ticket_sunat'].toString()),
                if (p['codigo_sunat'] != null)
                  _row('Código SUNAT', p['codigo_sunat'].toString()),
                if (p['descripcion_sunat'] != null) ...[
                  const SizedBox(height: 10),
                  Text(p['descripcion_sunat'].toString()),
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
                      'No se confirmó si SUNAT recibió este proceso. No debe '
                      'generarse otro resumen o baja hasta que un administrador '
                      'complete la reconciliación.',
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
                  'Documentos incluidos',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                ...detalles.map(
                  (d) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.description_outlined),
                    title: Text(d['serie_numero']?.toString() ?? '-'),
                    subtitle: Text(d['motivo']?.toString() ?? '-'),
                    trailing: Text(
                      'S/ ${NumberFormat('#,##0.00').format((d['total'] as num?) ?? 0)}',
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _card(
            child: _procesando
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(18),
                      child: CircularProgressIndicator(),
                    ),
                  )
                : Wrap(
                    spacing: 9,
                    runSpacing: 9,
                    children: [
                      if (tieneTicket && estado != 'aceptado')
                        OutlinedButton.icon(
                          onPressed: () => _cargar(consultarSunat: true),
                          icon: const Icon(Icons.sync),
                          label: const Text('CONSULTAR SUNAT'),
                        ),
                      if (!tieneTicket &&
                          (estado == 'pendiente_envio' ||
                              estado == 'pendiente_reintento' ||
                              (estado == 'rechazado' && esAdmin)))
                        ElevatedButton.icon(
                          onPressed: estado == 'rechazado'
                              ? _confirmarReintentoForzado
                              : _reintentar,
                          icon: const Icon(
                            Icons.cloud_upload,
                            color: Colors.white,
                          ),
                          label: Text(
                            estado == 'rechazado'
                                ? 'REVISAR Y FORZAR'
                                : 'REINTENTAR',
                            style: const TextStyle(color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: estado == 'rechazado'
                                ? Colors.red.shade700
                                : Colors.orange.shade700,
                          ),
                        ),
                      if (esAdmin && estado == 'resultado_incierto')
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
                      if (docs is Map && docs['pdf'] != null)
                        ElevatedButton.icon(
                          onPressed: () => _abrir('pdf'),
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
                      if (docs is Map && docs['xml'] != null)
                        ElevatedButton.icon(
                          onPressed: () => _abrir('xml'),
                          icon: const Icon(Icons.code, color: Colors.white),
                          label: const Text(
                            'XML',
                            style: TextStyle(color: Colors.white),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                          ),
                        ),
                      if (docs is Map && docs['cdr'] != null)
                        ElevatedButton.icon(
                          onPressed: () => _abrir('cdr'),
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
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(18),
        boxShadow: Theme.of(context).brightness == Brightness.dark
            ? null
            : const [
                BoxShadow(
                  color: Color(0x10000000),
                  blurRadius: 16,
                  offset: Offset(0, 6),
                ),
              ],
      ),
      child: child,
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextStyle(color: Colors.grey.shade600)),
          ),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  String _fecha(dynamic value) {
    if (value == null) return '-';
    final date = DateTime.tryParse(value.toString());
    return date == null
        ? value.toString()
        : DateFormat('dd/MM/yyyy').format(date);
  }
}
