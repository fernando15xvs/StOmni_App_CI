import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'package:core_logic/core_logic.dart';
import 'package:mobile_app/core/theme/app_colors.dart';
import '../presentation/controllers/almacen_controller.dart';
import '../pages/nuevo_producto_page.dart';
import '../pages/product_unit_configuration_page.dart';

class ProductoDetailSheet extends ConsumerWidget {
  final Map<String, dynamic> p;
  final bool modoInactivos;

  const ProductoDetailSheet({
    super.key,
    required this.p,
    this.modoInactivos = false,
  });

  static void show(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> p, {
    required bool modoInactivos,
  }) {
    final widget = ProductoDetailSheet(p: p, modoInactivos: modoInactivos);

    if (MediaQuery.of(context).size.width > 900) {
      showDialog(
        context: context,
        builder: (context) => Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 500),
            child: widget,
          ),
        ),
      );
    } else {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => Container(
          height: MediaQuery.of(context).size.height * 0.85,
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
          ),
          child: widget,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final int totalUnidades = p['_totalStock'] as int? ?? 0;
    final nombreMarca = p['_marcaNombre'] ?? 'Genérico';
    final int pcs = (p['cantidad_por_caja'] as num?)?.toInt() ?? 1;
    final tipoVenta = StockUtils.getTipoVentaFromMap(p);
    final productSnapshot = SaleCartMapper.decodeProduct(p);
    final unitProfile = productSnapshot.commercialProfile;
    final bool muestraContenido = StockUtils.usaContenidoInformativo(
      tipoVenta,
      pcs,
    );

    final esAdmin = ref.watch(rolProvider) == 'admin';
    final isPC = MediaQuery.of(context).size.width > 900;
    final urlImagen = p['imagen_path'];
    final tieneImagen =
        urlImagen != null && urlImagen.toString().startsWith('http');

    final precios = productSnapshot.unitConfiguration == null
        ? PriceVisualUtils.getInventoryPriceItems(p)
        : unitProfile.presentations
              .map(
                (presentation) => PriceVisualItem(
                  label: 'Precio por ${presentation.singularLabel}',
                  value: productSnapshot.defaultPrice(presentation.code),
                  destacado: presentation.code == unitProfile.baseUnit.code,
                ),
              )
              .toList(growable: false);
    final codigo = (p['codigo'] ?? '').toString().trim();
    final stockTotal = productSnapshot.unitConfiguration == null
        ? StockUtils.formatStock(totalUnidades, pcs, tipoVenta)
        : unitProfile.formatBaseQuantity(totalUnidades.toDouble());

    final colorTexto =
        Theme.of(context).textTheme.bodyLarge?.color ?? const Color(0xFF1F2937);
    final primaryTexto = Theme.of(context).brightness == Brightness.dark
        ? Colors.greenAccent
        : Theme.of(context).colorScheme.primary;
    final colorDorado = const Color(0xFFF59E0B);
    final colorNaranja = Colors.deepOrange;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isPC)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.grey[700]
                      : Colors.grey[300],
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            child: Column(
              children: [
                if (tieneImagen)
                  Hero(
                    tag: MediaQuery.of(context).size.width > 900
                        ? 'prod_pc_${p['id']}'
                        : 'prod_mobile_${p['id']}',
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: CachedNetworkImage(
                        imageUrl: urlImagen!,
                        height: 220,
                        width: double.infinity,
                        fit: BoxFit.contain,
                        memCacheWidth: 250,
                        memCacheHeight: 250,
                        placeholder: (context, url) => Center(
                          child: CircularProgressIndicator(
                            color: primaryTexto,
                            strokeWidth: 2,
                          ),
                        ),
                        errorWidget: (context, url, error) => Container(
                          height: 120,
                          width: 120,
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? Colors.grey[800]
                                : Colors.grey[50],
                            borderRadius: BorderRadius.circular(60),
                          ),
                          child: Icon(
                            Icons.image,
                            size: 50,
                            color:
                                Theme.of(context).brightness == Brightness.dark
                                ? Colors.grey[600]
                                : Colors.grey[300],
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  Container(
                    height: 120,
                    width: 120,
                    decoration: BoxDecoration(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.grey[800]
                          : Colors.grey[50],
                      borderRadius: BorderRadius.circular(60),
                    ),
                    child: Icon(
                      Icons.image,
                      size: 50,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.grey[600]
                          : Colors.grey[300],
                    ),
                  ),
                const SizedBox(height: 20),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    if (codigo.isNotEmpty)
                      _badgeLarge(
                        'CÓDIGO: ${codigo.toUpperCase()}',
                        primaryTexto,
                      ),
                    _badgeLarge(
                      nombreMarca.toUpperCase(),
                      Theme.of(context).brightness == Brightness.dark
                          ? Colors.white
                          : Colors.blueGrey,
                    ),
                    _badgeLarge(
                      productSnapshot.unitConfiguration == null
                          ? StockUtils.displayName(tipoVenta).toUpperCase()
                          : 'BASE: ${unitProfile.baseUnit.singularLabel.toUpperCase()}',
                      primaryTexto,
                    ),
                    if (muestraContenido &&
                        productSnapshot.unitConfiguration == null)
                      _badgeLarge(
                        StockUtils.descripcionContenido(pcs, tipoVenta),
                        colorDorado,
                      ),
                    if (p['permitir_sin_stock'] ?? false)
                      _badgeLarge("PERMITE VENTA SIN STOCK", colorNaranja),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  p['nombre'],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: colorTexto,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  stockTotal,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: totalUnidades > 0 ? primaryTexto : Colors.red,
                  ),
                ),
                const SizedBox(height: 30),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(20),
                    border: Theme.of(context).brightness == Brightness.dark
                        ? Border.all(
                            color: Colors.white.withValues(alpha: 0.05),
                          )
                        : Border.all(color: Colors.grey.shade100),
                    boxShadow: Theme.of(context).brightness == Brightness.dark
                        ? []
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 15,
                              offset: const Offset(0, 5),
                            ),
                          ],
                  ),
                  child: Column(
                    children: [
                      for (int i = 0; i < precios.length; i++) ...[
                        _rowPrecio(
                          precios[i].label,
                          AppFormatters.currency(precios[i].value),
                          precios[i].destacado,
                          colorTexto,
                        ),
                        if (i < precios.length - 1) const Divider(height: 15),
                      ],
                      if (precios.isNotEmpty) const Divider(height: 20),
                      _rowPrecio(
                        'Costo Referencia',
                        AppFormatters.currency(
                          ((p['precio_compra'] as num?)?.toDouble() ?? 0.0),
                        ),
                        false,
                        colorTexto,
                        isGrey: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.grey[900]
                        : Colors.grey[50],
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Ubicación de Stock",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 15),
                      ...(ref
                                  .watch(almacenNotifierProvider)
                                  .value
                                  ?.configAlmacenes ??
                              [])
                          .map((almacen) {
                            final cantUnid = AlmacenExcelService.obtenerStock(
                              p,
                              almacen['id'],
                            );
                            final textoStock =
                                productSnapshot.unitConfiguration == null
                                ? StockUtils.formatStock(
                                    cantUnid,
                                    pcs,
                                    tipoVenta,
                                  )
                                : unitProfile.formatBaseQuantity(
                                    cantUnid.toDouble(),
                                  );

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.store,
                                    size: 18,
                                    color: Colors.grey[600],
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    flex: 6,
                                    child: Text(
                                      almacen['nombre'],
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    flex: 4,
                                    child: Text(
                                      textoStock,
                                      textAlign: TextAlign.end,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                    ],
                  ),
                ),
                const SizedBox(height: 30),
                if (esAdmin && modoInactivos)
                  Row(
                    children: [
                      Expanded(
                        child: _botonGrande(
                          icon: Icons.replay,
                          label: "Reactivar Producto",
                          color: Colors.green,
                          onTap: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(15),
                                ),
                                title: const Text('¿Reactivar Producto?'),
                                content: Text(
                                  '"${p['nombre']}" volverá a estar disponible en el catálogo, ventas y cotizaciones.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('Cancelar'),
                                  ),
                                  ElevatedButton(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.primary,
                                    ),
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text(
                                      'REACTIVAR',
                                      style: TextStyle(color: Colors.white),
                                    ),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true && context.mounted) {
                              final productoId =
                                  (p['id'] as num?)?.toInt() ?? -1;
                              try {
                                await ref
                                    .read(almacenNotifierProvider.notifier)
                                    .reactivarProducto(productoId);
                                if (context.mounted) {
                                  Navigator.pop(context);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '"${p['nombre']}" reactivado correctamente.',
                                      ),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                }
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(e.toString()),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                }
                              }
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _botonGrande(
                          icon: Icons.delete_forever_outlined,
                          label: "Eliminar definitivamente",
                          color: Colors.red,
                          onTap: () =>
                              _mostrarDialogoEliminacionSegura(context, ref, p),
                        ),
                      ),
                    ],
                  )
                else if (esAdmin)
                  Row(
                    children: [
                      Expanded(
                        child: _botonGrande(
                          icon: Icons.edit_outlined,
                          label: "Editar",
                          color: Colors.orange,
                          onTap: () async {
                            final modoOffline =
                                ref
                                    .read(almacenNotifierProvider)
                                    .value
                                    ?.modoOffline ??
                                false;
                            if (modoOffline) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text("No disponible sin internet"),
                                  backgroundColor: Colors.red,
                                ),
                              );
                              return;
                            }
                            final navigator = Navigator.of(context);
                            navigator.pop();
                            FocusManager.instance.primaryFocus?.unfocus();
                            await navigator.push(
                              MaterialPageRoute(
                                builder: (_) =>
                                    NuevoProductoPage(productoEditar: p),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _botonGrande(
                          icon: Icons.visibility_off_outlined,
                          label: "Desactivar",
                          color: Colors.orange,
                          onTap: () =>
                              _mostrarDialogoDesactivar(context, ref, p),
                        ),
                      ),
                    ],
                  ),
                if (esAdmin && !modoInactivos) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: _botonGrande(
                      icon: Icons.straighten_outlined,
                      label: 'Unidades y presentaciones',
                      color: primaryTexto,
                      onTap: () async {
                        final modoOffline =
                            ref
                                .read(almacenNotifierProvider)
                                .value
                                ?.modoOffline ??
                            false;
                        if (modoOffline) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('No disponible sin internet'),
                            ),
                          );
                          return;
                        }
                        final navigator = Navigator.of(context);
                        navigator.pop();
                        await navigator.push(
                          MaterialPageRoute(
                            builder: (_) => ProductUnitConfigurationPage(
                              productId: (p['id'] as num).toInt(),
                              productName:
                                  p['nombre']?.toString() ?? 'Producto',
                              legacyProfile: productSnapshot.commercialProfile,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: _botonGrande(
                      icon: Icons.delete_forever_outlined,
                      label: "Eliminar definitivamente",
                      color: Colors.red,
                      onTap: () =>
                          _mostrarDialogoEliminacionSegura(context, ref, p),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Diálogos de confirmación — La vista es dueña de la UI, el notifier de la lógica.
  // ---------------------------------------------------------------------------

  Future<void> _mostrarDialogoDesactivar(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> producto,
  ) async {
    final int idProducto = producto['id'];
    final int stockTotal = (producto['_totalStock'] as int?) ?? 0;
    final modoOffline =
        ref.read(almacenNotifierProvider).value?.modoOffline ?? false;

    if (modoOffline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No puedes desactivar productos sin conexión.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: const Text('¿Desactivar producto?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'El producto se ocultará del catálogo, ventas y cotizaciones. Su stock y todo el historial se conservarán.',
            ),
            if (stockTotal > 0) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.orange.withValues(alpha: 0.5),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.orange,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Este producto aún tiene stock disponible ($stockTotal). No aparecerá en las ventas, pero el historial se conserva.',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.orange,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'DESACTIVAR',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirm != true || !context.mounted) return;

    try {
      await ref
          .read(almacenNotifierProvider.notifier)
          .desactivarProducto(idProducto);
      if (!context.mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Producto desactivado correctamente.'),
          backgroundColor: Colors.orange,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _mostrarDialogoEliminacionSegura(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> producto,
  ) async {
    final productoId = (producto['id'] as num?)?.toInt();
    final modoOffline =
        ref.read(almacenNotifierProvider).value?.modoOffline ?? false;

    if (productoId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El producto no tiene un identificador válido.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (modoOffline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No puedes eliminar definitivamente un producto sin conexión.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    Map<String, dynamic> evaluacion;
    try {
      evaluacion = await ref
          .read(almacenNotifierProvider.notifier)
          .evaluarEliminacionProducto(productoId);
    } catch (e) {
      if (context.mounted) Navigator.of(context).pop();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
        );
      }
      return;
    }

    if (!context.mounted) return;
    Navigator.of(context).pop();

    final puedeEliminar = evaluacion['puede_eliminar'] == true;
    final movimientosApertura =
        (evaluacion['movimientos_apertura'] as num?)?.toInt() ?? 0;
    final stockTotal = (evaluacion['stock_total'] as num?)?.toInt() ?? 0;
    final rawBloqueos = evaluacion['bloqueos'];
    final bloqueos = rawBloqueos is List
        ? rawBloqueos
              .map((item) {
                if (item is Map && item['mensaje'] != null)
                  return item['mensaje'].toString();
                return item.toString();
              })
              .where((item) => item.trim().isNotEmpty)
              .toList()
        : <String>[];

    if (puedeEliminar) {
      final confirmar = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text('Eliminar definitivamente'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '"${producto['nombre'] ?? 'Producto'}" nunca fue utilizado en una operación real.',
              ),
              const SizedBox(height: 12),
              const Text(
                'Se eliminarán el producto, su stock actual y sus movimientos de apertura. Esta acción no se puede deshacer.',
              ),
              if (movimientosApertura > 0 || stockTotal > 0) ...[
                const SizedBox(height: 12),
                Text(
                  'Movimientos de apertura: $movimientosApertura\nStock que se eliminará: $stockTotal',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'ELIMINAR DEFINITIVAMENTE',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      );

      if (confirmar != true || !context.mounted) return;

      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );

      try {
        await ref
            .read(almacenNotifierProvider.notifier)
            .eliminarProductoDefinitivamente(productoId);
        if (!context.mounted) return;
        Navigator.of(context).pop();
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Producto eliminado definitivamente.'),
            backgroundColor: Colors.green,
          ),
        );
      } catch (e) {
        if (context.mounted) Navigator.of(context).pop();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
          );
        }
      }
      return;
    }

    final desactivar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('No se puede eliminar definitivamente'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'El producto ya tiene historial operativo o relaciones con otros documentos. Para conservar la auditoría solo puede desactivarse.',
            ),
            if (bloqueos.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...bloqueos.map(
                (mensaje) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('• '),
                      Expanded(child: Text(mensaje)),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'DESACTIVAR PRODUCTO',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (desactivar != true || !context.mounted) return;

    try {
      await ref
          .read(almacenNotifierProvider.notifier)
          .desactivarProducto(productoId);
      if (!context.mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Producto desactivado correctamente.'),
          backgroundColor: Colors.orange,
        ),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString()), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _badgeLarge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Widget _rowPrecio(
    String label,
    String valor,
    bool destacado,
    Color defaultColor, {
    bool isGrey = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 14)),
        Text(
          valor,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: destacado ? 18 : 16,
            color: isGrey ? Colors.grey : defaultColor,
          ),
        ),
      ],
    );
  }

  Widget _botonGrande({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
