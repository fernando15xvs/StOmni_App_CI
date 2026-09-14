import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:core_logic/core_logic.dart';
import '../../../core/widgets/document_form_kit.dart';
import '../../../core/widgets/editar_precios_documento_page.dart';
import '../../shared/widgets/product_card.dart';
import '../../shared/widgets/product_quantity_dialog.dart';
import '../../almacen/presentation/controllers/almacen_controller.dart';
import 'detalle_cotizacion_page.dart';

class NuevaCotizacionPage extends ConsumerStatefulWidget {
  const NuevaCotizacionPage({super.key});

  @override
  ConsumerState<NuevaCotizacionPage> createState() =>
      _NuevaCotizacionPageState();
}

class _NuevaCotizacionPageState extends ConsumerState<NuevaCotizacionPage> {
  final _searchController = TextEditingController();
  String _busqueda = '';

  SaleCart _carrito = SaleCart.empty();
  List<Map<String, dynamic>> _productosOriginal = [];
  List<Map<String, dynamic>> _configAlmacenes = [];
  Map<int, String> _mapaMarcas = {};

  final Color colorTema = AppDocColors.cotizacion;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _mostrarDialogoCantidad(Map<String, dynamic> producto) {
    showDialog(
      context: context,
      builder: (_) => ProductQuantityDialog(
        producto: producto,
        configAlmacenes: _configAlmacenes,
        carritoActual: _carrito,
        colorTema: colorTema,
        // Una cotización puede superar el stock actual.
        aplicarRestriccionStock: false,
        onConfirm: (nuevosItems) {
          setState(() {
            _carrito = _carrito.replaceProductLines(
              (producto['id'] as num).toInt(),
              nuevosItems,
            );
          });
        },
      ),
    );
  }

  void _eliminarDelCarrito(int productoId) {
    setState(() {
      _carrito = _carrito.removeProduct(productoId);
    });
  }

  double get _totalReferencial {
    return _carrito.totalAmount;
  }

  bool _coincideBusqueda(Map<String, dynamic> producto) {
    final consulta = _busqueda.trim().toLowerCase();
    if (consulta.isEmpty) return true;

    final nombre = producto['nombre']?.toString().toLowerCase() ?? '';
    final codigo = producto['codigo']?.toString().toLowerCase() ?? '';
    final codigoBarras =
        producto['codigo_barras']?.toString().toLowerCase() ?? '';
    final proveedorId = (producto['proveedor_id'] as num?)?.toInt();
    final marca = _mapaMarcas[proveedorId]?.toLowerCase() ?? '';

    return nombre.contains(consulta) ||
        codigo.contains(consulta) ||
        codigoBarras.contains(consulta) ||
        marca.contains(consulta);
  }

