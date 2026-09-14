import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

class ProductCard extends StatelessWidget {
  final Map<String, dynamic> producto;
  final Map<int, String> mapaMarcas;
  final SaleCart carrito;
  final VoidCallback onTap;
  final VoidCallback? onDeleteFromCart;
  final bool isDesktop;
  final Color colorTema;

  const ProductCard({
    super.key,
    required this.producto,
    required this.mapaMarcas,
    required this.carrito,
    required this.onTap,
    this.onDeleteFromCart,
    required this.isDesktop,
    required this.colorTema,
  });

  @override
  Widget build(BuildContext context) {
    final tipoVenta = StockUtils.getTipoVentaFromMap(producto);
    final pcs = (producto['cantidad_por_caja'] as num?)?.toInt() ?? 1;
    final pUnidad = (producto['precio_unidad'] as num?)?.toDouble() ?? 0.0;
    final pCajaBase = (producto['precio_caja'] as num?)?.toDouble() ?? 0.0;
    final codigo = producto['codigo']?.toString().trim();
    final marca =
        mapaMarcas[(producto['proveedor_id'] as num?)?.toInt()] ?? 'Genérico';

    final lineas = carrito.lines.where(
      (item) =>
          item.productId == (producto['id'] as num?)?.toInt(),
    );
    final resumen = _resumenCarrito(lineas);
    final seleccionado = lineas.isNotEmpty;

    final precios = <Widget>[];
    final snapshot = SaleCartMapper.decodeProduct(producto);
    if (snapshot.unitConfiguration != null) {
      final presentations = snapshot.commercialProfile.presentations;
      for (final presentation in presentations.take(3)) {
        precios.add(
          _precio(
            context,
            presentation.singularLabel,
            snapshot.defaultPrice(presentation.code),
            presentation.baseQuantity > 1
                ? Icons.inventory_2_outlined
                : Icons.layers_outlined,
          ),
        );
      }
      if (presentations.length > 3) {
        precios.add(
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              '+ ${presentations.length - 3} presentaciones',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        );
      }
    } else if (tipoVenta == SaleUnitType.paquete ||
        tipoVenta == SaleUnitType.caja) {
      final paquete = StockUtils.precioComercialPredeterminado(
        tipoVenta: tipoVenta,
        tipoUnidad: tipoVenta == SaleUnitType.caja ? 'caja' : 'paquete',
        precioUnidad: pUnidad,
        precioCajaBase: pCajaBase,
        pcs: pcs,
      );
      final etiquetaEmpaque = tipoVenta == SaleUnitType.caja
          ? 'Caja'
          : 'Paquete';
      precios.add(
        _precio(
          context,
          etiquetaEmpaque,
          paquete,
          tipoVenta == SaleUnitType.caja
              ? Icons.inventory_2_outlined
              : Icons.all_inbox_outlined,
        ),
      );
      if (pCajaBase > 0) {
        precios.add(
          _precio(context, 'Pieza ref.', pCajaBase, Icons.circle_outlined),
        );
      }
    } else {
      final caja = StockUtils.precioComercialPredeterminado(
        tipoVenta: tipoVenta,
        tipoUnidad: 'caja',
        precioUnidad: pUnidad,
        precioCajaBase: pCajaBase,
        pcs: pcs,
      );
      final suelta = StockUtils.precioComercialPredeterminado(
        tipoVenta: tipoVenta,
        tipoUnidad: StockUtils.tipoUnidadSuelta(tipoVenta),
        precioUnidad: pUnidad,
        precioCajaBase: pCajaBase,
        pcs: pcs,
      );
      precios.add(_precio(context, 'Caja', caja, Icons.inventory_2_outlined));
      precios.add(
        _precio(
          context,
          StockUtils.etiquetaUnidadComercial(
            StockUtils.tipoUnidadSuelta(tipoVenta),
            cantidad: 1,
          ),
          suelta,
          Icons.layers_outlined,
        ),
      );
    }

    final badges = Wrap(
      spacing: 5,
      runSpacing: 4,
      children: [
        if (codigo != null && codigo.isNotEmpty) _badge(codigo, colorTema),
        _badge(marca.toUpperCase(), Colors.blueGrey),
        _badge(
          snapshot.unitConfiguration == null
              ? StockUtils.etiquetaContenido(tipoVenta, pcs)
              : 'BASE: ${snapshot.commercialProfile.baseUnit.singularLabel.toUpperCase()}',
          Colors.amber,
        ),
        if (producto['permitir_sin_stock'] == true)
          _badge('S/ STOCK', Colors.deepOrange),
      ],
    );

    final image = _imagen(context, producto['imagen_path']);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        badges,
        const SizedBox(height: 5),
        Text(
          producto['nombre']?.toString() ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 15,
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.white
                : Colors.black87,
          ),
        ),
        const SizedBox(height: 7),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: colorTema.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: colorTema.withValues(alpha: 0.22)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: precios,
          ),
        ),
      ],
    );

    if (isDesktop) {
      return Card(
        elevation: seleccionado ? 5 : 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
          side: seleccionado
              ? BorderSide(color: colorTema, width: 2.5)
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 5,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(15),
                  ),
                  child: image,
                ),
              ),
              Expanded(
                flex: 6,
                child: Padding(
                  padding: const EdgeInsets.all(11),
                  child: Stack(
                    children: [
                      content,
                      if (seleccionado)
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: _seleccionBadge(resumen),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: seleccionado ? 4 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(15),
        side: seleccionado
            ? BorderSide(color: colorTema, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(width: 85, height: 85, child: image),
              ),
              const SizedBox(width: 14),
              Expanded(child: content),
              const SizedBox(width: 8),
              Column(
                children: [
                  if (seleccionado) _seleccionBadge(resumen),
                  const SizedBox(height: 8),
                  if (seleccionado && onDeleteFromCart != null)
                    IconButton(
                      onPressed: onDeleteFromCart,
                      icon: const Icon(Icons.delete_outline),
                      color: Colors.red,
                      tooltip: 'Quitar del carrito',
                    )
                  else
                    const Icon(Icons.add_circle_outline),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _resumenCarrito(Iterable<SaleCartLine> lineas) =>
      SaleCartSummaryFormatter.format(SaleCart(lineas));

  Widget _seleccionBadge(String texto) {
    return Container(
      constraints: const BoxConstraints(minWidth: 34),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
      decoration: BoxDecoration(
        color: colorTema,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        texto,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 10,
        ),
      ),
    );
  }

  Widget _precio(
    BuildContext context,
    String etiqueta,
    double precio,
    IconData icono,
  ) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color actualColor = isDark ? Colors.greenAccent : colorTema;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, size: 12, color: actualColor),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '$etiqueta: ${AppFormatters.currency(precio)}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: actualColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _badge(String texto, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        texto,
        style: TextStyle(
          fontSize: 8.5,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Widget _imagen(BuildContext context, dynamic url) {
    final bg = Theme.of(context).brightness == Brightness.dark
        ? Colors.black
        : Colors.grey[100];
    if (url != null && url.toString().startsWith('http')) {
      return ColoredBox(
        color: bg!,
        child: CachedNetworkImage(
          imageUrl: url.toString(),
          fit: BoxFit.cover,
          memCacheWidth: 250,
          memCacheHeight: 250,
          placeholder: (_, _) =>
              const Center(child: Icon(Icons.image_outlined)),
          errorWidget: (_, _, _) => const Icon(Icons.image_not_supported),
        ),
      );
    }
    return ColoredBox(
      color: bg!,
      child: const Icon(Icons.image_not_supported_outlined),
    );
  }
}
