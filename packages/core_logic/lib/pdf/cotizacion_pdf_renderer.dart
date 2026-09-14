import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'pdf_branding.dart';
import '../utils/app_formatters.dart';
import 'pdf_asset_loader.dart';
import 'pdf_document_theme.dart';

class CotizacionPdfRenderer {
  const CotizacionPdfRenderer._();

  static Future<Uint8List> generar(
    Map<String, dynamic> documento,
    List<Map<String, dynamic>> detalles,
    Map<String, dynamic>? cliente, {
    PdfBranding? branding,
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
    final idStr =
        '001 - ${documento['id']?.toString().padLeft(6, '0') ?? '000000'}';
    final clienteNombre = cliente?['nombre']?.toString() ?? 'Cliente General';
    final clienteDoc = cliente?['dni_ruc']?.toString() ?? '---';
    final clienteDir = cliente?['direccion']?.toString() ?? '---';
    const scale = 1.3;

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.copyWith(
          marginLeft: 15 * PdfPageFormat.mm,
          marginRight: 15 * PdfPageFormat.mm,
          marginTop: 15 * PdfPageFormat.mm,
          marginBottom: 15 * PdfPageFormat.mm,
        ),
        build: (_) => [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              if (logoImage != null)
                pw.Container(
                  height: 120 * scale,
                  width: 250 * scale,
                  margin: pw.EdgeInsets.only(bottom: 5 * scale),
                  child: pw.Image(
                    logoImage,
                    fit: pw.BoxFit.contain,
                    alignment: pw.Alignment.center,
                  ),
                ),
              pw.Text(
                displayName,
                style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 12 * scale,
                ),
                textAlign: pw.TextAlign.center,
              ),
              if (legalName != displayName)
                pw.Text(
                  legalName,
                  style: pw.TextStyle(fontSize: 8 * scale),
                  textAlign: pw.TextAlign.center,
                ),
              pw.Text('RUC: $ruc', style: pw.TextStyle(fontSize: 9 * scale)),
              pw.Text(
                dir,
                style: pw.TextStyle(fontSize: 8 * scale),
                textAlign: pw.TextAlign.center,
              ),
              if (telefono.isNotEmpty)
                pw.Text(
                  'Cel: $telefono',
                  style: pw.TextStyle(fontSize: 8 * scale),
                ),
              pw.SizedBox(height: 8 * scale),
              pw.Container(
                width: double.infinity,
                padding: pw.EdgeInsets.symmetric(vertical: 5 * scale),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(
                    color: PdfDocumentTheme.indigo,
                    width: 2,
                  ),
                ),
                child: pw.Center(
                  child: pw.Text(
                    'COTIZACIÓN',
                    style: pw.TextStyle(
                      color: PdfDocumentTheme.indigo,
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 13 * scale,
                    ),
                  ),
                ),
              ),
              pw.SizedBox(height: 4 * scale),
              pw.Text(
                'N° $idStr',
                style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 11 * scale,
                  color: PdfDocumentTheme.azul,
                ),
              ),
              pw.SizedBox(height: 10 * scale),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(
                    flex: 7,
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          'Datos del Cliente',
                          style: pw.TextStyle(
                            fontSize: 9 * scale,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Divider(color: PdfDocumentTheme.grisClaro),
                        _infoLinea('Doc:', clienteDoc, scale),
                        _infoLinea('Cliente:', clienteNombre, scale),
                        _infoLinea('Dir:', clienteDir, scale),
                      ],
                    ),
                  ),
                  pw.SizedBox(width: 8 * scale),
                  pw.Expanded(
                    flex: 3,
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text(
                          'Detalles',
                          style: pw.TextStyle(
                            fontSize: 9 * scale,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.Divider(color: PdfDocumentTheme.grisClaro),
                        _infoLinea(
                          'Fecha:',
                          DateFormat('dd/MM/yyyy').format(fecha),
                          scale,
                          alinearDerecha: true,
                        ),
                        _infoLinea(
                          'Hora:',
                          DateFormat('HH:mm').format(fecha),
                          scale,
                          alinearDerecha: true,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 10 * scale),
              pw.Table(
                border: pw.TableBorder.all(
                  color: PdfColors.grey400,
                  width: 0.5,
                ),
                columnWidths: const {
                  0: pw.FlexColumnWidth(4),
                  1: pw.FlexColumnWidth(1.5),
                  2: pw.FlexColumnWidth(2.5),
                  3: pw.FlexColumnWidth(2.5),
                },
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(
                      color: PdfDocumentTheme.indigo,
                    ),
                    children: [
                      _celdaHeader(
                        'Descripción',
                        scale,
                        color: PdfColors.white,
                      ),
                      _celdaHeader('Cant.', scale, color: PdfColors.white),
                      _celdaHeader('P. Unit', scale, color: PdfColors.white),
                      _celdaHeader('Total', scale, color: PdfColors.white),
                    ],
                  ),
                  ...detalles.map(
                    (detalle) => _filaDetalle(detalle, formatoDinero, scale),
                  ),
                ],
              ),
              pw.SizedBox(height: 10 * scale),
              pw.Container(
                width: double.infinity,
                padding: pw.EdgeInsets.symmetric(vertical: 5 * scale),
                decoration: pw.BoxDecoration(
                  color: PdfDocumentTheme.verde.shade(0.1),
                  border: pw.Border.all(
                    color: PdfDocumentTheme.verde.shade(0.3),
                    width: 1,
                  ),
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.center,
                  children: [
                    _check(scale),
                    pw.Text(
                      ' Calidad Garantizada   ',
                      style: pw.TextStyle(
                        fontSize: 8 * scale,
                        color: PdfDocumentTheme.verde,
                      ),
                    ),
                    _check(scale),
                    pw.Text(
                      ' Confianza Total',
                      style: pw.TextStyle(
                        fontSize: 8 * scale,
                        color: PdfDocumentTheme.verde,
                      ),
                    ),
                  ],
                ),
              ),
              pw.SizedBox(height: 15 * scale),
              pw.Divider(
                color: PdfDocumentTheme.negro,
                borderStyle: pw.BorderStyle.dashed,
              ),
              pw.SizedBox(height: 5 * scale),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.center,
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    'TOTAL COTIZADO:  ',
                    style: pw.TextStyle(
                      fontSize: 12 * scale,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfDocumentTheme.azul,
                    ),
                  ),
                  pw.Text(
                    formatoDinero.format(total),
                    style: pw.TextStyle(
                      fontSize: 16 * scale,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfDocumentTheme.negro,
                    ),
                  ),
                ],
              ),
              pw.SizedBox(height: 5 * scale),
              pw.Divider(
                color: PdfDocumentTheme.negro,
                borderStyle: pw.BorderStyle.dashed,
              ),
              pw.SizedBox(height: 15 * scale),
              pw.Align(
                alignment: pw.Alignment.centerLeft,
                child: pw.Text(
                  'Términos y Condiciones:',
                  style: pw.TextStyle(
                    fontSize: 8 * scale,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.SizedBox(height: 2 * scale),
              pw.Align(
                alignment: pw.Alignment.centerLeft,
                child: pw.Text(
                  '  1. Cotización válida por ${documento['validez_dias'] ?? 15} días.\n'
                  '  2. Los precios están sujetos a variación sin previo aviso.\n'
                  '  3. Stock sujeto a disponibilidad.',
                  style: pw.TextStyle(fontSize: 7 * scale),
                ),
              ),
              pw.SizedBox(height: 15 * scale),
              pw.Text(
                'Gracias por su preferencia.',
                style: pw.TextStyle(
                  fontSize: 10 * scale,
                  fontStyle: pw.FontStyle.italic,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfDocumentTheme.verde,
                ),
                textAlign: pw.TextAlign.center,
              ),
              pw.SizedBox(height: 10 * scale),
            ],
          ),
        ],
      ),
    );

    return doc.save();
  }

  static pw.TableRow _filaDetalle(
    Map<String, dynamic> detalle,
    NumberFormat formatoDinero,
    double scale,
  ) {
    final producto = Map<String, dynamic>.from(
      detalle['productos'] as Map? ?? const <String, dynamic>{},
    );
    final nombre =
        detalle['producto_nombre_snapshot']?.toString() ??
        producto['nombre']?.toString() ??
        detalle['nombre_producto']?.toString() ??
        'Producto Desconocido';
    final subtipo =
        detalle['producto_subtipo_snapshot']?.toString() ??
        producto['subtipo']?.toString() ??
        '';
    final cantidad = (detalle['cantidad'] as num?)?.toDouble() ?? 1.0;
    final unitario = (detalle['precio_unitario'] as num?)?.toDouble() ?? 0.0;
    final subtotal = cantidad * unitario;

    final etiqueta = switch (subtipo) {
      'fraccion_1' => 'Unidades',
      'fraccion_2' => 'Varillas',
      'fraccion_3' => 'Metros',
      _ => '',
    };

    return pw.TableRow(
      children: [
        _celdaTexto(nombre, scale, subtipo: subtipo),
        pw.Padding(
          padding: pw.EdgeInsets.all(3 * scale),
          child: pw.Column(
            mainAxisAlignment: pw.MainAxisAlignment.center,
            children: [
              pw.Text(
                cantidad % 1 == 0
                    ? cantidad.toInt().toString()
                    : cantidad.toStringAsFixed(2),
                style: pw.TextStyle(fontSize: 8 * scale),
                textAlign: pw.TextAlign.center,
              ),
              pw.Text(
                etiqueta,
                style: pw.TextStyle(
                  fontSize: 6 * scale,
                  color: PdfColors.grey600,
                  fontStyle: pw.FontStyle.italic,
                ),
                textAlign: pw.TextAlign.center,
              ),
            ],
          ),
        ),
        pw.Padding(
          padding: pw.EdgeInsets.all(3 * scale),
          child: pw.Text(
            formatoDinero.format(unitario),
            style: pw.TextStyle(fontSize: 8 * scale),
            textAlign: pw.TextAlign.center,
          ),
        ),
        pw.Padding(
          padding: pw.EdgeInsets.all(3 * scale),
          child: pw.Text(
            formatoDinero.format(subtotal),
            style: pw.TextStyle(fontSize: 8 * scale),
            textAlign: pw.TextAlign.center,
          ),
        ),
      ],
    );
  }

  static pw.Widget _infoLinea(
    String label,
    String valor,
    double scale, {
    bool alinearDerecha = false,
  }) {
    return pw.Padding(
      padding: pw.EdgeInsets.only(bottom: 2 * scale),
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
              fontSize: 7 * scale,
              color: PdfDocumentTheme.azul,
            ),
          ),
          pw.Expanded(
            child: pw.Text(
              valor,
              style: pw.TextStyle(fontSize: 7 * scale),
              textAlign:
                  alinearDerecha ? pw.TextAlign.right : pw.TextAlign.left,
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _celdaHeader(
    String texto,
    double scale, {
    PdfColor color = PdfColors.black,
  }) {
    return pw.Padding(
      padding: pw.EdgeInsets.all(3 * scale),
      child: pw.Text(
        texto,
        style: pw.TextStyle(
          fontSize: 8 * scale,
          fontWeight: pw.FontWeight.bold,
          color: color,
        ),
        textAlign: pw.TextAlign.center,
      ),
    );
  }

  static pw.Widget _check(double scale) {
    return pw.Container(
      margin: pw.EdgeInsets.only(right: 2 * scale),
      width: 8 * scale,
      height: 8 * scale,
      decoration: const pw.BoxDecoration(
        color: PdfDocumentTheme.verde,
        shape: pw.BoxShape.circle,
      ),
      child: pw.Center(
        child: pw.Text(
          'OK',
          style: pw.TextStyle(
            color: PdfColors.white,
            fontSize: 4 * scale,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
      ),
    );
  }

  static pw.Widget _celdaTexto(
    String texto,
    double scale, {
    String subtipo = '',
  }) {
    return pw.Padding(
      padding: pw.EdgeInsets.all(3 * scale),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        mainAxisAlignment: pw.MainAxisAlignment.center,
        children: [
          pw.Text(texto, style: pw.TextStyle(fontSize: 8 * scale)),
          if ({'fraccion_1', 'fraccion_2', 'fraccion_3'}.contains(subtipo))
            pw.Text(
              'Fraccionado',
              style: pw.TextStyle(
                fontSize: 6 * scale,
                color: PdfDocumentTheme.indigo,
              ),
            ),
        ],
      ),
    );
  }
}
