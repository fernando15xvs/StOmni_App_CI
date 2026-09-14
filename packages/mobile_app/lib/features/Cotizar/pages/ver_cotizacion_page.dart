import 'package:mobile_app/platform/documents/mobile_pdf_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ventas/data/ventas_repository.dart';
import '../../shared/widgets/shimmer_detalle.dart';
import 'package:core_logic/core_logic.dart';
import '../../../core/theme/app_colors.dart';

class VerCotizacionPage extends ConsumerStatefulWidget {
  final int cotizacionId;

  const VerCotizacionPage({super.key, required this.cotizacionId});

  @override
  ConsumerState<VerCotizacionPage> createState() => _VerCotizacionPageState();
}

class _VerCotizacionPageState extends ConsumerState<VerCotizacionPage> {
  Map<String, dynamic>? _cotizacion;
  List<Map<String, dynamic>> _detalles = [];
  Map<String, dynamic>? _cliente;
  bool _cargando = true;
  String? _errorCarga;

  final Color colorTema = AppColors.cotizar;

  @override
  void initState() {
    super.initState();
    _cargarDatos();
  }

  Future<void> _cargarDatos() async {
    if (mounted) {
      setState(() {
        _cargando = true;
        _errorCarga = null;
      });
    }

    try {
      final data = await ref
          .read(ventasRepositoryProvider)
          .obtenerCotizacionCompleta(widget.cotizacionId);

      if (!mounted) return;

      final cotizacion = Map<String, dynamic>.from(data['cotizacion'] as Map);
      final rawDetalles = List<Map<String, dynamic>>.from(
        data['detalles'] as List,
      );

      setState(() {
        _cotizacion = cotizacion;
        _cliente =
            cotizacion['clientes'] as Map<String, dynamic>? ??
            {'nombre': 'Cliente General', 'dni_ruc': '---', 'direccion': '-'};

        _detalles = rawDetalles.map((detalle) {
          final producto = Map<String, dynamic>.from(
            detalle['productos'] as Map? ?? const <String, dynamic>{},
          );

          return <String, dynamic>{
            ...detalle,
            'nombre_producto':
                detalle['producto_nombre_snapshot'] ??
                producto['nombre'] ??
                'Producto',
            'codigo_producto': detalle['codigo_snapshot'] ?? producto['codigo'],
          };
        }).toList();

        _errorCarga = null;
        _cargando = false;
      });
    } catch (e, st) {
      debugPrint('VerCotizacionPage: fallo al cargar cotización: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;
      setState(() {
        _cotizacion = null;
        _errorCarga = ErrorMapper.map(e);
        _cargando = false;
      });
    }
  }

  Future<void> _eliminarCotizacion() async {
    final estado =
        _cotizacion?['estado']?.toString().toLowerCase() ?? 'pendiente';

    if (estado != 'pendiente') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Solo se pueden eliminar cotizaciones pendientes.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Eliminar cotización?'),
        content: const Text(
          'Se eliminará la cotización y todos sus detalles. '
          'Esta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'ELIMINAR',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirmar != true) return;

    try {
      await ref
          .read(ventasRepositoryProvider)
          .eliminarCotizacion(widget.cotizacionId);

      if (!mounted) return;

      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cotización eliminada correctamente')),
      );
    } catch (e, st) {
      debugPrint('VerCotizacionPage: fallo al eliminar cotización: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(e)),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Color _colorEstado(String estado) {
    switch (estado.toLowerCase()) {
      case 'aprobada':
        return Colors.green;
      case 'vencida':
        return Colors.grey;
      case 'anulada':
        return Colors.red;
      default:
        return Colors.orange;
    }
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 54),
            const SizedBox(height: 16),
            Text(
              _errorCarga ?? 'No se pudo cargar la cotización.',
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color colorTexto = isDark ? Colors.white : const Color(0xFF1F2937);
    final Color colorGris = isDark ? Colors.white70 : const Color(0xFF6B7280);

    if (_cargando) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: const Text(
            'Detalle de Cotización',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          backgroundColor: colorTema,
          iconTheme: const IconThemeData(color: Colors.white),
          elevation: 0,
        ),
        body: const ShimmerDetalle(),
      );
    }

    if (_cotizacion == null) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: const Text(
            'Detalle de Cotización',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          backgroundColor: colorTema,
          iconTheme: const IconThemeData(color: Colors.white),
          elevation: 0,
        ),
        body: _buildErrorView(),
      );
    }

    final cotizacion = _cotizacion!;
    final total = (cotizacion['total'] as num).toDouble();
    final validezDias = (cotizacion['validez_dias'] as num?)?.toInt() ?? 15;
    final observaciones = cotizacion['observaciones']?.toString() ?? '';
    final estado = cotizacion['estado']?.toString() ?? 'pendiente';
    final colorEstado = _colorEstado(estado);
    final puedeEliminar = estado.toLowerCase() == 'pendiente';

