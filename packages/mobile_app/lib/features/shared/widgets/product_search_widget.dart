import 'dart:async';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:core_logic/core_logic.dart';
import '../providers/search_revision_provider.dart';

class ProductSearchWidget extends ConsumerStatefulWidget {
  final Future<List<ProductoBusqueda>> Function(String query) onSearch;
  final Function(Map<String, dynamic>)
  onProductoSelected; // Mantenemos compatibilidad de salida
  final VoidCallback? onCleared;
  final String? initialValue;
  final bool autofocus;
  final Color primaryColor;

  const ProductSearchWidget({
    super.key,
    required this.onSearch,
    required this.onProductoSelected,
    this.onCleared,
    this.initialValue,
    this.autofocus = false,
    this.primaryColor = Colors.teal,
  });

  @override
  ConsumerState<ProductSearchWidget> createState() =>
      _ProductSearchWidgetState();
}

class _ProductSearchWidgetState extends ConsumerState<ProductSearchWidget> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final LayerLink _layerLink = LayerLink();

  Timer? _debouncer;
  OverlayEntry? _overlayEntry;

  List<ProductoBusqueda> _resultados = [];
  bool _buscando = false;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();

    // Disparar sincronización silenciosa al abrir el buscador (búsqueda vacía inicial)
    _sincronizacionSilenciosa();

    if (widget.initialValue != null) {
      _controller.text = widget.initialValue!;
    }
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        _removerOverlay();
      } else if (_resultados.isNotEmpty || _buscando) {
        _mostrarOverlay();
      }
    });
  }

  Future<void> _sincronizacionSilenciosa() async {
    if (_initialized) return;
    _initialized = true;
    try {
      // Hacemos una búsqueda vacía para forzar el fallback si la base está vacía.
      // También podríamos agregar una llamada explícita de sync aquí si quisiéramos.
      final results = await widget.onSearch('');
      if (mounted && _controller.text.isEmpty && _focusNode.hasFocus) {
        setState(() => _resultados = results);
        _mostrarOverlay();
      }
    } catch (e) {
      debugPrint('Error en sync inicial de buscador: $e');
    }
  }

  @override
  void dispose() {
    _debouncer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    _removerOverlay();
    super.dispose();
  }

  void _buscar(String query) {
    if (_debouncer?.isActive ?? false) _debouncer!.cancel();

    if (query.trim().isEmpty) {
      setState(() {
        _resultados = [];
        _buscando = false;
      });
      _removerOverlay();
      if (widget.onCleared != null) widget.onCleared!();
      return;
    }

    // Reducimos el debouncer a 50ms porque SQLite es instantáneo,
    // eliminando la espera artificial que era necesaria para llamadas de red.
    _debouncer = Timer(const Duration(milliseconds: 50), () async {
      setState(() => _buscando = true);
      if (_focusNode.hasFocus) _mostrarOverlay();

      try {
        final filtrados = await widget.onSearch(query);
        if (mounted) {
          setState(() {
            _resultados = filtrados;
            _buscando = false;
          });
          if (_focusNode.hasFocus) _mostrarOverlay();
        }
      } catch (e) {
        if (mounted) {
          setState(() => _buscando = false);
        }
      }
    });
  }

  void _removerOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _mostrarOverlay() {
    if (!mounted) return;
    _removerOverlay();

    if (_resultados.isEmpty && !_buscando) return;

    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final size = renderBox.size;

    _overlayEntry = OverlayEntry(
      builder: (context) {
        return Positioned(
          width: size.width,
          child: CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            offset: Offset(0, size.height + 5),
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(12),
              color: Theme.of(context).cardColor,
              child: Container(
                constraints: const BoxConstraints(maxHeight: 280),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.grey.shade200,
                  ),
                ),
                child: _buscando
                    ? Padding(
                        padding: const EdgeInsets.all(20),
                        child: Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: widget.primaryColor,
                            ),
                          ),
                        ),
                      )
                    : _resultados.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(20),
                        child: Center(
                          child: Text(
                            "No se encontraron productos",
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        shrinkWrap: true,
                        itemCount: _resultados.length,
                        itemBuilder: (context, index) {
                          final ProductoBusqueda p = _resultados[index];

                          // Calcular stock sumando inventario_almacen
                          int totalPiezas = 0;
                          for (var item in p.inventarioAlmacenes) {
                            totalPiezas +=
                                (item['cantidad'] as num?)?.toInt() ?? 0;
                          }

                          final String stockMostrado = StockUtils.formatStock(
                            totalPiezas,
                            p.cantidadPorCaja,
                            StockUtils.getTipoVentaFromString(p.tipoVenta),
                          );

                          return ListTile(
                            leading: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: p.activo
                                    ? widget.primaryColor.withValues(alpha: 0.1)
                                    : Colors.grey.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(
                                Icons.inventory_2,
                                color: p.activo
                                    ? widget.primaryColor
                                    : Colors.grey,
                              ),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    p.nombre,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: p.activo
                                          ? widget.primaryColor
                                          : Colors.grey,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                                if (!p.activo)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.red.shade100,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'INACTIVO',
                                      style: TextStyle(
                                        color: Colors.red.shade900,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: Text(
                              'Venta por: ${p.tipoVenta}\nStock: $stockMostrado',
                              style: TextStyle(
                                color:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Colors.white
                                    : Colors.grey.shade600,
                                fontSize: 12,
                              ),
                            ),
                            trailing: const Icon(
                              Icons.chevron_right,
                              color: Colors.grey,
                            ),
                            onTap: () {
                              _controller.text = p.nombre;
                              _removerOverlay();
                              _focusNode.unfocus();
                              widget.onProductoSelected(
                                p.toMap(),
                              ); // Conversión para compatibilidad
                            },
                          );
                        },
                      ),
              ),
            ),
          ),
        );
      },
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  Future<void> _refreshSilencioso() async {
    if (_controller.text.trim().isEmpty) return;
    try {
      final results = await widget.onSearch(_controller.text);
      if (mounted) {
        setState(() {
          _resultados = results;
        });
        if (_overlayEntry != null && _overlayEntry!.mounted) {
          _overlayEntry!.markNeedsBuild();
        }
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(productSearchRevisionProvider, (prev, next) {
      if (prev != next) {
        _refreshSilencioso();
      }
    });

    return CompositedTransformTarget(
      link: _layerLink,
      child: TextField(
        controller: _controller,
        focusNode: _focusNode,
        onChanged: _buscar,
        autofocus: widget.autofocus,
        decoration: InputDecoration(
          hintText: 'Buscar producto...',
          labelText: 'Nombre del producto',
          floatingLabelStyle: TextStyle(
            color: widget.primaryColor,
            fontWeight: FontWeight.bold,
          ),
          prefixIcon: Icon(Icons.search, color: widget.primaryColor),
          suffixIcon: _controller.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _controller.clear();
                    _buscar('');
                  },
                )
              : null,
          filled: true,
          fillColor: Theme.of(context).brightness == Brightness.dark
              ? Colors.white.withValues(alpha: 0.04)
              : Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: BorderSide(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.grey.shade300,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: BorderSide(
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.grey.shade300,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: BorderSide(color: widget.primaryColor, width: 2),
          ),
        ),
      ),
    );
  }
}
