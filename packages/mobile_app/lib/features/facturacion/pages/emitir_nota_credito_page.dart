import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import 'ver_nota_credito_page.dart';

class EmitirNotaCreditoPage extends ConsumerStatefulWidget {
  final String comprobanteId;
  final int ventaId;

  const EmitirNotaCreditoPage({
    super.key,
    required this.comprobanteId,
    required this.ventaId,
  });

  @override
  ConsumerState<EmitirNotaCreditoPage> createState() =>
      _EmitirNotaCreditoPageState();
}

class _EmitirNotaCreditoPageState extends ConsumerState<EmitirNotaCreditoPage> {
  final String _requestId = const Uuid().v4();
  static const Map<String, String> _motivos = {
    '01': 'Anulación total de la operación',
    '07': 'Devolución parcial de productos',
    '04': 'Descuento posterior',
    '03': 'Corrección de descripción',
  };

  bool _cargando = true;
  bool _guardando = false;
  String _motivoCodigo = '01';
  bool _reponerStock = true;

  Map<String, dynamic>? _comprobante;
  List<Map<String, dynamic>> _detalles = [];
  double _totalDisponible = 0;

  final Set<int> _seleccionados = {};
  final Map<int, TextEditingController> _cantidadCtrls = {};
  int? _detalleCorreccionId;

  final _montoDescuentoCtrl = TextEditingController();
  final _descripcionCorreccionCtrl = TextEditingController();
  final _motivoAdicionalCtrl = TextEditingController();

  Color get _colorPrincipal => Theme.of(context).colorScheme.primary;

  @override
  void initState() {
    super.initState();
    _cargarDisponibilidad();
  }

  @override
  void dispose() {
    for (final controller in _cantidadCtrls.values) {
      controller.dispose();
    }
    _montoDescuentoCtrl.dispose();
    _descripcionCorreccionCtrl.dispose();
    _motivoAdicionalCtrl.dispose();
    super.dispose();
  }

  int _precision(Map<String, dynamic> detail) {
    final raw = detail['quantity_precision'];
    if (raw is num) {
      return raw.toInt().clamp(0, FixedQuantity.maxScale).toInt();
    }
    return 0;
  }

  double _available(Map<String, dynamic> detail) =>
      (detail['cantidad_disponible'] as num?)?.toDouble() ?? 0;

  String _formatQuantity(double value) =>
      CommercialPresentation.formatNumber(value);

  Future<void> _cargarDisponibilidad() async {
    try {
      final data = await ref
          .read(notasCreditoRepositoryProvider)
          .obtenerDisponibilidad(widget.comprobanteId);

      final rawDetalles = data['detalles'];
      final detalles = rawDetalles is List
          ? List<Map<String, dynamic>>.from(
              rawDetalles.map((e) => Map<String, dynamic>.from(e as Map)),
            )
          : <Map<String, dynamic>>[];

      for (final controller in _cantidadCtrls.values) {
        controller.dispose();
      }
      _cantidadCtrls.clear();

      for (final detalle in detalles) {
        final id = (detalle['detalle_venta_id'] as num).toInt();
        final available = _available(detalle);
        final initial = available <= 0 ? 0 : (available < 1 ? available : 1);
        _cantidadCtrls[id] = TextEditingController(
          text: _formatQuantity(initial.toDouble()),
        );
      }

      if (!mounted) return;
      setState(() {
        _comprobante = data['comprobante'] is Map
            ? Map<String, dynamic>.from(data['comprobante'] as Map)
            : null;
        _detalles = detalles;
        _totalDisponible = (data['total_disponible'] as num?)?.toDouble() ?? 0;
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _cargando = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('No se pudo cargar la venta: $e')));
    }
  }

