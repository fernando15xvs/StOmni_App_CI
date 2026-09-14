import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:core_logic/core_logic.dart';
import 'gre_form_card.dart';

class GreProductosSection extends StatelessWidget {
  const GreProductosSection({
    super.key,
    required this.color,
    required this.detalles,
    required this.onAgregar,
    required this.onEditar,
    required this.onEliminar,
  });

  final Color color;
  final List<Map<String, dynamic>> detalles;
  final VoidCallback onAgregar;
  final ValueChanged<int> onEditar;
  final ValueChanged<int> onEliminar;

  @override
  Widget build(BuildContext context) {
    return GreFormCard(
      title: 'Productos',
      color: color,
      trailing: IconButton(
        onPressed: onAgregar,
        icon: const Icon(Icons.add_circle),
        color: color,
        tooltip: 'Agregar producto',
      ),
      child: detalles.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Todavía no hay productos.'),
            )
          : Column(
              children: detalles.asMap().entries.map((entry) {
                final index = entry.key;
                final item = entry.value;
                final cantidad = (item['cantidad'] as num?) ?? 0;
                final peso = (item['peso_total_kg'] as num?) ?? 0;
                final precio = (item['precio_unitario'] as num?) ?? 0;

                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  onTap: () => onEditar(index),
                  title: Text(
                    item['descripcion']?.toString() ?? 'Producto',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    '${item['codigo'] ?? ''} · '
                    '${NumberFormat("#,##0.###").format(peso)} kg\n'
                    'Precio: S/ ${NumberFormat("#,##0.00").format(precio)} · '
                    'Total: S/ ${NumberFormat("#,##0.00").format(precio * cantidad)}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${NumberFormat('#,##0.###').format(cantidad)} '
                        '${GreItemRules.nombreUnidad(item['unidad']?.toString() ?? '')}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        onPressed: () => onEditar(index),
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Editar',
                      ),
                      IconButton(
                        onPressed: () => onEliminar(index),
                        icon: const Icon(Icons.close, color: Colors.red),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
    );
  }
}
