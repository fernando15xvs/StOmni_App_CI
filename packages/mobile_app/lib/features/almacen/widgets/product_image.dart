import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class ProductImage extends StatelessWidget {
  final String? url;
  final double size;
  final BorderRadius? borderRadius;

  const ProductImage({
    super.key,
    required this.url,
    this.size = 50,
    this.borderRadius,
  });

  bool get _tieneImagen =>
      url != null && url!.isNotEmpty && url!.startsWith('http');

  @override
  Widget build(BuildContext context) {
    final br = borderRadius ?? BorderRadius.circular(8);
    if (_tieneImagen) {
      return ClipRRect(
        borderRadius: br,
        child: CachedNetworkImage(
          imageUrl: url!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          memCacheWidth: 250,
          memCacheHeight: 250,
          fadeInDuration: Duration.zero,
          fadeOutDuration: Duration.zero,
          errorWidget: (context, error, stackTrace) => _placeholder(context, br),
        ),
      );
    }
    return _placeholder(context, br);
  }

  Widget _placeholder(BuildContext context, BorderRadius br) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: br,
        border: Border.all(color: Theme.of(context).colorScheme.outline),
      ),
      child: Icon(
        Icons.image_not_supported_outlined,
        size: size * 0.45,
        color: Colors.grey.shade400,
      ),
    );
  }
}
