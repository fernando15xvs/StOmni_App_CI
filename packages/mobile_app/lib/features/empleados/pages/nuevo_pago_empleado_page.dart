import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import 'package:core_logic/core_logic.dart';

class NuevoPagoEmpleadoPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> empleado;

  const NuevoPagoEmpleadoPage({super.key, required this.empleado});

  @override
  ConsumerState<NuevoPagoEmpleadoPage> createState() =>
      _NuevoPagoEmpleadoPageState();
}

class _NuevoPagoEmpleadoPageState extends ConsumerState<NuevoPagoEmpleadoPage> {
  final _detalleExtraCtrl = TextEditingController();

  DateTime _fecha = AppTime.now();
  bool _guardando = false;
  String _conceptoSeleccionado = 'Sueldo Semanal';

  final List<String> _conceptosPago = const [
    'Sueldo Semanal',
    'Adelanto',
    'Desayuno',
    'Almuerzo',
    'Otro',
  ];

  final List<String> _metodos = const [
    'Efectivo',
    'Tarjeta',
    'Transferencia',
    'Yape',
    'Plin',
    'Otro',
  ];

  final List<Map<String, dynamic>> _pagosAnadidos = [
    {
      'montoCtrl': TextEditingController(),
      'metodo': 'Efectivo',
      'afectaCajaChica': false,
    },
  ];

  @override
  void dispose() {
    _detalleExtraCtrl.dispose();
    for (final pago in _pagosAnadidos) {
      (pago['montoCtrl'] as TextEditingController).dispose();
    }
    super.dispose();
  }

  void _anadirFilaPago() {
    setState(() {
      _pagosAnadidos.add({
        'montoCtrl': TextEditingController(),
        'metodo': 'Efectivo',
        'afectaCajaChica': false,
      });
    });
  }

  void _eliminarFilaPago(int index) {
    if (_pagosAnadidos.length <= 1) return;
    setState(() {
      final controller =
          _pagosAnadidos[index]['montoCtrl'] as TextEditingController;
      controller.dispose();
      _pagosAnadidos.removeAt(index);
    });
  }

  double _monto(Map<String, dynamic> pago) {
    final controller = pago['montoCtrl'] as TextEditingController;
    return double.tryParse(controller.text.replaceAll(',', '.')) ?? 0.0;
  }

  double _calcularTotalPagado() {
    return _pagosAnadidos.fold<double>(
      0,
      (total, pago) => total + _monto(pago),
    );
  }

  bool _afectaCajaChica(Map<String, dynamic> pago) {
    return (pago['metodo'] as String).toLowerCase() == 'efectivo' &&
        pago['afectaCajaChica'] == true &&
        _monto(pago) > 0;
  }

  Future<void> _guardarPago() async {
    if (_guardando) return;

    final pagosParaBD = _pagosAnadidos
        .where((pago) => _monto(pago) > 0)
        .map(
          (pago) => <String, dynamic>{
            'metodo': pago['metodo'],
            'monto': _monto(pago),
            'afecta_caja_chica': pago['afectaCajaChica'] == true,
          },
        )
        .toList();

    if (pagosParaBD.isEmpty) {
      _mostrarSnack('El monto total debe ser mayor a 0.', Colors.red);
      return;
    }

    var conceptoFinal = _conceptoSeleccionado;
    if (_conceptoSeleccionado == 'Otro') {
      conceptoFinal = _detalleExtraCtrl.text.trim();
      if (conceptoFinal.isEmpty) {
        _mostrarSnack('Especifica el concepto del pago.', Colors.red);
        return;
      }
    }

    setState(() => _guardando = true);

    try {
      final pagosCaja = _pagosAnadidos.where(_afectaCajaChica).toList();
      if (pagosCaja.isNotEmpty) {
        final estado = await ref
            .read(empleadoPagoContextRepositoryProvider)
            .obtenerEstadoCajaChica();

        if (estado['estado']?.toString().toUpperCase() != 'ABIERTA') {
          throw const UserFacingException(
            'No hay Caja Chica abierta para hacer retiros en efectivo.',
          );
        }

        final totalCaja = pagosCaja.fold<double>(
          0,
          (total, pago) => total + _monto(pago),
        );
        final saldo =
            double.tryParse(estado['saldo_esperado']?.toString() ?? '0') ?? 0;
        if (totalCaja > saldo) {
          throw UserFacingException(
            'El saldo en Caja Chica (${AppFormatters.currency(saldo)}) es insuficiente.',
          );
        }
      }

      await ref.read(empleadosRepositoryProvider).registrarPagoEmpleadoMixto(
            empleadoId: (widget.empleado['id'] as num).toInt(),
            concepto: conceptoFinal,
            fechaIso: AppTime.toIsoLima(_fecha),
            pagos: pagosParaBD,
          );

      if (!mounted) return;
      _mostrarSnack('Pago registrado correctamente.', Colors.green);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      _mostrarSnack(ErrorMapper.map(e), Colors.red);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  void _mostrarSnack(String mensaje, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(mensaje), backgroundColor: color),
    );
  }

