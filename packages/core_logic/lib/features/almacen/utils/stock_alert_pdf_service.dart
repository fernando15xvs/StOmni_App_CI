import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:intl/intl.dart';

import '../../../documents/domain/generated_document.dart';
import '../../../utils/stock_utils.dart';

class StockAlertPdfService {
  static Future<GeneratedDocument> generar({
    required List<Map<String, dynamic>> productos,
    required List<Map<String, dynamic>> almacenes,
    required Map<dynamic, String> mapaMarcas,
  }) async {
      final pdf = pw.Document();

      // Map para buscar el nombre del almacén por su ID rápidamente
      final Map<int, String> mapaAlmacenes = {};
      for (var a in almacenes) {
        if (a['id'] != null) {
          mapaAlmacenes[a['id'] as int] =
              a['nombre']?.toString() ?? 'Almacén ${a['id']}';
        }
      }

      final now = DateTime.now();
      final fechaStr = DateFormat('dd/MM/yyyy HH:mm').format(now);

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (pw.Context context) {
            return [
              _buildHeader(fechaStr),
              pw.SizedBox(height: 20),
              ...productos.map(
                (p) => _buildProductoItem(p, mapaMarcas, mapaAlmacenes),
              ),
            ];
          },
        ),
      );

      return GeneratedDocument(
        bytes: await pdf.save(),
        fileName: 'alerta_stock_${DateFormat('yyyyMMdd').format(now)}.pdf',
        kind: DocumentKind.pdf,
      );
  }

  static pw.Widget _buildHeader(String fecha) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Reporte de Alerta de Stock',
          style: pw.TextStyle(
            fontSize: 24,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.deepOrange800,
          ),
        ),
        pw.SizedBox(height: 8),
        pw.Text(
          'Fecha de generación: $fecha',
          style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 12),
        pw.Divider(color: PdfColors.grey400),
      ],
    );
  }

  static pw.Widget _buildProductoItem(
    Map<String, dynamic> p,
    Map<dynamic, String> mapaMarcas,
    Map<int, String> mapaAlmacenes,
  ) {
    final nombreProducto = p['nombre'] ?? 'Sin nombre';
    final codigo = p['codigo']?.toString().trim();
    final proveedorId = p['proveedor_id'];
    final nombreMarca = (proveedorId != null)
        ? (mapaMarcas[proveedorId] ?? 'Genérico')
        : 'Genérico';

    final int pcs = (p['cantidad_por_caja'] as num?)?.toInt() ?? 1;

    // Calcular el stock total y por almacén
    int totalUnidades = p['_totalStock'] as int? ?? 0;
    List<Map<String, dynamic>> desgloseAlmacenes = [];

    if (p['inventario_almacen'] != null) {
      int calcTotal = 0;
      for (var inv in p['inventario_almacen']) {
        if (inv is Map) {
          int cant = 0;
          if (inv['cantidad'] != null) {
            final val = inv['cantidad'];
            cant = (val is num)
                ? val.toInt()
                : (int.tryParse(val.toString()) ?? 0);
          }
          final almacenId = inv['almacen_id'] as int?;
          if (almacenId != null) {
            desgloseAlmacenes.add({'almacen_id': almacenId, 'cantidad': cant});
            calcTotal += cant;
          }
        }
      }
      if (totalUnidades == 0) totalUnidades = calcTotal;
    }

    final tipoVenta = StockUtils.getTipoVentaFromMap(p);
    final stockTotalMostrado = StockUtils.formatStock(
      totalUnidades,
      pcs,
      tipoVenta,
    );

    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 16),
      padding: const pw.EdgeInsets.all(12),
      decoration: pw.BoxDecoration(
        color: totalUnidades == 0 ? PdfColors.red50 : PdfColors.grey50,
        border: pw.Border.all(
          color: totalUnidades == 0 ? PdfColors.red200 : PdfColors.grey300,
        ),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (codigo != null && codigo.isNotEmpty)
            pw.Text(
              codigo,
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
          pw.Text(
            nombreProducto,
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Row(
            children: [
              pw.Text(
                'Proveedor: $nombreMarca',
                style: const pw.TextStyle(fontSize: 10),
              ),
              pw.SizedBox(width: 16),
              pw.Text(
                StockUtils.usaContenidoInformativo(tipoVenta, pcs)
                    ? StockUtils.descripcionContenido(pcs, tipoVenta)
                    : 'Sin contenido por empaque',
                style: const pw.TextStyle(fontSize: 10),
              ),
              pw.SizedBox(width: 16),
              pw.Text(
                'Total Disponible: $stockTotalMostrado',
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: totalUnidades == 0 ? PdfColors.red : PdfColors.black,
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 8),

          if (totalUnidades == 0)
            pw.Text(
              'Sin stock en todos los almacenes.',
              style: pw.TextStyle(
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
                fontStyle: pw.FontStyle.italic,
                color: PdfColors.red800,
              ),
            )
          else
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: desgloseAlmacenes
                  .where((a) => (a['cantidad'] as int) > 0)
                  .map((alm) {
                    final nombreAlmacen =
                        mapaAlmacenes[alm['almacen_id']] ?? 'Desconocido';
                    final cant = alm['cantidad'] as int;
                    final stockAlmacen = StockUtils.formatStock(
                      cant,
                      pcs,
                      tipoVenta,
                    );
                    return pw.Padding(
                      padding: const pw.EdgeInsets.only(bottom: 2, left: 8),
                      child: pw.Row(
                        children: [
                          pw.Container(
                            width: 4,
                            height: 4,
                            decoration: const pw.BoxDecoration(
                              color: PdfColors.grey600,
                              shape: pw.BoxShape.circle,
                            ),
                          ),
                          pw.SizedBox(width: 6),
                          pw.Text(
                            '$nombreAlmacen: $stockAlmacen',
                            style: const pw.TextStyle(
                              fontSize: 10,
                              color: PdfColors.grey800,
                            ),
                          ),
                        ],
                      ),
                    );
                  })
                  .toList(),
            ),
        ],
      ),
    );
  }
}
