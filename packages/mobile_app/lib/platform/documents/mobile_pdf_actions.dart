import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';

import 'mobile_document_output.dart';
import 'pdf_branding_loader.dart';

class MobilePdfActions {
  const MobilePdfActions._();

  static Future<void> imprimir(
    BuildContext context,
    TipoDocumento type,
    Map<String, dynamic> document,
    List<Map<String, dynamic>> details,
    Map<String, dynamic>? customer, [
    Map<String, dynamic>? electronicDocument,
  ]) => _deliver(
    context,
    type,
    document,
    details,
    customer,
    electronicDocument: electronicDocument,
    action: DocumentOutputAction.print,
  );

  static Future<void> compartir(
    BuildContext context,
    TipoDocumento type,
    Map<String, dynamic> document,
    List<Map<String, dynamic>> details,
    Map<String, dynamic>? customer, [
    Map<String, dynamic>? electronicDocument,
  ]) => _deliver(
    context,
    type,
    document,
    details,
    customer,
    electronicDocument: electronicDocument,
    action: DocumentOutputAction.share,
  );

  static Future<void> _deliver(
    BuildContext context,
    TipoDocumento type,
    Map<String, dynamic> document,
    List<Map<String, dynamic>> details,
    Map<String, dynamic>? customer, {
    Map<String, dynamic>? electronicDocument,
    required DocumentOutputAction action,
  }) async {
    try {
      final output = documentOutputFor(context);
      final ticketSize = PreferencesService.ticketSize;
      final branding = await PdfBrandingLoader.load();
      final bytes = await PdfGeneratorService.generarPdf(
        type,
        document,
        details,
        customer,
        comprobante: electronicDocument,
        branding: branding,
        ticketSize: ticketSize,
      );
      if (!context.mounted) return;
      final prefix = type == TipoDocumento.boleta ? 'Nota_Venta' : 'Cotizacion';
      final format = type == TipoDocumento.cotizacion
          ? PdfPageFormat.a4
          : PdfDocumentTheme.ticketFormat(size: ticketSize);
      await output.deliver(
        GeneratedDocument(
          bytes: bytes,
          fileName: '${prefix}_${document['id']}.pdf',
          kind: DocumentKind.pdf,
          pageWidthPoints: format.width,
          pageHeightPoints: format.height,
        ),
        action: action,
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMapper.map(error))));
      }
    }
  }
}