  Future<void> _seleccionarFecha() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _fecha,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date != null && mounted) {
      setState(() => _fecha = date);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorTema = AppColors.personal;
    final totalPagado = _calcularTotalPagado();
    final nombreEmpleado = widget.empleado['nombre']?.toString() ?? 'Empleado';

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          'Pago a $nombreEmpleado',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: colorTema,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _guardando ? null : _seleccionarFecha,
                icon: const Icon(Icons.calendar_today, size: 18),
                label: Text(DateFormat('dd MMMM yyyy').format(_fecha)),
                style: TextButton.styleFrom(foregroundColor: colorTema),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Concepto',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _conceptosPago.map((concepto) {
                final selected = _conceptoSeleccionado == concepto;
                return ChoiceChip(
                  label: Text(concepto),
                  selected: selected,
                  onSelected: _guardando
                      ? null
                      : (value) {
                          if (value) {
                            setState(() => _conceptoSeleccionado = concepto);
                          }
                        },
                  selectedColor: colorTema.withValues(alpha: 0.18),
                );
              }).toList(),
            ),
            if (_conceptoSeleccionado == 'Otro') ...[
              const SizedBox(height: 14),
              TextField(
                controller: _detalleExtraCtrl,
                enabled: !_guardando,
                decoration: InputDecoration(
                  labelText: 'Especificar concepto',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 28),
            Text(
              'Métodos de pago',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colorTema.withValues(alpha: isDark ? 0.10 : 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: colorTema.withValues(alpha: 0.18)),
              ),
              child: Column(
                children: [
                  for (var index = 0;
                      index < _pagosAnadidos.length;
                      index++) ...[
                    _buildPagoRow(index, isDark, colorTema),
                    if (index < _pagosAnadidos.length - 1)
                      const Divider(height: 22),
                  ],
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _guardando ? null : _anadirFilaPago,
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('Añadir pago'),
                    style: TextButton.styleFrom(foregroundColor: colorTema),
                  ),
                  const Divider(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'PAGO TOTAL:',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        AppFormatters.currency(totalPagado),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 110),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            boxShadow: const [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 10,
                offset: Offset(0, -4),
              ),
            ],
          ),
          child: SizedBox(
            height: 55,
            child: ElevatedButton(
              onPressed: _guardando ? null : _guardarPago,
              style: ElevatedButton.styleFrom(
                backgroundColor: colorTema,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
              child: _guardando
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'REGISTRAR SALIDA DE DINERO',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPagoRow(int index, bool isDark, Color colorTema) {
    final pago = _pagosAnadidos[index];
    final metodo = pago['metodo'] as String;
    final esEfectivo = metodo.toLowerCase() == 'efectivo';

    return Column(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: pago['montoCtrl'] as TextEditingController,
                enabled: !_guardando,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'Monto',
                  prefixText: 'S/ ',
                  filled: true,
                  fillColor: isDark
                      ? Colors.white.withValues(alpha: 0.04)
                      : Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: metodo,
                isExpanded: true,
                items: _metodos
                    .map(
                      (item) => DropdownMenuItem(
                        value: item,
                        child: Text(item, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(),
                onChanged: _guardando
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() {
                          pago['metodo'] = value;
                          if (value.toLowerCase() != 'efectivo') {
                            pago['afectaCajaChica'] = false;
                          }
                        });
                      },
                decoration: InputDecoration(
                  labelText: 'Método',
                  filled: true,
                  fillColor: isDark
                      ? Colors.white.withValues(alpha: 0.04)
                      : Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            if (_pagosAnadidos.length > 1)
              IconButton(
                tooltip: 'Eliminar pago',
                onPressed: _guardando ? null : () => _eliminarFilaPago(index),
                icon: const Icon(Icons.delete_outline, color: Colors.red),
              ),
          ],
        ),
        if (esEfectivo) ...[
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Retirar dinero de Caja Chica',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              'Se validará que exista una caja abierta y saldo suficiente.',
              style: TextStyle(fontSize: 11),
            ),
            secondary: const Icon(Icons.point_of_sale, color: Colors.orange),
            value: pago['afectaCajaChica'] == true,
            onChanged: _guardando
                ? null
                : (value) {
                    setState(() => pago['afectaCajaChica'] = value);
                  },
          ),
        ],
      ],
    );
  }
}
