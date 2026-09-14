import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pdf_branding.dart';
import '../utils/app_formatters.dart';
import '../utils/stock_utils.dart';
import 'pdf_asset_loader.dart';
import 'pdf_document_theme.dart';

class VentaTicketPdfRenderer {
  const VentaTicketPdfRenderer._();

  static Future<Uint8List> generar(
    Map<String, dynamic> documento,
    List<Map<String, dynamic>> detalles,
    Map<String, dynamic>? cliente,
    Map<String, dynamic>? comprobante, {
    PdfBranding? branding,
    String ticketSize = '80mm',
  }) async {
    final fiscalProfile = branding?.fiscalProfile;
    final ruc = fiscalProfile?.taxIdentifier.trim().isNotEmpty == true
        ? fiscalProfile!.taxIdentifier
        : '---';
    final dir = fiscalProfile?.address.street.trim().isNotEmpty == true
        ? fiscalProfile!.address.street
        : '---';
    final legalName = fiscalProfile?.legalName.trim().isNotEmpty == true
        ? fiscalProfile!.legalName
        : 'Negocio';
    final displayName = fiscalProfile?.tradeName.trim().isNotEmpty == true
        ? fiscalProfile!.tradeName
        : legalName;
    final telefono = fiscalProfile?.phone ?? '';
    final logoImage = PdfAssetLoader.fromBytes(branding?.logoBytes);

    final doc = pw.Document();
    final formatoDinero = NumberFormat.currency(locale: 'en_US', symbol: 'S/ ');
    final fecha = documento['fecha'] == null
        ? DateTime.now()
        : toLima(documento['fecha']);
    final total = (documento['total'] as num?)?.toDouble() ?? 0.0;
    var idStr =
        '001 - ${documento['id']?.toString().padLeft(6, '0') ?? '000000'}';
    var tituloDoc = 'NOTA DE VENTA';

    final rawComp = comprobante ??
        documento['comprobantes_electronicos'] ??
        documento['comprobante_electronico'];
    if (rawComp is Map) {
      final comp = Map<String, dynamic>.from(rawComp);
      final tipoComp = comp['tipo_comprobante']?.toString() ?? '';
      final serie = comp['serie']?.toString().toUpperCase() ?? '';
      final correlativo = comp['correlativo']?.toString().padLeft(6, '0') ?? '';
      if (tipoComp == '01' || serie.startsWith('F')) {
        tituloDoc = 'FACTURA ELECTRÓNICA';
        idStr = '$serie - $correlativo';
      } else if (tipoComp == '03' || serie.startsWith('B')) {
        tituloDoc = 'BOLETA DE VENTA ELECTRÓNICA';
        idStr = '$serie - $correlativo';
      }
    }

    final clienteNombre = cliente?['nombre']?.toString() ?? 'Cliente General';
    final clienteDoc = cliente?['dni_ruc']?.toString() ?? '---';
    final clienteDir = cliente?['direccion']?.toString() ?? '---';
    final selectedFormat = PdfDocumentTheme.ticketFormat(size: ticketSize);
    final formatoRollo = PdfPageFormat(
      selectedFormat.width,
      selectedFormat.height,
      marginAll: 4 * PdfPageFormat.mm,
    );

    doc.addPage(
      pw.Page(
        pageFormat: formatoRollo,
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            if (logoImage != null)
              pw.Container(
                width: 140,
                margin: const pw.EdgeInsets.only(bottom: 5),
                child: pw.Image(logoImage, fit: pw.BoxFit.contain),
              ),
            pw.Text(
              displayName,
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 12),
              textAlign: pw.TextAlign.center,
            ),
            if (legalName != displayName)
              pw.Text(
                legalName,
                style: const pw.TextStyle(fontSize: 8),
                textAlign: pw.TextAlign.center,
              ),
            pw.Text('RUC: $ruc', style: const pw.TextStyle(fontSize: 9)),
            pw.Text(
              dir,
              style: const pw.TextStyle(fontSize: 8),
              textAlign: pw.TextAlign.center,
            ),
            if (telefono.isNotEmpty)
              pw.Text('Cel: $telefono', style: const pw.TextStyle(fontSize: 8)),
            pw.SizedBox(height: 8),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.symmetric(vertical: 5),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfDocumentTheme.verde, width: 2),
              ),
              child: pw.Center(
                child: pw.Text(
                  tituloDoc,
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                    color: PdfDocumentTheme.verde,
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              'N° $idStr',
              style: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 11,
                color: PdfDocumentTheme.azul,
              ),
            ),
            pw.SizedBox(height: 10),
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Expanded(
                  flex: 6,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'Datos del Cliente',
                        style: pw.TextStyle(
                          fontSize: 9,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.Divider(color: PdfDocumentTheme.grisClaro),
                      _infoLinea('Doc:', clienteDoc),
                      _infoLinea('Cliente:', clienteNombre),
                      _infoLinea('Dir:', clienteDir),
                    ],
                  ),
                ),
                pw.SizedBox(width: 5),
                pw.Expanded(
                  flex: 4,
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text(
                        'Detalles',
                        style: pw.TextStyle(
                          fontSize: 9,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.Divider(color: PdfDocumentTheme.grisClaro),
                      _infoLinea(
                        'Fecha:',
                        DateFormat('dd/MM/yyyy').format(fecha),
                        alinearDerecha: true,
                      ),
                      _infoLinea(
                        'Hora:',
                        DateFormat('HH:mm').format(fecha),
                        alinearDerecha: true,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 10),
            pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
              columnWidths: const {
                0: pw.FlexColumnWidth(4),
                1: pw.FlexColumnWidth(1.5),
                2: pw.FlexColumnWidth(2.5),
                3: pw.FlexColumnWidth(2.5),
              },
              children: [
                pw.TableRow(
                  decoration: const pw.BoxDecoration(color: PdfColors.grey200),
                  children: [
                    _celdaHeader('Descripción'),
                    _celdaHeader('Cant\n.'),
                    _celdaHeader('P. Unit'),
                    _celdaHeader('Total'),
                  ],
                ),
                ...detalles.map(
                  (detalle) => _filaDetalle(detalle, formatoDinero),
                ),
              ],
            ),
            pw.SizedBox(height: 10),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.symmetric(vertical: 5),
              decoration: pw.BoxDecoration(
                color: PdfDocumentTheme.verde.shade(0.1),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.center,
                children: [
                  _check(),
                  pw.Text(
                    ' Calidad Garantizada   ',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                  _check(),
                  pw.Text(
                    ' Confianza Total',
                    style: const pw.TextStyle(fontSize: 8),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 15),
            pw.Divider(
              color: PdfDocumentTheme.negro,
              borderStyle: pw.BorderStyle.dashed,
            ),
            pw.SizedBox(height: 5),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.center,
              crossAxisAlignment: pw.CrossAxisAlignment.end,
              children: [
                pw.Text(
                  'TOTAL A PAGAR:  ',
                  style: pw.TextStyle(
                    fontSize: 12,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfDocumentTheme.azul,
                  ),
                ),
                pw.Text(
                  formatoDinero.format(total),
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfDocumentTheme.negro,
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 5),
            pw.Divider(
              color: PdfDocumentTheme.negro,
              borderStyle: pw.BorderStyle.dashed,
            ),
            pw.SizedBox(height: 15),
            pw.Align(
              alignment: pw.Alignment.centerLeft,
              child: pw.Text(
                'Términos y Condiciones:',
                style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
              ),
            ),
            pw.SizedBox(height: 2),
            pw.Align(
              alignment: pw.Alignment.centerLeft,
              child: pw.Text(
                '  1. No se aceptan devoluciones pasadas las 24 horas.\n'
                '  2. Conservar este comprobante para reclamos.\n'
                '  3. Precios sujetos a cambio sin previo aviso.',
                style: const pw.TextStyle(fontSize: 7),
              ),
            ),
            pw.SizedBox(height: 15),
            pw.Text(
              'Gracias por su preferencia.',
              style: pw.TextStyle(
                fontSize: 10,
                fontStyle: pw.FontStyle.italic,
                fontWeight: pw.FontWeight.bold,
                color: PdfDocumentTheme.verde,
              ),
              textAlign: pw.TextAlign.center,
            ),
            pw.SizedBox(height: 10),
          ],
        ),
      ),
    );

    return doc.save();
  }

  static pw.TableRow _filaDetalle(
    Map<String, dynamic> detalle,
    NumberFormat formatoDinero,
  ) {
    final producto = Map<String, dynamic>.from(
      detalle['productos'] as Map? ?? const <String, dynamic>{},
    );
    final nombre =
        detalle['producto_nombre_snapshot']?.toString() ??
        producto['nombre']?.toString() ??
        detalle['nombre_producto']?.toString() ??
        'Producto';
    final cantidad = (detalle['cantidad'] as num?)?.toInt() ?? 0;
    final tipoUnidad = StockUtils.normalizarTipoUnidad(
      detalle['tipo_unidad']?.toString(),
    );
    final etiqueta = StockUtils.etiquetaUnidadComercial(
      tipoUnidad,
      cantidad: cantidad,
    );
    final subtotal =
        (detalle['subtotal_final'] as num?)?.toDouble() ??
        (detalle['subtotal'] as num?)?.toDouble() ??
        0.0;
    final unitario = cantidad > 0 ? subtotal / cantidad : 0.0;
    final codigo =
        detalle['codigo_snapshot']?.toString().trim() ??
        producto['codigo']?.toString().trim();

    return pw.TableRow(
      children: [
        pw.Padding(
          padding: const pw.EdgeInsets.all(3),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (codigo != null && codigo.isNotEmpty)
                pw.Text(
                  codigo,
                  style: pw.TextStyle(fontSize: 6, color: PdfColors.grey600),
                ),
              pw.Text(nombre, style: const pw.TextStyle(fontSize: 8)),
            ],
          ),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.all(3),
          child: pw.Column(
            children: [
              pw.Text(
                '$cantidad',
                style: const pw.TextStyle(fontSize: 8),
                textAlign: pw.TextAlign.center,
              ),
              pw.Text(
                etiqueta,
                style: pw.TextStyle(
                  fontSize: 6,
                  color: PdfColors.grey600,
                  fontStyle: pw.FontStyle.italic,
                ),
                textAlign: pw.TextAlign.center,
              ),
            ],
          ),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.all(3),
          child: pw.Text(
            formatoDinero.format(unitario),
            style: const pw.TextStyle(fontSize: 8),
            textAlign: pw.TextAlign.center,
          ),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.all(3),
          child: pw.Text(
            formatoDinero.format(subtotal),
            style: const pw.TextStyle(fontSize: 8),
            textAlign: pw.TextAlign.center,
          ),
        ),
      ],
    );
  }

  static pw.Widget _infoLinea(
    String label,
    String valor, {
    bool alinearDerecha = false,
  }) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 2),
      child: pw.Row(
        mainAxisAlignment: alinearDerecha
            ? pw.MainAxisAlignment.end
            : pw.MainAxisAlignment.start,
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            '$label ',
            style: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              fontSize: 7,
              color: PdfDocumentTheme.azul,
            ),
          ),
          pw.Expanded(
            child: pw.Text(
              valor,
              style: const pw.TextStyle(fontSize: 7),
              textAlign:
                  alinearDerecha ? pw.TextAlign.right : pw.TextAlign.left,
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _celdaHeader(String texto) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(3),
      child: pw.Text(
        texto,
        style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
        textAlign: pw.TextAlign.center,
      ),
    );
  }

  static pw.Widget _check() {
    return pw.Container(
      margin: const pw.EdgeInsets.only(right: 2),
      width: 8,
      height: 8,
      decoration: const pw.BoxDecoration(
        color: PdfDocumentTheme.verde,
        shape: pw.BoxShape.circle,
      ),
      child: pw.Center(
        child: pw.Text(
          'v',
          style: const pw.TextStyle(color: PdfColors.white, fontSize: 5),
        ),
      ),
    );
  }
}
