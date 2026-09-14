import 'dart:async';
import 'package:flutter/material.dart';

class BuscadorInventario extends StatefulWidget {
  final Color colorTema;
  final List<Map<String, dynamic>> productosCompletos;
  final bool soloStockBajo;
  final void Function(List<Map<String, dynamic>> resultados, String query)
  onResultados;

  const BuscadorInventario({
    super.key,
    required this.colorTema,
    required this.productosCompletos,
    required this.soloStockBajo,
    required this.onResultados,
  });

  @override
  State<BuscadorInventario> createState() => _BuscadorInventarioState();
}

class _BuscadorInventarioState extends State<BuscadorInventario> {
  final _searchController = TextEditingController();
  Timer? _debouncer;

  @override
  void dispose() {
    _searchController.dispose();
    _debouncer?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    final busqueda = query.toLowerCase();

    // El parent (AlmacenPage) ignora 'temporal' y solo usa 'busqueda',
    // pero mantenemos la firma del callback onResultados por compatibilidad.
    widget.onResultados([], busqueda);

    // Solo para actualizar el icono X del TextField
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 800),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(30),
            boxShadow: Theme.of(context).brightness == Brightness.dark
                ? []
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Buscar por código, nombre o marca...',
              hintStyle: TextStyle(color: Colors.grey[400]),
              prefixIcon: Icon(Icons.search, color: widget.colorTema),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: Colors.grey),
                      onPressed: () {
                        _searchController.clear();
                        _onSearchChanged("");
                        FocusScope.of(context).unfocus();
                      },
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onChanged: _onSearchChanged,
          ),
        ),
      ),
    );
  }
}