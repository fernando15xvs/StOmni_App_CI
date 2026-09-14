import '../../../documents/domain/generated_document.dart';
import '../../../utils/app_formatters.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:intl/intl.dart';

class DetallePdfService {

  static Future<GeneratedDocument> generar({
    required DateTime fechaInicio,
    required DateTime fechaFin,
    required double totalIngresos,
    required double totalEgresos,
    required double totalDescuentos,
    required Map<String, Map<String, double>> desglose,
  }) async {
    final pdf = pw.Document();

    String rangoFechas = DateFormat('dd/MM/yyyy').format(fechaInicio);
    if (fechaInicio.day != fechaFin.day ||
        fechaInicio.month != fechaFin.month) {
      rangoFechas += " al ${DateFormat('dd/MM/yyyy').format(fechaFin)}";
    }

    final double balanceNeto = totalIngresos - totalEgresos;

    // Extraemos solo los métodos que tuvieron movimiento para asegurar que se impriman
    final metodosActivos = desglose.entries
        .where((e) => e.value['ingreso']! > 0 || e.value['egreso']! > 0)
        .toList();

    // --- CONSTRUCCIÓN DEL DISEÑO DEL PDF ---
    pdf.addPage(
      pw.MultiPage(
        // MultiPage permite que el contenido pase a otra hoja si es muy largo
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        build: (pw.Context context) {
          return [
            // ENCABEZADO
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  "REPORTE DE BALANCE",
                  style: pw.TextStyle(
                    fontSize: 24,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.green800,
                  ),
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
            pw.SizedBox(height: 20),
            pw.Divider(color: PdfColors.grey400),
            pw.SizedBox(height: 20),

            // RESUMEN GENERAL
            pw.Text(
              "RESUMEN GENERAL",
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 10),
            pw.Container(
              padding: const pw.EdgeInsets.all(15),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(10)),
                border: pw.Border.all(color: PdfColors.grey300),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceAround,
                children: [
                  _buildCajaResumen(
                    "INGRESOS",
                    totalIngresos,
                    PdfColors.green700,
                  ),
                  _buildCajaResumen("EGRESOS", totalEgresos, PdfColors.red700),
                  if (totalDescuentos > 0)
                    _buildCajaResumen(
                      "DESCUENTOS",
                      totalDescuentos,
                      PdfColors.orange700,
                    ),
                  _buildCajaResumen(
                    "BALANCE NETO",
                    balanceNeto,
                    balanceNeto >= 0 ? PdfColors.green900 : PdfColors.red900,
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 30),

            // DESGLOSE POR MÉTODO (Reconstruido para garantizar su impresión)
            pw.Text(
              "DESGLOSE POR MÉTODO DE PAGO",
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 15),

            if (metodosActivos.isEmpty)
              pw.Text(
                "No hubo movimientos en este periodo.",
                style: const pw.TextStyle(color: PdfColors.grey),
              ),

            ...metodosActivos.map((entry) {
              final metodo = entry.key;
              final ing = entry.value['ingreso']!;
              final egr = entry.value['egreso']!;
              final neto = ing - egr;

              return pw.Container(
                margin: const pw.EdgeInsets.only(bottom: 15),
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: const pw.BorderRadius.all(
                    pw.Radius.circular(8),
                  ),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: pw.CrossAxisAlignment.center,
                  children: [
                    pw.Text(
                      metodo,
                      style: pw.TextStyle(
                        fontWeight: pw.FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text(
                          "Ingresos: + ${AppFormatters.currency(ing)}",
                          style: const pw.TextStyle(color: PdfColors.green700),
                        ),
                        pw.SizedBox(height: 2),
                        pw.Text(
                          "Egresos: - ${AppFormatters.currency(egr)}",
                          style: const pw.TextStyle(color: PdfColors.red700),
                        ),
                        pw.SizedBox(height: 4),
                        pw.Text(
                          "Neto: ${AppFormatters.currency(neto)}",
                          style: pw.TextStyle(
                            fontWeight: pw.FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ];
        },
      ),
    );

    // --- Lógica DE GUARDADO (PC vs CELULAR) ---
    final bytes = await pdf.save();
    final nombreArchivo =
        "Balance_${DateFormat('ddMMyyyy_HHmm').format(DateTime.now())}.pdf";

    return GeneratedDocument(bytes: bytes, fileName: nombreArchivo, kind: DocumentKind.pdf);
  }

  static pw.Widget _buildCajaResumen(
    String titulo,
    double valor,
    PdfColor color,
  ) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Text(
          titulo,
          style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          AppFormatters.currency(valor),
          style: pw.TextStyle(
            fontSize: 16,
            fontWeight: pw.FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }
}
