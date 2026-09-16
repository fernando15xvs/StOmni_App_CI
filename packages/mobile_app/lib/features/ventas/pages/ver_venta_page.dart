import 'package:mobile_app/platform/documents/mobile_pdf_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core_logic/core_logic.dart';
import 'package:intl/intl.dart';
import '../../../core/widgets/resultado_incierto_dialog.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../shared/widgets/shimmer_detalle.dart';
import '../../facturacion/pages/emitir_nota_credito_page.dart';
import '../../facturacion/pages/ver_nota_credito_page.dart';
import '../../facturacion/pages/solicitar_baja_tributaria_page.dart';
import '../../facturacion/pages/nueva_guia_remision_page.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:io';

class VerVentaPage extends ConsumerStatefulWidget {
  final int ventaId;
  const VerVentaPage({super.key, required this.ventaId});

  @override
  ConsumerState<VerVentaPage> createState() => _VerVentaPageState();
}

class _VerVentaPageState extends ConsumerState<VerVentaPage> {
  Map<String, dynamic>? _venta;
  List<Map<String, dynamic>> _detalles = [];
  List<Map<String, dynamic>> _pagos = [];
  Map<String, dynamic>? _cliente;
  Map<String, dynamic>? _comprobante;
  List<Map<String, dynamic>> _notasCredito = [];
  bool _cargando = true;
  bool _procesandoComprobante = false;
  String? _errorCarga;

  // AHORA LA LLAVE ES INT (almacen_id)
  Map<int, String> nombresalmacenes = {};

  // Colores Corporativos
  Color get colorVerde => Theme.of(context).colorScheme.primary;
  Color get colorVerdeBrillante =>
      Theme.of(context).brightness == Brightness.dark
      ? Colors.greenAccent
      : const Color(0xFF0F9D58);
  Color get colorTexto => Theme.of(context).brightness == Brightness.dark
      ? Colors.white
      : const Color(0xFF1F2937);
  Color get colorGris => Theme.of(context).brightness == Brightness.dark
      ? Colors.grey.shade400
      : const Color(0xFF6B7280);

  @override
  void initState() {
    super.initState();
    _cargarDatos();
  }

