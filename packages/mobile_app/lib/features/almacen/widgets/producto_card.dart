import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:core_logic/core_logic.dart';

Widget _badge(String text, Color color) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color.withValues(alpha: 0.2)),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color),
    ),
  );
}

class ProductoCardMobile extends StatelessWidget {
  final Map<String, dynamic> p;
  final Function(Map<String, dynamic>) onTap;

  const ProductoCardMobile({super.key, required this.p, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final int totalUnidades = p['_totalStock'] as int? ?? 0;
    final urlImagen = p['imagen_path'];
    final tieneImagen =
        urlImagen != null && urlImagen.toString().startsWith('http');
    final nombreMarca = p['_marcaNombre'] ?? 'Genérico';
    final int pcs = (p['cantidad_por_caja'] as num?)?.toInt() ?? 1;
    final tipoVenta = StockUtils.getTipoVentaFromMap(p);
    final bool muestraContenido = StockUtils.usaContenidoInformativo(
      tipoVenta,
      pcs,
    );
    final stockMostrado = StockUtils.formatStock(totalUnidades, pcs, tipoVenta);
    final threshold = (p['stock_minimo'] as num?)?.toInt() ?? 0;
    final bool stockBajo = totalUnidades <= threshold && totalUnidades > 0;

    final Color colorDorado = const Color(0xFFF59E0B);
    final Color colorNaranja = Colors.deepOrange;
    final Color colorTexto =
        Theme.of(context).textTheme.bodyLarge?.color ?? Colors.black;

    final primaryTexto = Theme.of(context).brightness == Brightness.dark
        ? Colors.greenAccent
        : Theme.of(context).colorScheme.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: stockBajo ? Border.all(color: Colors.orange, width: 1.5) : null,
        boxShadow: Theme.of(context).brightness == Brightness.dark
            ? []
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => onTap(p),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.black
                        : Colors.grey[50],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.grey[900]!
                          : Colors.grey.shade200,
                    ),
                  ),
                  child: tieneImagen
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: CachedNetworkImage(
                            imageUrl: urlImagen!,
                            fit: BoxFit.cover,
                            memCacheWidth: 250,
                            memCacheHeight: 250,
                            fadeInDuration: Duration.zero,
                            fadeOutDuration: Duration.zero,
                            errorWidget: (context, url, error) => Icon(
                              Icons.image_not_supported_outlined,
                              color: Colors.grey[300],
                              size: 35,
                            ),
                          ),
                        )
                      : Icon(
                          Icons.image_not_supported_outlined,
                          color: Colors.grey[300],
                          size: 35,
                        ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if ((p['codigo'] ?? '').toString().trim().isNotEmpty)
                            _badge(
                              p['codigo'].toString().trim().toUpperCase(),
                              primaryTexto,
                            ),
                          _badge(
                            nombreMarca.toUpperCase(),
                            Theme.of(context).brightness == Brightness.dark
                                ? Colors.white
                                : Colors.blueGrey,
                          ),
                          if (muestraContenido)
                            _badge(
                              StockUtils.descripcionContenidoCorta(
                                pcs,
                                tipoVenta,
                              ),
                              colorDorado,
                            ),
                          if (p['permitir_sin_stock'] ?? false)
                            _badge("VENTA S/ STOCK", colorNaranja),
                          if (stockBajo) _badge("STOCK BAJO", Colors.orange),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        p['nombre'],
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: colorTexto,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: totalUnidades > 0
                              ? primaryTexto.withValues(alpha: 0.1)
                              : Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              totalUnidades > 0
                                  ? Icons.inventory_2
                                  : Icons.warning_rounded,
                              size: 16,
                              color: totalUnidades > 0
                                  ? primaryTexto
                                  : Colors.red,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              stockMostrado,
                              style: TextStyle(
                                color: totalUnidades > 0
                                    ? primaryTexto
                                    : Colors.red,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ProductoCardDesktop extends StatelessWidget {
  final Map<String, dynamic> p;
  final Function(Map<String, dynamic>) onTap;

  const ProductoCardDesktop({super.key, required this.p, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final int totalUnidades = p['_totalStock'] as int? ?? 0;
    final urlImagen = p['imagen_path'];
    final tieneImagen =
        urlImagen != null && urlImagen.toString().startsWith('http');
    final nombreMarca = p['_marcaNombre'] ?? 'Genérico';
    final int pcs = (p['cantidad_por_caja'] as num?)?.toInt() ?? 1;
    final tipoVenta = StockUtils.getTipoVentaFromMap(p);
    final bool muestraContenido = StockUtils.usaContenidoInformativo(
      tipoVenta,
      pcs,
    );
    final stockMostrado = StockUtils.formatStock(totalUnidades, pcs, tipoVenta);
    final threshold = (p['stock_minimo'] as num?)?.toInt() ?? 0;
    final bool stockBajo = totalUnidades <= threshold && totalUnidades > 0;

    final Color colorDorado = const Color(0xFFF59E0B);
    final Color colorNaranja = Colors.deepOrange;
    final Color colorTexto =
        Theme.of(context).textTheme.bodyLarge?.color ?? Colors.black;

    final primaryTexto = Theme.of(context).brightness == Brightness.dark
        ? Colors.greenAccent
        : Theme.of(context).colorScheme.primary;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(16),
        border: stockBajo ? Border.all(color: Colors.orange, width: 1.5) : null,
        boxShadow: Theme.of(context).brightness == Brightness.dark
            ? []
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => onTap(p),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 5,
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.black
                        : Colors.grey[50],
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(16),
                    ),
                  ),
                  child: tieneImagen
                      ? ClipRRect(
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(16),
                          ),
                          child: CachedNetworkImage(
                            imageUrl: urlImagen!,
                            fit: BoxFit.cover,
                            memCacheWidth: 250,
                            memCacheHeight: 250,
                            placeholder: (context, url) => const Center(
                              child: CircularProgressIndicator(
                                color: Color(0xFF0F9D58),
                                strokeWidth: 2,
                              ),
                            ),
                            errorWidget: (context, url, error) => Icon(
                              Icons.image,
                              size: 50,
                              color: Colors.grey[300],
                            ),
                          ),
                        )
                      : Icon(Icons.image, size: 50, color: Colors.grey[300]),
                ),
              ),
              Expanded(
                flex: 4,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              if ((p['codigo'] ?? '')
                                  .toString()
                                  .trim()
                                  .isNotEmpty)
                                _badge(
                                  p['codigo'].toString().trim().toUpperCase(),
                                  primaryTexto,
                                ),
                              _badge(
                                nombreMarca.toUpperCase(),
                                Theme.of(context).brightness == Brightness.dark
                                    ? Colors.white
                                    : Colors.blueGrey,
                              ),
                              if (muestraContenido)
                                _badge(
                                  StockUtils.descripcionContenidoCorta(
                                    pcs,
                                    tipoVenta,
                                  ),
                                  colorDorado,
                                ),
                              if (p['permitir_sin_stock'] ?? false)
                                _badge("VENTA S/ STOCK", colorNaranja),
                              if (stockBajo)
                                _badge("STOCK BAJO", Colors.orange),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            p['nombre'],
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: colorTexto,
                            ),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: totalUnidades > 0
                              ? primaryTexto.withValues(alpha: 0.1)
                              : Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              totalUnidades > 0
                                  ? Icons.inventory_2
                                  : Icons.warning_rounded,
                              size: 14,
                              color: totalUnidades > 0
                                  ? primaryTexto
                                  : Colors.red,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              stockMostrado,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: totalUnidades > 0
                                    ? primaryTexto
                                    : Colors.red,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
