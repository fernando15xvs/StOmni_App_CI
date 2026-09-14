import 'dart:typed_data';

enum DocumentKind { pdf, xlsx }
enum DocumentOutputAction { export, print, share }
enum DocumentOutputResult { saved, shared, printed, presented, cancelled }

/// Resultado de generación: contenido y metadatos, nunca rutas ni diálogos.
class GeneratedDocument {
  GeneratedDocument({
    required List<int> bytes,
    required String fileName,
    required this.kind,
    this.pageWidthPoints,
    this.pageHeightPoints,
  }) : _bytes = Uint8List.fromList(bytes),
       fileName = _safeName(fileName, kind.name) {
    if (_bytes.isEmpty) throw ArgumentError('El documento no puede estar vacío.');
    final width = pageWidthPoints;
    final height = pageHeightPoints;
    if (width != null && (!width.isFinite || width <= 0)) {
      throw ArgumentError('El ancho de página no es válido.');
    }
    if (height != null && (height.isNaN || height <= 0)) {
      throw ArgumentError('El alto de página no es válido.');
    }
  }

  final Uint8List _bytes;
  final String fileName;
  final DocumentKind kind;
  final double? pageWidthPoints;
  final double? pageHeightPoints;
  Uint8List get bytes => Uint8List.fromList(_bytes);
  String get mimeType => kind == DocumentKind.pdf
      ? 'application/pdf'
      : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

  static String _safeName(String value, String extension) {
    var name = value.replaceAll('\\', '/').split('/').last
        .replaceAll(RegExp(r'[\x00-\x1f:*?"<>|]'), '_').trim();
    if (name.isEmpty || name == '.' || name == '..') name = 'documento';
    return name.toLowerCase().endsWith('.$extension') ? name : '$name.$extension';
  }
}

abstract interface class DocumentOutputGateway {
  Future<DocumentOutputResult> deliver(
    GeneratedDocument document, {
    DocumentOutputAction action = DocumentOutputAction.export,
  });
}
