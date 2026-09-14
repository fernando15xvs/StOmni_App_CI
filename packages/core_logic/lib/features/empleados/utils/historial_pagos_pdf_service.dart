import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:intl/intl.dart';
import '../../../documents/domain/generated_document.dart';
import '../../../utils/app_formatters.dart';

class HistorialPagosPdfService {
  static Future<GeneratedDocument> generar({
    required List<Map<String, dynamic>> pagos,
    required String nombreEmpleado,
    required String rangoFechas,
    required double total,
  }) async {
    final pdf = pw.Document();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        build: (pw.Context context) {
          return [
            // ENCABEZADO
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  "HISTORIAL DE PAGOS",
                  style: pw.TextStyle(
                    fontSize: 22,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.green800,
                  ),
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(
                      "Empleado: $nombreEmpleado",
                      style: const pw.TextStyle(fontSize: 12),
                    ),
                    pw.Text(
                      "Fecha: $rangoFechas",
                      style: const pw.TextStyle(
                        fontSize: 12,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 20),
            pw.Divider(color: PdfColors.grey400),
            pw.SizedBox(height: 20),

            // RESUMEN
            pw.Container(
              padding: const pw.EdgeInsets.all(15),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                borderRadius: const pw.BorderRadius.all(
                  pw.Radius.circular(10),
                ),
                border: pw.Border.all(color: PdfColors.grey300),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    "TOTAL PAGADO EN EL RANGO",
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  pw.Text(
                    AppFormatters.currency(total),
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 16,
                      color: PdfColors.green900,
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 30),

            // TABLA DE PAGOS
            if (pagos.isEmpty)
              pw.Center(
                child: pw.Text(
                  "No hay pagos registrados en este periodo.",
                  style: const pw.TextStyle(color: PdfColors.grey),
                ),
              )
            else
              pw.TableHelper.fromTextArray(
                border: pw.TableBorder.all(color: PdfColors.grey300),
                headerStyle: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.white,
                  fontSize: 10,
                ),
                headerDecoration: const pw.BoxDecoration(
                  color: PdfColors.green700,
                ),
                cellStyle: const pw.TextStyle(fontSize: 10),
                cellAlignment: pw.Alignment.centerLeft,
                headers: [
                  'Fecha',
                  'Empleado',
                  'Concepto',
                  'Método',
                  'Monto (S/)',
                ],
                data: pagos.map((p) {
                  final empNombre =
                      p['empleados']?['nombre'] ?? 'Desconocido';
                  final fechaFormateada =
                      AppFormatters.limaDateTimeLong(p['fecha']);
                  return [
                    fechaFormateada,
                    empNombre,
                    p['concepto'] ?? '',
                    p['metodo'] ?? 'Efectivo',
                    (p['monto'] as num).toStringAsFixed(2),
                  ];
                }).toList(),
              ),
          ];
        },
      ),
    );

    // GUARDADO
    final bytes = await pdf.save();
    final nombreArchivo =
        "Pagos_Personal_${DateFormat('ddMMyyyy_HHmm').format(DateTime.now())}.pdf";

    return GeneratedDocument(bytes: bytes, fileName: nombreArchivo, kind: DocumentKind.pdf);
  }
}
