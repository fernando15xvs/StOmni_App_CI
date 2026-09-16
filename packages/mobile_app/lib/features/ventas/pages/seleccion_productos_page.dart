import 'package:core_logic/core_logic.dart';
import 'package:core_logic/features/ventas/providers/sale_pricing_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/widgets/document_form_kit.dart';
import '../../../core/widgets/editar_precios_documento_page.dart';
import '../../shared/widgets/product_card.dart';
import '../../shared/widgets/product_quantity_dialog.dart';
import '../presentation/controllers/carrito_controller.dart';
import '../../almacen/presentation/controllers/almacen_controller.dart';
import 'venta_page.dart';

class SeleccionProductosV2 extends ConsumerStatefulWidget {
  final void Function(
    BuildContext context,
    SaleCart carritoFinal,
    double total,
  )?
  onContinuarFlow;

  const SeleccionProductosV2({super.key, this.onContinuarFlow});

  @override
  ConsumerState<SeleccionProductosV2> createState() =>
      _SeleccionProductosV2State();
}

class _SeleccionProductosV2State extends ConsumerState<SeleccionProductosV2> {
  final _searchController = TextEditingController();
  String busqueda = "";

  List<Map<String, dynamic>> _productosOriginal = [];
  List<Map<String, dynamic>> configalmacenes = [];
  Map<int, String> _mapaMarcas = {};

  bool _modoOffline = false;

  Color get colorVerde => Theme.of(context).colorScheme.primary;

  @override
  void initState() {
    super.initState();
  }

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
        configAlmacenes: configalmacenes,
        carritoActual: ref.read(carritoProvider),
        colorTema: Theme.of(context).colorScheme.primary,
        aplicarRestriccionStock: !(producto['permitir_sin_stock'] ?? false),
        onConfirm: (nuevosItems) {
          ref
              .read(carritoProvider.notifier)
              .actualizarProducto(producto['id'], nuevosItems);
        },
      ),
    );
  }

  void _eliminarDelCarrito(int productoId) {
    ref.read(carritoProvider.notifier).eliminarProducto(productoId);
  }

  Future<void> _continuar() async {
    var cart = ref.read(carritoProvider);
    if (!_modoOffline) {
      try {
        final pricing = ref.read(authoritativePriceSaleLineUseCaseProvider);
        final priced = <SaleCartLine>[];
        for (final line in cart.lines) {
          priced.add(await pricing.execute(line));
        }
        cart = SaleCart(priced);
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMapper.map(error))));
        return;
      }
    }
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditarPreciosDocumentoPage(
          carritoDetallado: cart,
          titulo: widget.onContinuarFlow != null
              ? 'Definir Detalles'
              : 'Definir Precios',
          colorTema: AppDocColors.venta(context),
          onContinuar:
              widget.onContinuarFlow ??
              (ctx, carritoFinal, total) {
                Navigator.push(
                  ctx,
                  MaterialPageRoute(
                    builder: (_) => DetalleVentaPage(
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

  @override
  Widget build(BuildContext context) {
    final carrito = ref.watch(carritoProvider);
    final carritoNotifier = ref.read(carritoProvider.notifier);
    final almacenStateAsync = ref.watch(almacenNotifierProvider);

    final String resumenCantidades = carritoNotifier.resumenCantidades;
    final double dineroTotal = carritoNotifier.totalDinero;

    if (!almacenStateAsync.hasValue && almacenStateAsync.isLoading) {
      return Scaffold(
        backgroundColor: Colors.grey[100],
        appBar: AppBar(
          title: const Text(
            'Seleccionar Productos',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          backgroundColor: Theme.of(context).colorScheme.primary,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Center(
          child: CircularProgressIndicator(
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }

    if (almacenStateAsync.hasError && !almacenStateAsync.hasValue) {
      return Scaffold(
        backgroundColor: Colors.grey[100],
        appBar: AppBar(
          title: const Text(
            'Seleccionar Productos',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          backgroundColor: Theme.of(context).colorScheme.primary,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Center(child: Text("Error: ${almacenStateAsync.error}")),
      );
    }

    final almacenState = almacenStateAsync.value!;
    _productosOriginal = almacenState.productosCompletos;
    configalmacenes = almacenState.configAlmacenes;
    _mapaMarcas = almacenState.mapaMarcas;
    _modoOffline = almacenState.modoOffline;

    final selectedProductIds = carrito.lines
        .map((line) => line.productId)
        .toSet();
    final listaVisual = SaleProductSelection.filterAndSortLegacy(
      products: _productosOriginal,
      brandByProviderId: _mapaMarcas,
      query: busqueda,
      selectedProductIds: selectedProductIds,
    );

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Row(
          children: [
            const Text(
              'Seleccionar Productos',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (_modoOffline) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.orange,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.wifi_off, color: Colors.white, size: 12),
                    SizedBox(width: 4),
                    Text(
                      "OFFLINE",
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.primary,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: Column(
        children: [
          if (almacenStateAsync.isLoading && almacenStateAsync.hasValue)
            LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context).colorScheme.primary,
              ),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
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
                    hintText: 'Buscar por código, nombre o marca...',
                    hintStyle: TextStyle(color: Colors.grey[400]),
                    prefixIcon: Icon(
                      Icons.search,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, color: Colors.grey),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => busqueda = "");
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: Theme.of(context).brightness == Brightness.dark
                        ? Colors.grey[900]
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
                  onChanged: (val) =>
                      setState(() => busqueda = val.toLowerCase()),
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
                          "No se encontraron productos",
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth > 900) {
                        return _buildDesktopGrid(
                          listaVisual,
                          constraints.maxWidth,
                          carrito,
                        );
                      } else {
                        return _buildMobileList(listaVisual, carrito);
                      }
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          boxShadow: [
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
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    resumenCantidades,
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                  Text(
                    'Total Ref: S/ ${NumberFormat('#,##0.00').format(dineroTotal)}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.greenAccent
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
              ElevatedButton(
                onPressed: carrito.isNotEmpty ? _continuar : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
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

  Widget _buildMobileList(
    List<Map<String, dynamic>> productos,
    SaleCart carrito,
  ) {
    return ListView.builder(
      itemCount: productos.length,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      itemBuilder: (context, index) {
        return ProductCard(
          producto: productos[index],
          mapaMarcas: _mapaMarcas,
          carrito: carrito,
          isDesktop: false,
          colorTema: Theme.of(context).colorScheme.primary,
          onTap: () => _mostrarDialogoCantidad(productos[index]),
          onDeleteFromCart: () => _eliminarDelCarrito(productos[index]['id']),
        );
      },
    );
  }

  Widget _buildDesktopGrid(
    List<Map<String, dynamic>> productos,
    double screenWidth,
    SaleCart carrito,
  ) {
    int columnas = screenWidth > 1400 ? 5 : (screenWidth > 1100 ? 4 : 3);
    return GridView.builder(
      padding: const EdgeInsets.all(20),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columnas,
        childAspectRatio: 0.7,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: productos.length,
      itemBuilder: (context, index) {
        return ProductCard(
          producto: productos[index],
          mapaMarcas: _mapaMarcas,
          carrito: carrito,
          isDesktop: true,
          colorTema: Theme.of(context).colorScheme.primary,
          onTap: () => _mostrarDialogoCantidad(productos[index]),
          onDeleteFromCart: () => _eliminarDelCarrito(productos[index]['id']),
        );
      },
    );
  }
}