  @override
  Widget build(BuildContext context) {
    final almacenStateAsync = ref.watch(almacenNotifierProvider);

    if (!almacenStateAsync.hasValue && almacenStateAsync.isLoading) {
      return Scaffold(
        backgroundColor: Colors.grey[100],
        appBar: AppBar(
          title: const Text(
            'Nueva Cotización',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          backgroundColor: colorTema,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Center(child: CircularProgressIndicator(color: colorTema)),
      );
    }

    if (almacenStateAsync.hasError && !almacenStateAsync.hasValue) {
      return Scaffold(
        backgroundColor: Colors.grey[100],
        appBar: AppBar(
          title: const Text(
            'Nueva Cotización',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          backgroundColor: colorTema,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Center(child: Text('Error: ${almacenStateAsync.error}')),
      );
    }

    final almacenState = almacenStateAsync.value!;
    _productosOriginal = almacenState.productosCompletos;
    _configAlmacenes = almacenState.configAlmacenes;
    _mapaMarcas = almacenState.mapaMarcas;

    final listaVisual = _productosOriginal.where(_coincideBusqueda).toList();

    listaVisual.sort((a, b) {
      final aSeleccionado = _carrito.containsProduct((a['id'] as num).toInt());
      final bSeleccionado = _carrito.containsProduct((b['id'] as num).toInt());

      if (aSeleccionado && !bSeleccionado) return -1;
      if (!aSeleccionado && bSeleccionado) return 1;

      return (a['nombre']?.toString() ?? '').compareTo(
        b['nombre']?.toString() ?? '',
      );
    });

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Nueva Cotización',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: colorTema,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: Column(
        children: [
          if (almacenStateAsync.isLoading && almacenStateAsync.hasValue)
            LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: colorTema.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation<Color>(colorTema),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
            decoration: BoxDecoration(
              color: colorTema,
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(20),
              ),
            ),
            child: Center(
              child: Container(
                constraints: const BoxConstraints(maxWidth: 800),
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Buscar por código, producto o marca...',
                    hintStyle: TextStyle(color: Colors.grey[400]),
                    prefixIcon: Icon(Icons.search, color: colorTema),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, color: Colors.grey),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _busqueda = '');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: Theme.of(context).brightness == Brightness.dark
                        ? Colors.grey.shade900
                        : Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 0,
                      horizontal: 20,
                    ),
                  ),
                  onChanged: (valor) {
                    setState(() => _busqueda = valor.toLowerCase());
                  },
                ),
              ),
            ),
          ),
          Expanded(
            child: listaVisual.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.search_off,
                          size: 60,
                          color: Colors.grey[300],
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'No se encontraron productos',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth > 900) {
                        return GridView.builder(
                          padding: const EdgeInsets.all(16),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 4,
                                childAspectRatio: 0.78,
                                crossAxisSpacing: 12,
                                mainAxisSpacing: 12,
                              ),
                          itemCount: listaVisual.length,
                          itemBuilder: (context, index) {
                            final producto = listaVisual[index];

                            return ProductCard(
                              producto: producto,
                              mapaMarcas: _mapaMarcas,
                              carrito: _carrito,
                              isDesktop: true,
                              colorTema: colorTema,
                              onTap: () => _mostrarDialogoCantidad(producto),
                              onDeleteFromCart: () => _eliminarDelCarrito(
                                (producto['id'] as num).toInt(),
                              ),
                            );
                          },
                        );
                      }

                      return ListView.builder(
                        itemCount: listaVisual.length,
                        padding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: 16,
                        ),
                        itemBuilder: (context, index) {
                          final producto = listaVisual[index];

                          return ProductCard(
                            producto: producto,
                            mapaMarcas: _mapaMarcas,
                            carrito: _carrito,
                            isDesktop: false,
                            colorTema: colorTema,
                            onTap: () => _mostrarDialogoCantidad(producto),
                            onDeleteFromCart: () => _eliminarDelCarrito(
                              (producto['id'] as num).toInt(),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey.shade900
              : Colors.white,
          boxShadow: Theme.of(context).brightness == Brightness.dark
              ? []
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 10,
                    offset: const Offset(0, -2),
                  ),
                ],
        ),
        child: SafeArea(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_carrito.lineCount} presentaciones cotizadas',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12),
                    ),
                    Text(
                      'Total: S/ ${NumberFormat('#,##0.00').format(_totalReferencial)}',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: colorTema,
                      ),
                    ),
                  ],
                ),
              ),
              ElevatedButton(
                onPressed: _carrito.isNotEmpty
                    ? () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => EditarPreciosDocumentoPage(
                              carritoDetallado: _carrito,
                              titulo: 'Ajustar Precios',
                              colorTema: AppDocColors.cotizacion,
                              textoBoton: 'FINALIZAR',
                              onContinuar: (ctx, carritoFinal, total) {
                                Navigator.push(
                                  ctx,
                                  MaterialPageRoute(
                                    builder: (_) => DetalleCotizacionPage(
                                      carritoConPreciosFinales: carritoFinal,
                                      totalAPagar: total,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      }
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1F2937),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 25,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                  elevation: 3,
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'CONTINUAR',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    SizedBox(width: 5),
                    Icon(Icons.arrow_forward, size: 18),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