  String _descripcionServidor() {
    final adicional = _motivoAdicionalCtrl.text.trim();
    if (adicional.isNotEmpty) return adicional;
    return switch (_motivoCodigo) {
      '01' => 'ANULACION DE LA OPERACION',
      '07' => 'DEVOLUCION POR ITEM',
      '04' => 'DESCUENTO GLOBAL',
      '03' => 'CORRECCION POR ERROR EN LA DESCRIPCION',
      _ => 'NOTA DE CREDITO',
    };
  }

  Future<void> _emitir() async {
    if (_guardando) return;

    final esBoleta =
        (_comprobante?['tipo_documento_sunat'] ?? '')
            .toString()
            .trim()
            .toLowerCase() ==
        'boleta';
    if (esBoleta && _motivoCodigo == '04') {
      _mostrarError(
        'SUNAT no permite el descuento global (motivo 04) para boletas.',
      );
      return;
    }

    final detallesPayload = <Map<String, dynamic>>[];
    double? montoDescuento;

    if (_motivoCodigo == '07') {
      if (_seleccionados.isEmpty) {
        _mostrarError('Selecciona al menos un producto para devolver.');
        return;
      }

      for (final detalle in _detalles) {
        final id = (detalle['detalle_venta_id'] as num).toInt();
        if (!_seleccionados.contains(id)) continue;

        final cantidad = double.tryParse(
              (_cantidadCtrls[id]?.text ?? '').trim().replaceAll(',', '.'),
            ) ??
            0;
        final disponible = _available(detalle);
        final precision = _precision(detalle);
        try {
          FixedQuantity.fromDouble(cantidad, scale: precision);
        } on ArgumentError {
          _mostrarError(
            'La cantidad de ${detalle['nombre']} admite como máximo $precision decimal${precision == 1 ? '' : 'es'}.',
          );
          return;
        }
        if (cantidad <= 0 || cantidad > disponible + 0.0000001) {
          _mostrarError(
            'La cantidad de ${detalle['nombre']} debe ser mayor que 0 y no superar ${_formatQuantity(disponible)}.',
          );
          return;
        }

        detallesPayload.add({'detalle_venta_id': id, 'cantidad': cantidad});
      }
    } else if (_motivoCodigo == '04') {
      montoDescuento = double.tryParse(
        _montoDescuentoCtrl.text.trim().replaceAll(',', '.'),
      );
      if (montoDescuento == null || montoDescuento <= 0) {
        _mostrarError('Ingresa un monto de descuento mayor a cero.');
        return;
      }
      if (montoDescuento > _totalDisponible + 0.01) {
        _mostrarError(
          'El descuento no puede superar ${AppFormatters.currency(_totalDisponible)}.',
        );
        return;
      }
    } else if (_motivoCodigo == '03') {
      if (_detalleCorreccionId == null) {
        _mostrarError('Selecciona el producto cuya descripción corregirás.');
        return;
      }
      final descripcion = _descripcionCorreccionCtrl.text.trim();
      if (descripcion.isEmpty) {
        _mostrarError('Escribe la descripción correcta del producto.');
        return;
      }
      detallesPayload.add({
        'detalle_venta_id': _detalleCorreccionId,
        'descripcion_corregida': descripcion,
      });
    } else if (_motivoCodigo == '01' && _totalDisponible <= 0.01) {
      _mostrarError('El comprobante ya no tiene saldo tributario disponible.');
      return;
    }

    setState(() => _guardando = true);

    try {
      final creado = await ref
          .read(notasCreditoRepositoryProvider)
          .crearNotaCredito(
            requestId: _requestId,
            comprobanteId: widget.comprobanteId,
            motivoCodigo: _motivoCodigo,
            motivoDescripcion: _descripcionServidor(),
            detalles: detallesPayload,
            montoDescuento: montoDescuento,
            reponerStock:
                (_motivoCodigo == '01' || _motivoCodigo == '07') &&
                _reponerStock,
          );

      final notaId = creado['nota_credito_id']?.toString();
      if (notaId == null || notaId.isEmpty) {
        throw StateError('La base de datos no devolvió el ID de la nota.');
      }

      Map<String, dynamic>? resultadoEmision;
      try {
        resultadoEmision = await FacturacionService.emitirNotaCredito(notaId);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'La nota se creó, pero quedó pendiente de envío: $e',
              ),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }

      if (!mounted) return;

      final estado =
          resultadoEmision?['estado']?.toString() ??
          creado['estado']?.toString() ??
          'pendiente_envio';

      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => VerNotaCreditoPage(notaCreditoId: notaId),
        ),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            estado == 'aceptado'
                ? 'Nota de crédito aceptada por SUNAT.'
                : 'Nota creada. Revisa su estado de envío.',
          ),
          backgroundColor: estado == 'aceptado' ? Colors.green : Colors.orange,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _mostrarError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  void _mostrarError(String mensaje) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(mensaje), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Emitir Nota de Crédito',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: _colorPrincipal,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _cargando
          ? Center(child: CircularProgressIndicator(color: _colorPrincipal))
          : _comprobante == null
          ? const Center(child: Text('Comprobante no disponible'))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildResumen(),
                  const SizedBox(height: 16),
                  _buildMotivo(),
                  const SizedBox(height: 16),
                  _buildContenidoMotivo(),
                  const SizedBox(height: 16),
                  _buildMotivoAdicional(),
                  const SizedBox(height: 22),
                  SizedBox(
                    height: 54,
                    child: ElevatedButton.icon(
                      onPressed: _guardando ? null : _emitir,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _colorPrincipal,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      icon: _guardando
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.receipt_long, color: Colors.white),
                      label: Text(
                        _guardando ? 'PROCESANDO...' : 'EMITIR NOTA',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
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

  Widget _buildResumen() {
    final serie = _comprobante?['serie'] ?? '';
    final correlativo = _comprobante?['correlativo'] ?? '';
    final tipo = _comprobante?['tipo_documento_sunat']?.toString() ?? '';
    final total = (_comprobante?['total'] as num?)?.toDouble() ?? 0;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: _colorPrincipal.withValues(alpha: 0.1),
                child: Icon(Icons.verified, color: _colorPrincipal),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tipo.toUpperCase(),
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '$serie-$correlativo',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                'S/ ${NumberFormat('#,##0.00').format(total)}',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const Divider(height: 26),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Saldo disponible para notas'),
              Text(
                'S/ ${NumberFormat('#,##0.00').format(_totalDisponible)}',
                style: TextStyle(
                  color: _colorPrincipal,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMotivo() {
    final esBoleta =
        (_comprobante?['tipo_documento_sunat'] ?? '')
            .toString()
            .trim()
            .toLowerCase() ==
        'boleta';
    final motivosPermitidos = _motivos.entries
        .where((entry) => !(esBoleta && entry.key == '04'))
        .toList(growable: false);

    return _card(
      child: DropdownButtonFormField<String>(
        initialValue: _motivoCodigo,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Motivo de la nota de crédito',
          prefixIcon: Icon(Icons.rule),
          border: OutlineInputBorder(),
        ),
        items: motivosPermitidos
            .map(
              (entry) => DropdownMenuItem(
                value: entry.key,
                child: Text(
                  '${entry.key} - ${entry.value}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
            .toList(),
        onChanged: (value) {
          if (value == null) return;
          setState(() {
            _motivoCodigo = value;
            _seleccionados.clear();
            _detalleCorreccionId = null;
            _descripcionCorreccionCtrl.clear();
            _montoDescuentoCtrl.clear();
            _reponerStock = value == '01' || value == '07';
          });
        },
      ),
    );
  }

  Widget _buildContenidoMotivo() {
    return switch (_motivoCodigo) {
      '01' => _buildAnulacionTotal(),
      '07' => _buildDevolucionParcial(),
      '04' => _buildDescuentoPosterior(),
      '03' => _buildCorreccionDescripcion(),
      _ => const SizedBox.shrink(),
    };
  }

  Widget _buildAnulacionTotal() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Se emitirá una nota por el total completo del comprobante.',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Text(
            'La venta original se conservará como historial y quedará marcada tributariamente como anulada cuando SUNAT acepte la nota.',
            style: TextStyle(color: Colors.grey.shade700),
          ),
          const SizedBox(height: 12),
          _buildStockSwitch(),
        ],
      ),
    );
  }

  Widget _buildDevolucionParcial() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Productos a devolver',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          ..._detalles.map((detalle) {
            final id = (detalle['detalle_venta_id'] as num).toInt();
            final disponible = _available(detalle);
            final precision = _precision(detalle);
            final selected = _seleccionados.contains(id);

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: selected
                    ? _colorPrincipal.withValues(alpha: 0.06)
                    : Theme.of(context).brightness == Brightness.dark
                    ? Colors.grey.shade900
                    : Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected
                      ? _colorPrincipal
                      : Theme.of(context).brightness == Brightness.dark
                      ? Colors.grey.shade800
                      : Colors.grey.shade200,
                ),
              ),
              child: Row(
                children: [
                  Checkbox(
                    value: selected,
                    onChanged: disponible <= 0
                        ? null
                        : (value) {
                            setState(() {
                              if (value == true) {
                                _seleccionados.add(id);
                              } else {
                                _seleccionados.remove(id);
                              }
                            });
                          },
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          detalle['nombre']?.toString() ?? 'Producto',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          'Disponible: ${_formatQuantity(disponible)} ${detalle['tipo_unidad'] ?? ''}',
                          style: TextStyle(
                            color: disponible > 0
                                ? Colors.grey.shade600
                                : Colors.red,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 84,
                    child: TextField(
                      controller: _cantidadCtrls[id],
                      enabled: selected,
                      keyboardType: TextInputType.numberWithOptions(
                        decimal: precision > 0,
                      ),
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(
                        labelText: 'Cant.',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 8),
          _buildStockSwitch(),
        ],
      ),
    );
  }

  Widget _buildDescuentoPosterior() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Monto del descuento posterior',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _montoDescuentoCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText:
                  'Monto máximo ${AppFormatters.currency(_totalDisponible)}',
              prefixText: 'S/ ',
              prefixIcon: const Icon(Icons.discount),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Este motivo modifica el importe tributario, pero no cambia el stock.',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildCorreccionDescripcion() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Producto a corregir',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          RadioGroup<int>(
            groupValue: _detalleCorreccionId,
            onChanged: (value) {
              setState(() => _detalleCorreccionId = value);
            },
            child: Column(
              children: _detalles.map((detalle) {
                final id = (detalle['detalle_venta_id'] as num).toInt();
                return RadioListTile<int>(
                  value: id,
                  contentPadding: EdgeInsets.zero,
                  title: Text(detalle['nombre']?.toString() ?? 'Producto'),
                  subtitle: Text(detalle['codigo']?.toString() ?? ''),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _descripcionCorreccionCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Descripción corregida',
              prefixIcon: Icon(Icons.edit_note),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'La corrección de descripción no devuelve stock ni reduce el importe de la venta.',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildStockSwitch() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _colorPrincipal.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.inventory_2_outlined, color: _colorPrincipal),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Reposición de stock obligatoria',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 3),
                Text(
                  'El stock se devolverá una sola vez, únicamente después del CDR aceptado por SUNAT.',
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMotivoAdicional() {
    return _card(
      child: TextField(
        controller: _motivoAdicionalCtrl,
        maxLines: 2,
        decoration: const InputDecoration(
          labelText: 'Motivo u observación para SUNAT (opcional)',
          prefixIcon: Icon(Icons.notes),
          border: OutlineInputBorder(),
        ),
      ),
    );
  }
}
