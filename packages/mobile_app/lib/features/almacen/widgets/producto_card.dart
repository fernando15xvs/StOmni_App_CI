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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = (p['nombre'] ?? 'Producto sin nombre').toString();
    final code = (p['codigo'] ?? '').toString().trim();
    final brand = (p['_marcaNombre'] ?? '').toString().trim();
    final image = p['imagen_path']?.toString() ?? '';
    final hasImage =
        image.startsWith('https://') || image.startsWith('http://');
    final total = (p['_totalStock'] as num?)?.toInt() ?? 0;
    final perBox = (p['cantidad_por_caja'] as num?)?.toInt() ?? 1;
    final kind = StockUtils.getTipoVentaFromMap(p);
    final stock = StockUtils.formatStock(total, perBox, kind);
    final minimum = (p['stock_minimo'] as num?)?.toInt() ?? 0;
    final low = total > 0 && total <= minimum;
    final out = total <= 0;
    final statusColor = out
        ? const Color(0xFFE35959)
        : low
        ? const Color(0xFFC28B23)
        : scheme.primary;
    Widget placeholder() => Icon(
      Icons.inventory_2_outlined,
      size: 29,
      color: scheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: theme.cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(17),
          side: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.65),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onTap(p),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 76,
                  height: 76,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: hasImage
                      ? CachedNetworkImage(
                          imageUrl: image,
                          fit: BoxFit.cover,
                          memCacheWidth: 228,
                          memCacheHeight: 228,
                          fadeInDuration: Duration.zero,
                          placeholder: (context, url) =>
                              Center(child: placeholder()),
                          errorWidget: (context, url, error) =>
                              Center(child: placeholder()),
                        )
                      : Center(child: placeholder()),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (code.isNotEmpty)
                        Text(
                          code.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            letterSpacing: 0.4,
                          ),
                        ),
                      const SizedBox(height: 3),
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                      if (brand.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          brand,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 7),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.inventory_2_outlined,
                            size: 14,
                            color: statusColor,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              stock,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: statusColor,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (low || out) ...[
                            const SizedBox(width: 6),
                            Icon(
                              Icons.warning_amber_rounded,
                              size: 14,
                              color: statusColor,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right_rounded,
                  color: scheme.onSurfaceVariant,
                  size: 20,
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
        ? Theme.of(context).colorScheme.primary
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
