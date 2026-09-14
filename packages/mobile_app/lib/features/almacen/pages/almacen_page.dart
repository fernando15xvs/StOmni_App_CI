import 'package:mobile_app/platform/documents/mobile_document_output.dart';
import 'package:mobile_app/platform/connectivity/connectivity_status_service.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../widgets/buscador_inventario.dart';
import 'package:core_logic/core_logic.dart';

import 'nuevo_producto_page.dart';
import 'ingreso_mercaderia_page.dart';

import '../presentation/controllers/almacen_controller.dart';
import 'package:mobile_app/home/home_notifier.dart';
import 'package:mobile_app/core/theme/app_colors.dart';
import '../../../core/utils/navigation_utils.dart';

import '../widgets/producto_card.dart';
import '../widgets/producto_detail_sheet.dart';

class AlmacenPage extends ConsumerStatefulWidget {
  final bool soloStockBajo;
  final bool modoInactivos;

  const AlmacenPage({
    super.key,
    this.soloStockBajo = false,
    this.modoInactivos = false,
  });

  @override
  ConsumerState<AlmacenPage> createState() => _AlmacenPageState();
}

class _AlmacenPageState extends ConsumerState<AlmacenPage> with TickerProviderStateMixin {
  final Color colorDorado = const Color(0xFFF59E0B);
  final Color colorNaranja = Colors.deepOrange;
  Color get colorTexto =>
      Theme.of(context).textTheme.bodyLarge?.color ?? const Color(0xFF1F2937);
  Color get primaryTexto => Theme.of(context).brightness == Brightness.dark
      ? Colors.greenAccent
      : Theme.of(context).colorScheme.primary;
  final Color colorGrisSuave = const Color(0xFFF3F4F6);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(almacenBusquedaProvider.notifier).state = '';
      if (widget.modoInactivos && ref.read(rolProvider) != 'admin') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Solo el administrador puede ver productos inactivos.',
            ),
            backgroundColor: Colors.red,
          ),
        );
        Navigator.of(context).maybePop();
      }
    });
    homeRefreshNotifier.addListener(_onRefresh);
  }

  void _onRefresh() {
    if (mounted) ref.read(almacenNotifierProvider.notifier).recargar();
  }

  @override
  void dispose() {
    homeRefreshNotifier.removeListener(_onRefresh);
    super.dispose();
  }

  void _cambiarOrdenamiento(String campo) {
    final actual = ref.read(almacenOrdenarPorProvider);
    if (actual == campo) {
      ref
          .read(almacenOrdenAscendenteProvider.notifier)
          .update((state) => !state);
    } else {
      ref.read(almacenOrdenarPorProvider.notifier).state = campo;
      ref.read(almacenOrdenAscendenteProvider.notifier).state = true;
    }
  }

  Future<void> _descargarInventario() async {
    final stateValue = ref.read(almacenNotifierProvider).value;
    if (stateValue == null) return;

    final configAlmacenes = stateValue.configAlmacenes;
    final productosCompletos = stateValue.productosCompletos;
    final mapaMarcas = stateValue.mapaMarcas;

    if (configAlmacenes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay almacenes configurados para exportar.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    if (productosCompletos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay productos para exportar'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) =>
          const Center(child: CircularProgressIndicator(color: Colors.white)),
    );

    try {
      final document = await AlmacenExcelService.generar(
        configalmacenes: configAlmacenes,
        productosCompletos: productosCompletos,
        mapaMarcas: mapaMarcas,
      );
      if (!mounted) return;
      final resultado = await documentOutputFor(context).deliver(document);
      if (!mounted) return;
      Navigator.pop(context);

      if (resultado == DocumentOutputResult.saved) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Inventario guardado correctamente en tu PC."),
            backgroundColor: Colors.green,
          ),
        );
      } else if (resultado == DocumentOutputResult.cancelled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Exportación cancelada'),
            backgroundColor: Colors.grey,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(e)),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _exportarStockBajoPdf() async {
    final stateValue = ref.read(almacenNotifierProvider).value;
    if (stateValue == null) return;

    final asyncList = widget.modoInactivos
        ? ref.read(productosInactivosFiltradoProvider)
        : ref.read(almacenFiltradoProvider(widget.soloStockBajo));

    final productosList = asyncList.value ?? [];
    if (productosList.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay productos en alerta para exportar'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final configAlmacenes = stateValue.configAlmacenes;
    final mapaMarcas = stateValue.mapaMarcas;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) =>
          const Center(child: CircularProgressIndicator(color: Colors.white)),
    );

    try {
      final document = await StockAlertPdfService.generar(
        productos: productosList,
        almacenes: configAlmacenes,
        mapaMarcas: mapaMarcas,
      );
      if (!mounted) return;
      await documentOutputFor(context).deliver(document, action: DocumentOutputAction.print);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(e)),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final esAdmin = ref.watch(rolProvider) == 'admin';
    final primaryColor = Theme.of(context).brightness == Brightness.dark
        ? Colors.greenAccent
        : AppColors.primary;

    final asyncList = widget.modoInactivos
        ? ref.watch(productosInactivosFiltradoProvider)
        : ref.watch(almacenFiltradoProvider(widget.soloStockBajo));
    final ordenarPor = ref.watch(almacenOrdenarPorProvider);
    final ordenAscendente = ref.watch(almacenOrdenAscendenteProvider);

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: Row(
          children: [
            Expanded(
              child: Text(
                widget.modoInactivos
                    ? 'Productos Inactivos'
                    : widget.soloStockBajo
                    ? 'Alerta de Stock'
                    : 'Inventario',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if ((ref.watch(
                  almacenNotifierProvider.select((v) => v.value?.modoOffline),
                ) ??
                false)) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
        backgroundColor: Colors.transparent,
        elevation: 0,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: widget.soloStockBajo
                  ? [Colors.deepOrange.shade800, Colors.orange]
                  : [Colors.black, AppColors.primary],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(35),
            ),
          ),
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(35)),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(80),
          child: BuscadorInventario(
            colorTema: widget.soloStockBajo
                ? Colors.orange
                : (widget.modoInactivos ? Colors.grey : primaryColor),
            productosCompletos: widget.modoInactivos
                ? (ref.watch(
                        productosInactivosFutureProvider.select((v) => v.value),
                      ) ??
                      [])
                : (ref.watch(
                        almacenNotifierProvider.select(
                          (v) => v.value?.productosCompletos,
                        ),
                      ) ??
                      []),
            soloStockBajo: widget.soloStockBajo,
            onResultados: (resultados, query) {
              ref.read(almacenBusquedaProvider.notifier).state = query;
            },
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (MediaQuery.of(context).size.width > 800) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: ElevatedButton.icon(
                onPressed: () async {
                  FocusManager.instance.primaryFocus?.unfocus();
                  final online = await ConnectivityStatusService.hasInternet();
                  if (!context.mounted) return;
                  if (!online) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Requiere conexión a Internet'),
                        backgroundColor: Colors.red,
                      ),
                    );
                    return;
                  }
                  await AppNavigator.navegarA(
                    context,
                    const IngresoMercaderiaPage(),
                  );
                  _onRefresh();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  elevation: 2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                icon: const Icon(Icons.move_to_inbox, size: 18),
                label: const Text(
                  'INGRESO PROD.',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                ),
              ),
            ),
            const SizedBox(width: 10),
            if (esAdmin)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: ElevatedButton.icon(
                  onPressed: () async {
                    FocusManager.instance.primaryFocus?.unfocus();
                    final online = await ConnectivityStatusService.hasInternet();
                    if (!context.mounted) return;
                    if (!online) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Requiere conexión a Internet'),
                          backgroundColor: Colors.red,
                        ),
                      );
                      return;
                    }
                    await AppNavigator.navegarA(
                      context,
                      const NuevoProductoPage(),
                    );
                    _onRefresh();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    foregroundColor: Colors.white,
                    elevation: 2,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text(
                    'REGISTRO PROD.',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                  ),
                ),
              ),
            const SizedBox(width: 15),
          ],
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort_rounded),
            offset: const Offset(0, 40),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            elevation: 4,
            onSelected: (value) {
              if (value == 'asc_desc') {
                _cambiarOrdenamiento(ordenarPor);
              } else {
                _cambiarOrdenamiento(value);
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                enabled: false,
                height: 32,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'DIRECCIÓN',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ),
              PopupMenuItem<String>(
                value: 'asc_desc',
                child: Row(
                  children: [
                    Icon(
                      ordenAscendente
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      size: 20,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      ordenAscendente ? 'Ascendente' : 'Descendente',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Colors.black87,
                      ),
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(thickness: 1, height: 1),
              const PopupMenuItem(
                enabled: false,
                height: 32,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'ORDENAR POR',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ),
              PopupMenuItem<String>(
                value: 'nombre',
                child: Row(
                  children: [
                    Icon(
                      Icons.sort_by_alpha_rounded,
                      size: 20,
                      color: ordenarPor == 'nombre'
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey.shade500,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Nombre',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: ordenarPor == 'nombre'
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: ordenarPor == 'nombre'
                              ? Theme.of(context).colorScheme.primary
                              : Colors.black87,
                        ),
                      ),
                    ),
                    if (ordenarPor == 'nombre')
                      Icon(
                        Icons.check_circle_rounded,
                        color: Theme.of(context).colorScheme.primary,
                        size: 18,
                      ),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'precio',
                child: Row(
                  children: [
                    Icon(
                      Icons.attach_money_rounded,
                      size: 20,
                      color: ordenarPor == 'precio'
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey.shade500,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Precio',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: ordenarPor == 'precio'
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: ordenarPor == 'precio'
                              ? Theme.of(context).colorScheme.primary
                              : Colors.black87,
                        ),
                      ),
                    ),
                    if (ordenarPor == 'precio')
                      Icon(
                        Icons.check_circle_rounded,
                        color: Theme.of(context).colorScheme.primary,
                        size: 18,
                      ),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'stock',
                child: Row(
                  children: [
                    Icon(
                      Icons.inventory_2_rounded,
                      size: 20,
                      color: ordenarPor == 'stock'
                          ? AppColors.primary
                          : Colors.grey.shade500,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Stock',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: ordenarPor == 'stock'
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: ordenarPor == 'stock'
                              ? AppColors.primary
                              : Colors.black87,
                        ),
                      ),
                    ),
                    if (ordenarPor == 'stock')
                      Icon(
                        Icons.check_circle_rounded,
                        color: AppColors.primary,
                        size: 18,
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (esAdmin && !widget.modoInactivos && !widget.soloStockBajo)
            IconButton(
              icon: const Icon(Icons.visibility_off_outlined),
              tooltip: "Productos desactivados",
              onPressed: () {
                AppNavigator.navegarA(
                  context,
                  const AlmacenPage(modoInactivos: true),
                );
              },
            ),
          if (!widget.modoInactivos && !widget.soloStockBajo)
            IconButton(
              icon: const Icon(Icons.download),
              tooltip: "Descargar Inventario a Excel",
              onPressed: _descargarInventario,
            ),
          if (widget.soloStockBajo)
            IconButton(
              icon: const Icon(Icons.picture_as_pdf),
              tooltip: "Exportar Alerta a PDF",
              onPressed: _exportarStockBajoPdf,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                if (widget.modoInactivos) {
                  ref.invalidate(productosInactivosFutureProvider);
                } else {
                  try {
                    await ref
                        .read(almacenNotifierProvider.notifier)
                        .forzarActualizacionOnline();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Inventario actualizado'),
                          duration: Duration(milliseconds: 800),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(e.toString()),
                          backgroundColor: Colors.red.shade800,
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    }
                  }
                }
              },
              color: Theme.of(context).colorScheme.primary,
              child:
                  (!widget.modoInactivos &&
                      ref.watch(
                        almacenNotifierProvider.select((v) => v.isLoading),
                      ) &&
                      (ref.watch(
                                almacenNotifierProvider.select(
                                  (v) => v.value?.productosCompletos,
                                ),
                              ) ??
                              [])
                          .isEmpty)
                  ? const Center(child: CircularProgressIndicator())
                  : Builder(
                      builder: (context) {
                        return asyncList.when(
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (err, stack) => _buildLoadError(err),
                          data: (visuales) => _renderLista(visuales),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadError(Object error) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(28),
      children: [
        const SizedBox(height: 120),
        const Icon(Icons.cloud_off_outlined, size: 52),
        const SizedBox(height: 16),
        Text(
          ErrorMapper.map(error),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Center(
          child: FilledButton.icon(
            onPressed: () {
              if (widget.modoInactivos) {
                ref.invalidate(productosInactivosFutureProvider);
              } else {
                ref.read(almacenNotifierProvider.notifier).recargar();
              }
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Reintentar'),
          ),
        ),
      ],
    );
  }

  Widget _renderLista(List<Map<String, dynamic>> visuales) {
    if (visuales.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inventory_2_outlined, size: 60, color: Colors.grey[300]),
            const SizedBox(height: 10),
            Text(
              "No se encontraron productos",
              style: TextStyle(color: Colors.grey[500]),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 180),
      itemCount: visuales.length,
      itemBuilder: (context, index) {
        final p = visuales[index];
        return ProductoCardMobile(p: p, onTap: _mostrarDetalle);
      },
    );
  }

  void _mostrarDetalle(Map<String, dynamic> p) {
    ProductoDetailSheet.show(
      context,
      ref,
      p,
      modoInactivos: widget.modoInactivos,
    );
  }
}