    final nombreCliente = _cliente?['nombre']?.toString() ?? 'Cliente General';
    final documentoCliente = _cliente?['dni_ruc']?.toString() ?? '---';
    final direccionRaw = _cliente?['direccion']?.toString() ?? '-';
    final direccionCliente = direccionRaw == '-' || direccionRaw.trim().isEmpty
        ? 'No registrada'
        : direccionRaw;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Detalle de Cotización',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: colorTema,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Compartir PDF',
            onPressed: () => MobilePdfActions.compartir(
              context,
              TipoDocumento.cotizacion,
              cotizacion,
              _detalles,
              _cliente,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.print),
            tooltip: 'Imprimir PDF',
            onPressed: () => MobilePdfActions.imprimir(
              context,
              TipoDocumento.cotizacion,
              cotizacion,
              _detalles,
              _cliente,
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: colorTema.withValues(alpha: 0.08),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(20),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'COTIZACIÓN CT-${widget.cotizacionId.toString().padLeft(6, '0')}',
                                style: TextStyle(
                                  color: colorTema,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 18,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                AppFormatters.limaDateTimeText(
                                  cotizacion['fecha'],
                                ),
                                style: TextStyle(
                                  color: colorGris,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: colorEstado.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: colorEstado.withValues(alpha: 0.35),
                                ),
                              ),
                              child: Text(
                                estado.toUpperCase(),
                                style: TextStyle(
                                  color: colorEstado,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Válida por $validezDias días',
                              style: TextStyle(
                                color: Colors.grey.shade600,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.grey.shade900
                                    : Colors.grey.shade100,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.person, color: colorTema),
                            ),
                            const SizedBox(width: 15),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    nombreCliente,
                                    style: TextStyle(
                                      color: colorTexto,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'RUC/DNI: $documentoCliente',
                                    style: TextStyle(
                                      color: colorGris,
                                      fontSize: 13,
                                    ),
                                  ),
                                  if (direccionCliente != 'No registrada') ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      direccionCliente,
                                      style: TextStyle(
                                        color: colorGris,
                                        fontSize: 13,
                                      ),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (observaciones.isNotEmpty) ...[
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 15),
                            child: Divider(),
                          ),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.amber.shade900.withValues(
                                      alpha: 0.15,
                                    )
                                  : Colors.amber.shade50,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.amber.shade200),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Observaciones',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.amber.shade900,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  observaciones,
                                  style: TextStyle(
                                    color: Colors.amber.shade900,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 15),
                          child: Divider(height: 1),
                        ),
                        Container(
                          padding: const EdgeInsets.all(15),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.grey.shade900
                                : Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'TOTAL COTIZADO',
                                style: TextStyle(
                                  color: colorGris,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                AppFormatters.currency(total),
                                style: TextStyle(
                                  color: colorTema,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
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
                  Row(
                    children: [
                      Icon(Icons.shopping_bag_outlined, color: colorTema),
                      const SizedBox(width: 10),
                      Text(
                        'Productos (${_detalles.length})',
                        style: TextStyle(
                          color: colorTexto,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 15),
                  ..._detalles.map((detalle) {
                    final cantidad = (detalle['cantidad'] as num).toInt();
                    final subtotal = (detalle['subtotal'] as num).toDouble();
                    final precioComercial =
                        (detalle['precio_unitario_comercial'] as num?)
                            ?.toDouble() ??
                        subtotal / cantidad;
                    final tipoUnidad = StockUtils.normalizarTipoUnidad(
                      detalle['tipo_unidad']?.toString(),
                    );
                    final etiqueta = StockUtils.etiquetaUnidadComercial(
                      tipoUnidad,
                      cantidad: cantidad,
                    );
                    final pcs = (detalle['pcs_snapshot'] as num?)?.toInt() ?? 1;
                    final piezasReales =
                        (detalle['piezas_reales'] as num?)?.toInt() ?? cantidad;
                    final codigo = detalle['codigo_producto']?.toString();

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.grey.shade900
                              : Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isDark
                                ? Colors.grey.shade800
                                : Colors.grey.shade200,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: colorTema.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '$cantidad $etiqueta',
                                style: TextStyle(
                                  color: colorTema,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (codigo != null &&
                                      codigo.trim().isNotEmpty)
                                    Text(
                                      codigo,
                                      style: TextStyle(
                                        color: Colors.grey.shade600,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  Text(
                                    detalle['nombre_producto'].toString(),
                                    style: TextStyle(
                                      color: colorTexto,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'P.U. comercial: ${AppFormatters.currency(precioComercial)}',
                                    style: TextStyle(
                                      color: colorGris,
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (tipoUnidad == 'caja')
                                    Text(
                                      '$pcs por caja · '
                                      '$piezasReales ${detalle['unidad_base_snapshot'] ?? 'unidades'} base',
                                      style: TextStyle(
                                        color: Colors.grey.shade500,
                                        fontSize: 11,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Text(
                              AppFormatters.currency(subtotal),
                              style: TextStyle(
                                color: colorTexto,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 30),

            if (puedeEliminar)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text(
                    'ELIMINAR COTIZACIÓN',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                  onPressed: _eliminarCotizacion,
                ),
              ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
