import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/stock_utils.dart';

class AlmacenStockInput extends StatelessWidget {
  final String nombreAlmacen;
  final SaleUnitType tipoVenta;
  final TextEditingController cajasController;
  final TextEditingController unidadesController;
  final ValueChanged<String>? onChanged;
  final int baseQuantityPrecision;
  final String? baseQuantityLabel;
  final bool configuredBaseMode;

  const AlmacenStockInput({
    super.key,
    required this.nombreAlmacen,
    required this.tipoVenta,
    required this.cajasController,
    required this.unidadesController,
    this.onChanged,
    this.baseQuantityPrecision = 0,
    this.baseQuantityLabel,
    this.configuredBaseMode = false,
  });

  @override
  Widget build(BuildContext context) {
    if (configuredBaseMode) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.store, color: Colors.grey[600], size: 18),
                const SizedBox(width: 8),
                Text(
                  nombreAlmacen,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.grey[300]
                        : Colors.grey[800],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _buildField(
              context,
              controller: unidadesController,
              label: baseQuantityLabel?.trim().isNotEmpty == true
                  ? 'Cantidad (${baseQuantityLabel!.trim()})'
                  : 'Cantidad base',
              icon: Icons.scale_outlined,
              precision: baseQuantityPrecision,
            ),
          ],
        ),
      );
    }

    final esMixto = StockUtils.esMixto(tipoVenta);
    final esPaqueteSimple = tipoVenta == SaleUnitType.paquete;

    final etiquetaBase = tipoVenta == SaleUnitType.cajaPaquetes
        ? 'Paquetes'
        : tipoVenta == SaleUnitType.cajaUnidades
        ? 'Unidades'
        : esPaqueteSimple
        ? 'Paquetes'
        : tipoVenta == SaleUnitType.unidad
        ? 'Unidades'
        : 'Sueltas';

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.store, color: Colors.grey[600], size: 18),
              const SizedBox(width: 8),
              Text(
                nombreAlmacen,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.grey[300]
                      : Colors.grey[800],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (esMixto || tipoVenta == SaleUnitType.caja)
                Expanded(
                  child: _buildField(
                    context,
                    controller: cajasController,
                    label: 'Cajas',
                    icon: Icons.inventory_2,
                  ),
                ),
              if (esMixto) const SizedBox(width: 10),
              if (esPaqueteSimple ||
                  esMixto ||
                  tipoVenta == SaleUnitType.unidad)
                Expanded(
                  child: _buildField(
                    context,
                    controller: unidadesController,
                    label: etiquetaBase,
                    icon:
                        esPaqueteSimple ||
                            tipoVenta == SaleUnitType.cajaPaquetes
                        ? Icons.all_inbox_outlined
                        : Icons.extension_outlined,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildField(
    BuildContext context, {
    required TextEditingController controller,
    required String label,
    required IconData icon,
    int precision = 0,
  }) {
    final allowsDecimal = precision > 0;
    return TextField(
      controller: controller,
      keyboardType: TextInputType.numberWithOptions(decimal: allowsDecimal),
      inputFormatters: [
        if (allowsDecimal)
          TextInputFormatter.withFunction((oldValue, newValue) {
            final normalized = newValue.text.replaceAll(',', '.');
            final pattern = RegExp('^\\d*(?:\\.\\d{0,$precision})?\$');
            if (!pattern.hasMatch(normalized)) return oldValue;
            return newValue.copyWith(
              text: normalized,
              selection: TextSelection.collapsed(offset: normalized.length),
            );
          })
        else
          FilteringTextInputFormatter.digitsOnly,
      ],
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: Colors.grey, size: 20),
        filled: true,
        fillColor: Theme.of(context).brightness == Brightness.dark
            ? Colors.grey[800]
            : Colors.grey.shade50,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.grey[700]!
                : Colors.grey.shade300,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.grey[700]!
                : Colors.grey.shade300,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.greenAccent
                : const Color(0xFF0F9D58),
            width: 2,
          ),
        ),
        floatingLabelStyle: TextStyle(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.greenAccent
              : const Color(0xFF0F9D58),
          fontWeight: FontWeight.bold,
        ),
      ),
      onChanged: onChanged,
    );
  }
}
