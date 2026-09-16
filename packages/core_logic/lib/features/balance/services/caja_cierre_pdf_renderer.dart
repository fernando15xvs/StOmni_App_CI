import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../pdf/pdf_branding.dart';
import '../../../pdf/pdf_document_theme.dart';
import '../../../utils/app_formatters.dart';

class CajaCierrePdfRenderer {
  const CajaCierrePdfRenderer._();

  static Future<Uint8List> generar(
    Map<String, dynamic> cajaInfo,
    List<Map<String, dynamic>> movimientos, {
    PdfBranding? branding,
    String ticketSize = '80mm',
  }) async {
    final fiscalProfile = branding?.fiscalProfile;
    final razonSocial = fiscalProfile?.legalName.trim().isNotEmpty == true
        ? fiscalProfile!.legalName
        : 'Negocio';
    final doc = pw.Document();
    final formatoDinero = NumberFormat.currency(locale: 'en_US', symbol: 'S/ ');
    final fechaApertura = toLima(cajaInfo['fecha_apertura']);
    final fechaCierre = toLima(cajaInfo['fecha_cierre']);
    final apertura = (cajaInfo['monto_apertura'] as num).toDouble();
    final esperado = (cajaInfo['monto_cierre_esperado'] as num).toDouble();
    final real = (cajaInfo['monto_cierre_real'] as num).toDouble();
    final diferencia = real - esperado;
    final obs = cajaInfo['observaciones']?.toString() ?? '';

    final format = PdfDocumentTheme.ticketFormat(size: ticketSize);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          format.width,
          format.height,
          marginAll: 5 * PdfPageFormat.mm,
        ),
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text(
              razonSocial,
              style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 5),
            pw.Text(
              'TICKET DE CIERRE DE CAJA',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
            pw.Divider(thickness: 1),
            pw.SizedBox(height: 5),
            _linea(
              'Apertura:',
              DateFormat('dd/MM/yyyy HH:mm').format(fechaApertura),
            ),
            _linea(
              'Cierre:',
              DateFormat('dd/MM/yyyy HH:mm').format(fechaCierre),
            ),
            pw.Divider(thickness: 1, borderStyle: pw.BorderStyle.dashed),
            pw.SizedBox(height: 5),
            _monto('Monto Inicial:', formatoDinero.format(apertura)),
            _monto('Saldo Esperado:', formatoDinero.format(esperado)),
            _monto('Saldo Real en Gaveta:', formatoDinero.format(real)),
            pw.SizedBox(height: 10),
            pw.Container(
              padding: const pw.EdgeInsets.all(5),
              decoration: pw.BoxDecoration(border: pw.Border.all()),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    diferencia == 0
                        ? 'CUADRE PERFECTO'
                        : (diferencia > 0 ? 'SOBRANTE' : 'FALTANTE'),
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                  pw.Text(
                    formatoDinero.format(diferencia.abs()),
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                ],
              ),
            ),
            if (obs.isNotEmpty) ...[
              pw.SizedBox(height: 10),
              pw.Align(
                alignment: pw.Alignment.centerLeft,
                child: pw.Text(
                  'Observaciones:',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                ),
              ),
              pw.Align(alignment: pw.Alignment.centerLeft, child: pw.Text(obs)),
            ],
            if (movimientos.isNotEmpty) ...[
              pw.SizedBox(height: 15),
              pw.Divider(thickness: 1, borderStyle: pw.BorderStyle.dashed),
              pw.Text(
                'DETALLE DE MOVIMIENTOS',
                style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              pw.SizedBox(height: 5),
              _resumenMovimientos(movimientos, formatoDinero),
              pw.SizedBox(height: 5),
              ...movimientos.map(
                (movimiento) => _movimiento(movimiento, formatoDinero),
              ),
            ],
            pw.SizedBox(height: 20),
            pw.Text(
              '--- FIN DEL REPORTE ---',
              style: const pw.TextStyle(fontSize: 10),
            ),
            pw.SizedBox(height: 10),
          ],
        ),
      ),
    );

    return doc.save();
  }

  static pw.Widget _linea(String label, String valor) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [pw.Text(label), pw.Text(valor)],
    );
  }

  static pw.Widget _monto(String label, String valor) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(label, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        pw.Text(valor),
      ],
    );
  }

  static pw.Widget _resumenMovimientos(
    List<Map<String, dynamic>> movimientos,
    NumberFormat formatoDinero,
  ) {
    double ingresos = 0;
    double egresos = 0;
    for (final movimiento in movimientos) {
      final monto = (movimiento['monto'] as num).toDouble();
      if (movimiento['tipo'] == 'ingreso') {
        ingresos += monto;
      } else {
        egresos += monto;
      }
    }
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          'Ingresos: ${formatoDinero.format(ingresos)}',
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10),
        ),
        pw.Text(
          'Egresos: ${formatoDinero.format(egresos)}',
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 10),
        ),
      ],
    );
  }

  static pw.Widget _movimiento(
    Map<String, dynamic> movimiento,
    NumberFormat formatoDinero,
  ) {
    final esIngreso = movimiento['tipo'] == 'ingreso';
    final fecha = toLima(movimiento['fecha']);
    final descripcion =
        movimiento['descripcion']?.toString() ??
        (esIngreso ? 'Ingreso Efectivo' : 'Egreso Efectivo');
    final monto = (movimiento['monto'] as num).toDouble();

    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 4),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(descripcion, style: const pw.TextStyle(fontSize: 10)),
                pw.Text(
                  DateFormat('HH:mm').format(fecha),
                  style: pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
                ),
              ],
            ),
          ),
          pw.Text(
            '${esIngreso ? '+' : '-'} ${formatoDinero.format(monto)}',
            style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
