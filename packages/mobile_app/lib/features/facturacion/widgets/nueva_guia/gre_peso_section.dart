import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'gre_form_card.dart';

class GrePesoSection extends StatelessWidget {
  const GrePesoSection({
    super.key,
    required this.color,
    required this.controller,
    required this.cantidadBultosController,
    required this.pesoEditado,
    required this.onPesoChanged,
    required this.onRecalcular,
  });

  final Color color;
  final TextEditingController controller;
  final TextEditingController cantidadBultosController;
  final bool pesoEditado;
  final ValueChanged<String> onPesoChanged;
  final VoidCallback onRecalcular;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    InputDecoration decoration({
      required String label,
      required IconData icon,
      String? suffix,
    }) {
      return InputDecoration(
        labelText: label,
        floatingLabelStyle: TextStyle(color: color),
        prefixIcon: Icon(
          icon,
          color: isDark ? Colors.grey[400] : Colors.grey[600],
          size: 20,
        ),
        filled: true,
        fillColor: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.grey.withValues(alpha: 0.05),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.1)
                : Colors.grey.withValues(alpha: 0.2),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: color, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        suffixText: suffix,
      );
    }

    return GreFormCard(
      title: 'Carga',
      color: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: onPesoChanged,
            decoration: decoration(
              label: 'Peso total en kilogramos',
              icon: Icons.monitor_weight,
              suffix: 'kg',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            pesoEditado
                ? 'Peso editado manualmente.'
                : 'Se calcula con el peso registrado en los productos. '
                      'Puedes modificarlo antes de emitir.',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
          if (pesoEditado)
            TextButton(
              onPressed: onRecalcular,
              child: const Text('VOLVER A CALCULAR'),
            ),
          const SizedBox(height: 14),
          TextField(
            controller: cantidadBultosController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: decoration(
              label: 'Número de bultos (opcional)',
              icon: Icons.inventory_2_outlined,
              suffix: 'bultos',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Indica cuántos paquetes físicos viajan en el traslado. '
            'No es la cantidad de productos ni de cajas comerciales.',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