  Future<void> _cargarDatos() async {
    if (mounted && !_cargando) {
      setState(() {
        _cargando = true;
        _errorCarga = null;
      });
    }

    try {
      final repo = ref.read(ventasRepositoryProvider);
      final detalleRepo = ref.read(ventaDetalleReadRepositoryProvider);

      // 1. Obtener la venta completa desde el repositorio
      final ventaData = await repo.obtenerVentaCompleta(widget.ventaId);

      // 2. Nombres históricos de almacenes, incluyendo los inactivos.
      final mapAlmacenesTemp = await detalleRepo
          .obtenerNombresAlmacenesHistoricos();

      // 3. Comprobante electrónico (si existe)
      Map<String, dynamic>? comprobanteData;
      try {
        final rawComprobante = await detalleRepo.obtenerComprobantePorVenta(
          widget.ventaId,
        );

        if (rawComprobante != null) {
          comprobanteData = rawComprobante;
          try {
            final consulta = await FacturacionService.consultarComprobante(
              comprobanteData['id'].toString(),
            );
            if (consulta['comprobante'] is Map) {
              comprobanteData = {
                ...comprobanteData,
                ...Map<String, dynamic>.from(consulta['comprobante'] as Map),
              };
            }
          } catch (_) {
            // El detalle de venta sigue disponible aunque la Edge Function
            // todavía no haya sido desplegada o no exista conexión.
          }
        }
      } catch (_) {}

      // 4. Notas de crédito vinculadas a la venta.
      List<Map<String, dynamic>> notasCreditoData = [];
      try {
        notasCreditoData = await ref
            .read(notasCreditoRepositoryProvider)
            .listarPorVenta(widget.ventaId);
      } catch (_) {
        // La venta sigue disponible aunque el bloque de notas todavía no exista.
      }

      if (mounted) {
        setState(() {
          _venta = ventaData['venta'];
          nombresalmacenes = mapAlmacenesTemp;
          _cliente =
              _venta?['clientes'] ??
              {'nombre': 'Cliente General', 'dni_ruc': '---', 'direccion': '-'};
          // Extraemos el operador (empleados) si existe (dependiendo de si se hizo el join,
          // pero si no se hizo, mostramos que no hay data o actualizamos el select en el repo)

          final List<dynamic> rawDetalles = ventaData['detalles'];
          _detalles = List<Map<String, dynamic>>.from(
            rawDetalles.map((item) {
              final productoInfo = item['productos'] as Map<String, dynamic>?;
              final detalle = Map<String, dynamic>.from(item as Map);
              return {
                ...detalle,
                'nombre_producto': productoInfo?['nombre'] ?? 'Producto s/n',
                'codigo_producto': productoInfo?['codigo'],
                'unidad_medida': productoInfo?['unidad_medida'] ?? 'Unidades',
                'cantidad_por_caja':
                    detalle['pcs_snapshot'] ??
                    productoInfo?['cantidad_por_caja'] ??
                    1,
                'tipo_venta_visual':
                    detalle['tipo_venta_snapshot'] ??
                    productoInfo?['tipo_venta'] ??
                    '',
              };
            }),
          );

          _pagos = List<Map<String, dynamic>>.from(ventaData['pagos']);
          _comprobante = comprobanteData;
          _notasCredito = notasCreditoData;
          _errorCarga = null;
          _cargando = false;
        });
      }
    } catch (e, st) {
      debugPrint('VerVentaPage: fallo al cargar venta ${widget.ventaId}: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;
      setState(() {
        _errorCarga = ErrorMapper.map(e);
        _cargando = false;
      });
    }
  }

  // --- ANULAR VENTA COMPLETA ---
  Future<void> _eliminarVenta() async {
    final estadoComprobante =
        _comprobante?['estado']?.toString().toLowerCase() ?? '';

    const estadosTributariosInciertos = {
      'pendiente',
      'pendiente_envio',
      'procesando',
      'pendiente_reintento',
      'ticket_pendiente',
      'resultado_incierto',
    };

    if (_comprobante != null &&
        estadosTributariosInciertos.contains(estadoComprobante)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No se puede anular localmente mientras el comprobante tenga '
            'un resultado tributario pendiente. Consulta primero su estado '
            'en SUNAT.',
          ),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 5),
        ),
      );
      return;
    }

    if (_comprobante != null && estadoComprobante == 'aceptado') {
      await _abrirEmisionNotaCredito();
      return;
    }

    final motivoCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final motivo = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Anular venta?'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Se devolverá el stock y se conservará una auditoría con '
                'quién realizó la venta, quién la anuló y el motivo.',
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: motivoCtrl,
                autofocus: true,
                maxLength: 250,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Motivo de la anulación',
                  hintText: 'Ejemplo: el cliente canceló la compra',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.length < 3) {
                    return 'Escribe un motivo de al menos 3 caracteres.';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.pop(ctx, motivoCtrl.text.trim());
            },
            child: const Text(
              'ANULAR VENTA',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    Future.delayed(
      const Duration(milliseconds: 500),
      () => motivoCtrl.dispose(),
    );
    if (motivo == null || motivo.isEmpty) return;

    try {
      await ref
          .read(ventasRepositoryProvider)
          .anularVenta(ventaId: widget.ventaId, motivo: motivo);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Venta anulada correctamente')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(e)),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _abrirGuiaRemision() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NuevaGuiaRemisionPage(ventaId: widget.ventaId),
      ),
    );

    if (mounted) await _cargarDatos();
  }

  Future<void> _abrirEmisionNotaCredito() async {
    final comprobanteId = _comprobante?['id']?.toString();
    final estado = _comprobante?['estado']?.toString().toLowerCase() ?? '';
    final estadoBaja =
        _comprobante?['estado_baja_tributaria']?.toString().toLowerCase() ??
        'ninguna';

    if (comprobanteId == null || comprobanteId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('La venta no tiene comprobante electrónico.'),
        ),
      );
      return;
    }

    if (estado != 'aceptado') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'La nota de crédito solo puede emitirse cuando SUNAT aceptó el comprobante original.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (estadoBaja != 'ninguna') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No se puede emitir una nota porque la baja tributaria está: $estadoBaja.',
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EmitirNotaCreditoPage(
          comprobanteId: comprobanteId,
          ventaId: widget.ventaId,
        ),
      ),
    );

    if (mounted) await _cargarDatos();
  }

  Future<void> _abrirBajaTributaria() async {
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

    final comprobante = _comprobante;
    final id = comprobante?['id']?.toString();
    if (id == null || id.isEmpty) return;

    final estado = comprobante?['estado']?.toString().toLowerCase() ?? '';
    final estadoBaja =
        comprobante?['estado_baja_tributaria']?.toString().toLowerCase() ??
        'ninguna';
    if (estado != 'aceptado') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Solo puede darse de baja un comprobante aceptado.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    if (estadoBaja != 'ninguna') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('La baja tributaria ya está: $estadoBaja.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final tipo =
        comprobante?['tipo_documento_sunat']?.toString().toLowerCase() ?? '';
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SolicitarBajaTributariaPage(
          tipoOrigen: 'comprobante',
          origenId: id,
          numeroDocumento:
              '${comprobante?['serie'] ?? ''}-${comprobante?['correlativo'] ?? ''}',
          tipoProcesoEsperado: tipo == 'boleta'
              ? 'resumen_boletas'
              : 'comunicacion_baja',
        ),
      ),
    );
    if (result == true && mounted) await _cargarDatos();
  }

  Future<void> _abrirNotaCredito(String notaCreditoId) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VerNotaCreditoPage(notaCreditoId: notaCreditoId),
      ),
    );
    if (mounted) await _cargarDatos();
  }

  // --- ELIMINAR PAGO INDIVIDUAL ---
  Future<void> _eliminarPago(Map<String, dynamic> p) async {
    if (_comprobante != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No se pueden modificar los pagos de una venta que ya tiene un '
            'comprobante electrónico reservado. Consulta, reintenta, emite '
            'una nota de crédito o anula la venta mediante el flujo '
            'tributario correspondiente.',
          ),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 5),
        ),
      );
      return;
    }

    final confirm = await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("¿Eliminar pago?"),
        content: Text(
          "Se eliminará el abono de S/ ${p['monto']} y la deuda aumentará.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text("Cancelar"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text("Eliminar", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await ref
          .read(ventasRepositoryProvider)
          .eliminarPago(
            pagoId: (p['id'] as num).toInt(),
            ventaId: widget.ventaId,
          );

      _cargarDatos();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Pago eliminado y caja actualizada")),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMapper.map(e)),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _abrirUrl(String? url, {String extension = 'pdf'}) async {
    if (url == null || url.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Documento no disponible')));
      return;
    }

    final uri = Uri.tryParse(url);
    if (uri == null) return;

    // Mostrar indicador de carga
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) =>
          const Center(child: CircularProgressIndicator(color: Colors.white)),
    );

    try {
      final response = await http.get(uri);
      if (!mounted) return;
      Navigator.pop(context); // Quitar indicador

      if (response.statusCode == 200) {
        final tempDir = await getTemporaryDirectory();
        final fileName =
            '${_comprobante?['serie'] ?? 'DOC'}-${_comprobante?['correlativo'] ?? '0000'}.$extension';
        final file = File('${tempDir.path}/$fileName');
        await file.writeAsBytes(response.bodyBytes);

        await Share.shareXFiles([XFile(file.path)]);
        return;
      }
    } catch (e) {
      debugPrint('VerVentaPage: descarga de documento falló, se usará URL: $e');
      if (mounted) Navigator.pop(context); // Quitar indicador
    }

    // Fallback: Si falla la descarga, intenta abrir la URL en el navegador
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No se pudo abrir ni descargar el documento'),
        ),
      );
    }
  }

  Future<void> _refrescarComprobante({bool consultarSunat = false}) async {
    final id = _comprobante?['id']?.toString();
    if (id == null || id.isEmpty || _procesandoComprobante) return;

    setState(() => _procesandoComprobante = true);
    try {
      final resultado = await FacturacionService.consultarComprobante(
        id,
        consultarSunat: consultarSunat,
      );
      final comprobante = resultado['comprobante'];
      if (comprobante is Map && mounted) {
        setState(() {
          _comprobante = {
            ...?_comprobante,
            ...Map<String, dynamic>.from(comprobante),
          };
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMapper.map(e)),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _procesandoComprobante = false);
    }
  }

  Future<void> _emitirOReintentarComprobante() async {
    final id = _comprobante?['id']?.toString();
    if (id == null || id.isEmpty || _procesandoComprobante) return;

    final estado = _comprobante?['estado']?.toString().toLowerCase() ?? '';
    setState(() => _procesandoComprobante = true);

    try {
      final resultado = estado == 'pendiente_reintento'
          ? await FacturacionService.reintentarComprobante(id)
          : await FacturacionService.emitirComprobante(id);

      final comprobante = resultado['comprobante'];
      if (comprobante is Map && mounted) {
        setState(() {
          _comprobante = {
            ...?_comprobante,
            ...Map<String, dynamic>.from(comprobante),
          };
        });
      }

      if (!mounted) return;
      final estadoNuevo = resultado['estado']?.toString() ?? 'pendiente';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            estadoNuevo == 'aceptado'
                ? 'Comprobante aceptado por SUNAT.'
                : resultado['mensaje']?.toString() ??
                      'El comprobante quedó pendiente de reintento.',
          ),
          backgroundColor: estadoNuevo == 'aceptado'
              ? Colors.green
              : estadoNuevo == 'rechazado'
              ? Colors.red
              : Colors.orange,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMapper.map(e)),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _procesandoComprobante = false);
    }
  }

  Future<void> _reconciliarResultadoInciertoComprobante() async {
    if (ref.read(rolProvider) != 'admin' || _procesandoComprobante) return;
    final id = _comprobante?['id']?.toString();
    if (id == null || id.isEmpty) return;

    setState(() => _procesandoComprobante = true);
    var liberarBloqueoAntesDeRefresh = false;
    try {
      final actualizado = await mostrarReconciliacionResultadoIncierto(
        context: context,
        tipoDocumento: 'comprobante',
        documentoId: id,
      );
      if (actualizado && mounted) {
        // _refrescarComprobante() protege contra operaciones concurrentes. Hay
        // que liberar este bloqueo antes de llamarlo; de lo contrario retorna
        // inmediatamente y la UI conserva el estado anterior.
        setState(() => _procesandoComprobante = false);
        liberarBloqueoAntesDeRefresh = true;
        await _refrescarComprobante();
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
      if (mounted &&
          (!liberarBloqueoAntesDeRefresh || _procesandoComprobante)) {
        setState(() => _procesandoComprobante = false);
      }
    }
  }

  Future<void> _confirmarReintentoForzadoComprobante() async {
    if (ref.read(rolProvider) != 'admin') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Solo el administrador puede forzar el reintento de un '
            'comprobante rechazado.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final id = _comprobante?['id']?.toString();
    if (id == null || id.isEmpty || _procesandoComprobante) return;

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forzar reintento tributario'),
        content: const Text(
          'Realiza esta acción únicamente después de corregir la causa del '
          'rechazo. Se conservarán la misma serie y el mismo correlativo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text(
              'FORZAR REINTENTO',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirmar != true || !mounted) return;

    setState(() => _procesandoComprobante = true);
    try {
      final resultado = await FacturacionService.reintentarComprobante(
        id,
        forzar: true,
      );
      final comprobante = resultado['comprobante'];
      if (comprobante is Map && mounted) {
        setState(() {
          _comprobante = {
            ...?_comprobante,
            ...Map<String, dynamic>.from(comprobante),
          };
        });
      }

      if (!mounted) return;
      final estadoNuevo =
          resultado['estado']?.toString().toLowerCase() ?? 'pendiente';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            estadoNuevo == 'aceptado'
                ? 'Comprobante aceptado por SUNAT.'
                : resultado['mensaje']?.toString() ??
                      'El comprobante conserva su estado tributario.',
          ),
          backgroundColor: estadoNuevo == 'aceptado'
              ? Colors.green
              : estadoNuevo == 'rechazado'
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
      if (mounted) setState(() => _procesandoComprobante = false);
    }
  }

  Future<void> _abrirDocumento(String tipo) async {
    await _refrescarComprobante();
    final documentos = _comprobante?['documentos'];
    final url = documentos is Map ? documentos[tipo]?.toString() : null;
    await _abrirUrl(url, extension: tipo);
  }

  Color _colorEstadoComprobante(String estado) {
    switch (estado) {
      case 'aceptado':
        return Colors.green;
      case 'rechazado':
        return Colors.red;
      case 'resultado_incierto':
        return Colors.deepOrange;
      case 'procesando':
        return Colors.blue;
      default:
        return Colors.orange;
    }
  }

  String _textoEstadoComprobante(String estado) {
    switch (estado) {
      case 'pendiente':
      case 'pendiente_envio':
        return 'PENDIENTE DE ENVÍO';
      case 'pendiente_reintento':
        return 'PENDIENTE DE REINTENTO';
      case 'procesando':
        return 'PROCESANDO';
      case 'aceptado':
        return 'ACEPTADO';
      case 'rechazado':
        return 'RECHAZADO';
      case 'resultado_incierto':
        return 'RESULTADO INCIERTO';
      default:
        return estado.toUpperCase();
    }
  }

  Widget _buildComprobanteElectronicoCard() {
    final comprobante = _comprobante!;
    final estado =
        comprobante['estado']?.toString().toLowerCase() ?? 'pendiente_envio';
    final colorEstado = _colorEstadoComprobante(estado);
    final documentos = comprobante['documentos'];
    final tienePdf = documentos is Map && documentos['pdf'] != null;
    final tieneXml = documentos is Map && documentos['xml'] != null;
    final tieneCdr = documentos is Map && documentos['cdr'] != null;
    final puedeEmitir =
        estado == 'pendiente' ||
        estado == 'pendiente_envio' ||
        estado == 'pendiente_reintento';
    final puedeForzarRechazado =
        estado == 'rechazado' && ref.watch(rolProvider) == 'admin';
    final puedeReconciliar =
        estado == 'resultado_incierto' && ref.watch(rolProvider) == 'admin';

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: Theme.of(context).brightness == Brightness.dark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 5),
                ),
              ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.receipt_long, color: colorVerdeBrillante),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Comprobante Electrónico',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    Text(
                      '${comprobante['serie'] ?? ''}-'
                      '${comprobante['correlativo'] ?? ''}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: colorEstado.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _textoEstadoComprobante(estado),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: colorEstado,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 22),
          if ((comprobante['estado_baja_tributaria']?.toString() ??
                  'ninguna') !=
              'ninguna')
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.red.shade100),
              ),
              child: Text(
                'Baja tributaria: ${comprobante['estado_baja_tributaria']}',
                style: TextStyle(
                  color: Colors.red.shade800,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          if (_procesandoComprobante)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            if ((comprobante['descripcion_sunat']?.toString() ?? '')
                .trim()
                .isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  comprobante['descripcion_sunat'].toString(),
                  style: TextStyle(
                    color: estado == 'rechazado'
                        ? (Theme.of(context).brightness == Brightness.dark
                              ? Colors.red.shade300
                              : Colors.red)
                        : (Theme.of(context).brightness == Brightness.dark
                              ? Colors.white70
                              : Colors.grey.shade700),
                    fontSize: 12,
                    fontWeight: estado == 'rechazado'
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              ),
            if (estado == 'resultado_incierto')
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.deepOrange.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.deepOrange.withValues(alpha: 0.35),
                  ),
                ),
                child: const Text(
                  'No se confirmó si SUNAT recibió el comprobante. No lo '
                  'vuelvas a emitir. Consulta el estado y, si continúa '
                  'incierto, un administrador debe reconciliarlo.',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (puedeEmitir)
                  ElevatedButton.icon(
                    onPressed: _emitirOReintentarComprobante,
                    icon: const Icon(Icons.cloud_upload, color: Colors.white),
                    label: Text(
                      estado == 'pendiente_reintento' ? 'REINTENTAR' : 'EMITIR',
                      style: const TextStyle(color: Colors.white),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange.shade700,
                    ),
                  ),
                if (puedeReconciliar)
                  ElevatedButton.icon(
                    onPressed: _reconciliarResultadoInciertoComprobante,
                    icon: const Icon(Icons.manage_search, color: Colors.white),
                    label: const Text(
                      'RECONCILIAR',
                      style: TextStyle(color: Colors.white),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.deepOrange.shade700,
                    ),
                  ),
                if (puedeForzarRechazado)
                  ElevatedButton.icon(
                    onPressed: _confirmarReintentoForzadoComprobante,
                    icon: const Icon(Icons.warning_amber, color: Colors.white),
                    label: const Text(
                      'FORZAR REINTENTO',
                      style: TextStyle(color: Colors.white),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: () => _refrescarComprobante(consultarSunat: true),
                  icon: const Icon(Icons.sync),
                  label: const Text('CONSULTAR'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colorVerdeBrillante,
                    side: BorderSide(color: colorVerdeBrillante),
                  ),
                ),
                if (tienePdf)
                  ElevatedButton.icon(
                    onPressed: () => _abrirDocumento('pdf'),
                    icon: const Icon(Icons.picture_as_pdf, color: Colors.white),
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
          ],
        ],
      ),
    );
  }

  Color _colorEstadoNota(String estado) {
    switch (estado) {
      case 'aceptado':
        return Colors.green;
      case 'rechazado':
        return Colors.red;
      case 'resultado_incierto':
        return Colors.deepOrange;
      case 'procesando':
        return Colors.blue;
      default:
        return Colors.orange;
    }
  }

  Widget _buildNotasCreditoCard() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: Theme.of(context).brightness == Brightness.dark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 5),
                ),
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                Icon(Icons.assignment_return, color: colorVerdeBrillante),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'Notas de Crédito',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  '${_notasCredito.length}',
                  style: TextStyle(
                    color: colorVerde,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ..._notasCredito.map((nota) {
            final estado =
                nota['estado']?.toString().toLowerCase() ?? 'pendiente_envio';
            final colorEstado = _colorEstadoNota(estado);
            final total = (nota['total'] as num?)?.toDouble() ?? 0;
            final id = nota['id']?.toString() ?? '';

            return ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 6,
              ),
              leading: CircleAvatar(
                backgroundColor: colorEstado.withValues(alpha: 0.1),
                child: Icon(Icons.receipt_long, color: colorEstado),
              ),
              title: Text(
                '${nota['serie'] ?? ''}-${nota['correlativo'] ?? ''}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                '${nota['motivo_codigo'] ?? ''} · ${nota['motivo_descripcion'] ?? ''}\n'
                '${_textoEstadoComprobante(estado)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              isThreeLine: true,
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'S/ ${NumberFormat('#,##0.00').format(total)}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Icon(Icons.chevron_right, color: Colors.grey.shade400),
                ],
              ),
              onTap: id.isEmpty ? null : () => _abrirNotaCredito(id),
            );
          }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: const Text(
            'Detalle de Venta',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          backgroundColor: colorVerde,
          iconTheme: const IconThemeData(color: Colors.white),
          elevation: 0,
        ),
        body: const ShimmerDetalle(),
      );
    }
    if (_venta == null) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: const Text(
            'Detalle de Venta',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          backgroundColor: colorVerde,
          iconTheme: const IconThemeData(color: Colors.white),
          elevation: 0,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_outlined, size: 52),
                const SizedBox(height: 16),
                Text(
                  _errorCarga ?? 'No se pudo cargar la venta.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _cargarDatos,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final total = (_venta!['total'] as num).toDouble();
    final saldo = (_venta!['saldo'] as num).toDouble();
    final pagado = total - saldo;
    final fecha = toLima(_venta!['fecha']);
    final estado = saldo <= 0.01 ? 'pagado' : 'pendiente';
    final esAdmin = ref.watch(rolProvider) == 'admin';

    final nombreCliente = _cliente?['nombre'] ?? 'Cliente General';
    final docCliente = _cliente?['dni_ruc'] ?? '---';
    String rawDir = _cliente?['direccion'] ?? '-';
    final dirCliente = (rawDir == '-' || rawDir.trim().isEmpty)
        ? 'No registrada'
        : rawDir;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Detalle de Venta',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: colorVerde,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: "Compartir",
            onPressed: () => MobilePdfActions.compartir(
              context,
              TipoDocumento.boleta,
              _venta!,
              _detalles,
              _cliente,
              _comprobante,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.print),
            tooltip: "Imprimir",
            onPressed: () => MobilePdfActions.imprimir(
              context,
              TipoDocumento.boleta,
              _venta!,
              _detalles,
              _cliente,
              _comprobante,
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // --- TICKET PRINCIPAL ---
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(20),
                boxShadow: Theme.of(context).brightness == Brightness.dark
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
              ),
              child: Column(
                children: [
                  // CABECERA
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: colorVerdeBrillante.withValues(alpha: 0.05),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(20),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "VENTA #${widget.ventaId}",
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              DateFormat('dd MMM yyyy - HH:mm').format(fecha),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: estado == 'pagado'
                                ? colorVerdeBrillante
                                : Colors.orange,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            estado.toUpperCase(),
                            style: TextStyle(
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Colors.black
                                  : Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // CUERPO INFO
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        _buildInfoRow(Icons.person, "Cliente", nombreCliente),
                        const SizedBox(height: 8),
                        _buildInfoRow(Icons.badge, "RUC / DNI", docCliente),
                        const SizedBox(height: 8),
                        _buildInfoRow(
                          Icons.location_on,
                          "Dirección",
                          dirCliente,
                        ),
                        if (_venta?['empleados'] != null &&
                            _venta!['empleados']['nombre'] != null) ...[
                          const SizedBox(height: 8),
                          _buildInfoRow(
                            Icons.badge,
                            "Operador",
                            _venta!['empleados']['nombre'],
                          ),
                        ],

                        const Divider(height: 30),

                        // ENCABEZADO LISTA LIMPIO
                        Row(
                          children: [
                            Expanded(
                              flex: 4,
                              child: Text(
                                "PRODUCTO",
                                style: TextStyle(
                                  color: Colors.grey[400],
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(
                                "DETALLE",
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: Colors.grey[400],
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Text(
                                "TOTAL",
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                  color: Colors.grey[400],
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 15),

                        // LISTA DE PRODUCTOS ELEGANTE
                        ..._detalles.map((d) {
                          final almacenId = (d['almacen_id'] as num?)?.toInt();
                          final origen = almacenId == null
                              ? 'General'
                              : nombresalmacenes[almacenId] ?? 'General';
                          final cantidad =
                              (d['cantidad'] as num?)?.toInt() ?? 0;
                          final tipoUnidad = StockUtils.normalizarTipoUnidad(
                            d['tipo_unidad']?.toString(),
                          );
                          final etiqueta = cantidad == 1
                              ? d['commercial_unit_label_snapshot']
                                        ?.toString() ??
                                    StockUtils.etiquetaUnidadComercial(
                                      tipoUnidad,
                                      cantidad: 1,
                                    )
                              : d['commercial_unit_plural_snapshot']
                                        ?.toString() ??
                                    StockUtils.etiquetaUnidadComercial(
                                      tipoUnidad,
                                      cantidad: 2,
                                    );
                          final subtotal =
                              (d['subtotal_final'] as num?)?.toDouble() ??
                              (d['subtotal'] as num?)?.toDouble() ??
                              0.0;
                          final precioVisual = cantidad > 0
                              ? subtotal / cantidad
                              : 0.0;
                          final codigo = d['codigo_producto']
                              ?.toString()
                              .trim();

                          return Container(
                            margin: const EdgeInsets.only(bottom: 15),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 4,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (codigo != null && codigo.isNotEmpty)
                                        Text(
                                          codigo,
                                          style: TextStyle(
                                            fontSize: 9,
                                            color: colorVerdeBrillante,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      Text(
                                        d['nombre_producto']?.toString() ??
                                            'Producto',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13,
                                          color: colorTexto,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '$cantidad $etiqueta',
                                        style: TextStyle(
                                          color: colorVerdeBrillante,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 10,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  flex: 3,
                                  child: Column(
                                    children: [
                                      Text(
                                        'P.U: ${AppFormatters.currency(precioVisual)}',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: colorTexto,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      Text(
                                        origen,
                                        style: TextStyle(
                                          color: Colors.grey[400],
                                          fontSize: 10,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  flex: 2,
                                  child: Text(
                                    'S/ ${NumberFormat('#,##0.00', 'es_PE').format(subtotal)}',
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: colorTexto,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),

                        const Divider(height: 30),

                        // BARRA DE PROGRESO Y SALDOS
                        Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  "Pagado",
                                  style: TextStyle(
                                    color: colorGris,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  "Total",
                                  style: TextStyle(
                                    color: colorGris,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  "S/ ${NumberFormat('#,##0.00').format(pagado)}",
                                  style: TextStyle(
                                    color: colorVerdeBrillante,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                                Text(
                                  "S/ ${NumberFormat('#,##0.00').format(total)}",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: colorTexto,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            LinearProgressIndicator(
                              value: pagado / (total == 0 ? 1 : total),
                              backgroundColor:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? Colors.red.withValues(alpha: 0.1)
                                  : Colors.red[50],
                              color: colorVerdeBrillante,
                              minHeight: 8,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            if (saldo > 0.01)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    "Resta por cobrar: S/ ${NumberFormat('#,##0.00').format(saldo)}",
                                    style: const TextStyle(
                                      color: Colors.red,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // --- COMPROBANTE ELECTRÓNICO (SI EXISTE) ---
            if (_comprobante != null) ...[
              const SizedBox(height: 20),
              _buildComprobanteElectronicoCard(),
            ],

            if (_notasCredito.isNotEmpty) ...[
              const SizedBox(height: 20),
              _buildNotasCreditoCard(),
            ],

            const SizedBox(height: 20),

            // HISTORIAL PAGOS
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(20),
                boxShadow: Theme.of(context).brightness == Brightness.dark
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(Icons.history, color: colorVerdeBrillante),
                        const SizedBox(width: 10),
                        const Text(
                          "Historial de Pagos",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  if (_pagos.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(30),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(
                              Icons.money_off,
                              size: 40,
                              color: Colors.grey[300],
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              "Venta a crédito",
                              style: TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    ..._pagos.map(
                      (p) => ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 5,
                        ),
                        leading: CircleAvatar(
                          backgroundColor:
                              Theme.of(context).brightness == Brightness.dark
                              ? Colors.white.withValues(alpha: 0.05)
                              : Colors.grey[50],
                          child: Icon(
                            _getIconoPago(p['metodo']),
                            color: Colors.grey[700],
                            size: 20,
                          ),
                        ),
                        title: Text(
                          "S/ ${NumberFormat('#,##0.00').format(p['monto'])}",
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: colorTexto,
                          ),
                        ),
                        subtitle: Text(
                          "${p['metodo']} • ${AppFormatters.limaMediumDateTime(p['fecha'])}",
                          style: TextStyle(fontSize: 12, color: colorGris),
                        ),
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                            size: 20,
                          ),
                          onPressed: () => _eliminarPago(p),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 30),

            // La guía copia los productos y datos de la venta. No descuenta,
            // suma ni revierte stock.
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _abrirGuiaRemision,
                icon: const Icon(
                  Icons.local_shipping_rounded,
                  color: Colors.white,
                ),
                label: const Text(
                  'CREAR GUÍA DE REMISIÓN',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),

            // Un comprobante aceptado no se borra: se modifica con nota de crédito.
            SizedBox(
              width: double.infinity,
              child:
                  (_comprobante != null &&
                      (_comprobante?['estado']?.toString().toLowerCase() ??
                              '') ==
                          'aceptado')
                  ? Column(
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed:
                                (_comprobante?['estado_baja_tributaria']
                                            ?.toString() ??
                                        'ninguna') ==
                                    'ninguna'
                                ? _abrirEmisionNotaCredito
                                : null,
                            icon: const Icon(
                              Icons.assignment_return,
                              color: Colors.white,
                            ),
                            label: const Text(
                              'EMITIR NOTA DE CRÉDITO',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange.shade800,
                              padding: const EdgeInsets.symmetric(vertical: 15),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        if (esAdmin) ...[
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed:
                                  (_comprobante?['estado_baja_tributaria']
                                              ?.toString() ??
                                          'ninguna') ==
                                      'ninguna'
                                  ? _abrirBajaTributaria
                                  : null,
                              icon: const Icon(Icons.cancel_schedule_send),
                              label: Text(
                                (_comprobante?['estado_baja_tributaria']
                                                ?.toString() ??
                                            'ninguna') ==
                                        'ninguna'
                                    ? 'COMUNICAR BAJA TRIBUTARIA'
                                    : 'BAJA: ${_comprobante?['estado_baja_tributaria']}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.red.shade700,
                                side: BorderSide(color: Colors.red.shade300),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 15,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    )
                  : TextButton.icon(
                      onPressed: _eliminarVenta,
                      icon: const Icon(Icons.delete_forever, color: Colors.red),
                      label: const Text(
                        'Anular Venta Completa',
                        style: TextStyle(color: Colors.red),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(
                            color: Colors.red.withValues(alpha: 0.3),
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  // --- WIDGETS AUXILIARES ---
  Widget _buildInfoRow(IconData icon, String label, String val) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.grey[50],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 18, color: Colors.grey[500]),
        ),
        const SizedBox(width: 15),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 10,
                  color: Colors.grey,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                val,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: colorTexto,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  IconData _getIconoPago(String? metodo) {
    if (metodo == null) return Icons.money;
    switch (metodo.toLowerCase()) {
      case 'efectivo':
        return Icons.money;
      case 'tarjeta':
        return Icons.credit_card;
      case 'yape':
      case 'plin':
        return Icons.phone_android;
      case 'transferencia':
        return Icons.account_balance;
      default:
        return Icons.payment;
    }
  }
}
