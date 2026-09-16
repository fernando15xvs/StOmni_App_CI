import 'package:core_logic/core_logic.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import 'save_document_stub.dart'
    if (dart.library.io) 'save_document_io.dart'
    as files;

DocumentOutputGateway documentOutputFor(BuildContext context) {
  final box = context.findRenderObject();
  final origin = box is RenderBox && box.hasSize && !box.size.isEmpty
      ? box.localToGlobal(Offset.zero) & box.size
      : null;
  return MobileDocumentOutput(sharePositionOrigin: origin);
}

/// Adaptador del cliente: destinos, diálogo de impresión y hoja de compartir.
class MobileDocumentOutput implements DocumentOutputGateway {
  const MobileDocumentOutput({this.sharePositionOrigin});
  final Rect? sharePositionOrigin;

  @override
  Future<DocumentOutputResult> deliver(
    GeneratedDocument document, {
    DocumentOutputAction action = DocumentOutputAction.export,
  }) async {
    if (action == DocumentOutputAction.print) {
      if (document.kind != DocumentKind.pdf) {
        throw StateError('La impresión directa requiere un documento PDF.');
      }
      final format = document.pageWidthPoints == null
          ? PdfPageFormat.a4
          : PdfPageFormat(
              document.pageWidthPoints!,
              document.pageHeightPoints ?? PdfPageFormat.a4.height,
            );
      final printed = await Printing.layoutPdf(
        onLayout: (_) async => document.bytes,
        name: document.fileName,
        format: format,
      );
      return printed
          ? DocumentOutputResult.printed
          : DocumentOutputResult.cancelled;
    }
    final desktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
    if (action == DocumentOutputAction.export && desktop) {
      return files.saveDocument(document);
    }
    final result = await Share.shareXFiles(
      [
        XFile.fromData(
          document.bytes,
          mimeType: document.mimeType,
          name: document.fileName,
        ),
      ],
      fileNameOverrides: [document.fileName],
      sharePositionOrigin: sharePositionOrigin,
    );
    return switch (result.status) {
      ShareResultStatus.success => DocumentOutputResult.shared,
      ShareResultStatus.dismissed => DocumentOutputResult.cancelled,
      ShareResultStatus.unavailable => DocumentOutputResult.presented,
    };
  }
}
