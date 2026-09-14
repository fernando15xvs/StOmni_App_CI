import 'dart:typed_data';
import 'package:pdf/widgets.dart' as pw;

/// Convierte bytes suministrados por el cliente; no conoce logos ni assets.
class PdfAssetLoader {
  const PdfAssetLoader._();

  static pw.ImageProvider? fromBytes(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    try {
      return pw.MemoryImage(bytes);
    } catch (_) {
      return null;
    }
  }
}
