import 'package:flutter/material.dart';

import 'package:core_logic/core_logic.dart';

class GreProductoEdicion {
  const GreProductoEdicion({
    required this.descripcion,
    required this.cantidad,
    required this.unidad,
    required this.piezasReales,
    required this.pesoUnitarioKg,
  });

  final String descripcion;
  final double cantidad;
  final String unidad;
  final int piezasReales;
  final double pesoUnitarioKg;

  void aplicarA(Map<String, dynamic> item) {
    item['descripcion'] = descripcion;
    item['cantidad'] = cantidad;
    item['unidad'] = unidad;
    item['piezas_reales'] = piezasReales;
    item['peso_unitario_kg'] = pesoUnitarioKg;
    item['peso_total_kg'] = pesoUnitarioKg * piezasReales;
  }
}

Future<GreProductoEdicion?> mostrarGreProductoEditor({
  required BuildContext context,
  required Map<String, dynamic> item,
  required Map<String, dynamic>? producto,
}) {
  return showDialog<GreProductoEdicion>(
    context: context,
    builder: (_) => _GreProductoEditorDialog(item: item, producto: producto),
  );
}

class _GreProductoEditorDialog extends StatefulWidget {
  const _GreProductoEditorDialog({required this.item, required this.producto});

  final Map<String, dynamic> item;
  final Map<String, dynamic>? producto;

  @override
  State<_GreProductoEditorDialog> createState() =>
      _GreProductoEditorDialogState();
}

class _GreProductoEditorDialogState extends State<_GreProductoEditorDialog> {
  late final TextEditingController _descripcion;
  late final TextEditingController _cantidad;
  late final TextEditingController _peso;
  late String _unidad;
  late int _piezasActuales;
  late List<String> _unidadesPermitidas;
  String? _error;

  @override
  void initState() {
    super.initState();
    final cantidadActual = (widget.item['cantidad'] as num?)?.toDouble() ?? 0;
    _piezasActuales =
        (widget.item['piezas_reales'] as num?)?.toInt() ??
        cantidadActual.round();
    _descripcion = TextEditingController(
      text: widget.item['descripcion']?.toString() ?? '',
    );
    _cantidad = TextEditingController(text: cantidadActual.toString());
    _peso = TextEditingController(
      text: ((widget.item['peso_unitario_kg'] as num?)?.toDouble() ?? 0)
          .toStringAsFixed(3),
    );
    _unidad = widget.item['unidad']?.toString().trim().toUpperCase() ?? 'NIU';
    _unidadesPermitidas = GreItemRules.unidadesPermitidas(
      widget.producto,
      _unidad,
    );
  }

  @override
  void dispose() {
    _descripcion.dispose();
    _cantidad.dispose();
    _peso.dispose();
    super.dispose();
  }

  void _guardar() {
    try {
      final nuevaCantidad =
          double.tryParse(_cantidad.text.replaceAll(',', '.')) ?? 0;
      final nuevoPeso = double.tryParse(_peso.text.replaceAll(',', '.')) ?? -1;
      if (nuevoPeso < 0) {
        throw const FormatException('El peso no puede ser negativo.');
      }

      final piezas = GreItemRules.calcularPiezasDetalle(
        producto: widget.producto,
        unidadSunat: _unidad,
        cantidadVisual: nuevaCantidad,
        piezasFallback: _piezasActuales,
      );

      Navigator.pop(
        context,
        GreProductoEdicion(
          descripcion: _descripcion.text.trim(),
          cantidad: nuevaCantidad,
          unidad: _unidad,
          piezasReales: piezas,
          pesoUnitarioKg: nuevoPeso,
        ),
      );
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } on ArgumentError catch (e) {
      setState(() => _error = e.message?.toString() ?? e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Editar producto de la guía'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _descripcion,
                decoration: const InputDecoration(
                  labelText: 'Descripción',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _cantidad,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Cantidad trasladada',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _unidad,
                items: _unidadesPermitidas
                    .map(
                      (code) => DropdownMenuItem(
                        value: code,
                        child: Text(GreItemRules.nombreUnidad(code)),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) setState(() => _unidad = value);
                },
                decoration: const InputDecoration(
                  labelText: 'Unidad de medida',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _peso,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Peso por unidad base (kg)',
                  helperText:
                      'Ejemplo: en Caja + Unidades, ingresa el peso '
                      'de una unidad, no el peso de toda la caja.',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(onPressed: _guardar, child: const Text('GUARDAR')),
      ],
    );
  }
}
