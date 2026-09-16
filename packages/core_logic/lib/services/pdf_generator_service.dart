import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import '../features/ventas/data/quotation_sale_cart_mapper.dart';
import '../pdf/pdf_branding.dart';

import '../pdf/cotizacion_pdf_renderer.dart';
import '../pdf/pdf_document_theme.dart';
import '../pdf/venta_ticket_pdf_renderer.dart';

enum TipoDocumento { boleta, cotizacion }

/// Fachada estable de generación. La salida pertenece al cliente.
///
/// Los renderizadores no consultan fuentes de datos: reciben toda la información
/// que necesitan y se limitan a construir el documento.
class PdfGeneratorService {
  const PdfGeneratorService._();

  static const PdfColor colorVerde = PdfDocumentTheme.verde;
  static const PdfColor colorIndigo = PdfDocumentTheme.indigo;
  static const PdfColor colorAzul = PdfDocumentTheme.azul;
  static const PdfColor colorNegro = PdfDocumentTheme.negro;
  static const PdfColor colorGrisClaro = PdfDocumentTheme.grisClaro;

  static Future<Uint8List> generarPdf(
    TipoDocumento tipo,
    Map<String, dynamic> documento,
    List<Map<String, dynamic>> detalles,
    Map<String, dynamic>? cliente, {
    Map<String, dynamic>? comprobante,
    PdfBranding? branding,
    String ticketSize = '80mm',
  }) {
    return switch (tipo) {
      TipoDocumento.cotizacion => CotizacionPdfRenderer.generar(
        documento,
        QuotationSaleCartMapper.documentDetails(detalles),
        cliente,
        branding: branding,
      ),
      TipoDocumento.boleta => VentaTicketPdfRenderer.generar(
        documento,
        detalles,
        cliente,
        comprobante,
        branding: branding,
        ticketSize: ticketSize,
      ),
    };
  }
}
