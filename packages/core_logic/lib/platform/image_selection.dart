import 'dart:typed_data';

enum ImageSelectionSource { camera, gallery }

class ImageSelectionRequest {
  const ImageSelectionRequest({
    required this.source,
    this.maxWidth,
    this.maxHeight,
    this.imageQuality = 85,
    this.crop = false,
    this.cropQuality = 85,
  });

  final ImageSelectionSource source;
  final double? maxWidth;
  final double? maxHeight;
  final int imageQuality;
  final bool crop;
  final int cropQuality;
}

class SelectedImageData {
  const SelectedImageData({
    required this.bytes,
    required this.extension,
    this.fileName,
  });

  final Uint8List bytes;
  final String extension;
  final String? fileName;
}

abstract interface class ImageSelectionPort {
  Future<SelectedImageData?> select(ImageSelectionRequest request);
}

/// Fachada neutral de plataforma. Mobile y desktop pueden registrar
/// implementaciones distintas sin llevar plugins concretos a las páginas.
class ImageSelectionService {
  const ImageSelectionService._();

  static ImageSelectionPort? _port;

  static void configure(ImageSelectionPort port) {
    _port = port;
  }

  static ImageSelectionPort get _api {
    final port = _port;
    if (port == null) {
      throw StateError(
        'ImageSelectionService no fue configurado en el composition root.',
      );
    }
    return port;
  }

  static Future<SelectedImageData?> select(ImageSelectionRequest request) {
    return _api.select(request);
  }
}
