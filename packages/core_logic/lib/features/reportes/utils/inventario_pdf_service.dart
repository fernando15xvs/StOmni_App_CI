import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../documents/domain/generated_document.dart';
import '../../../utils/app_formatters.dart';
import '../../../utils/inventario_movimiento_utils.dart';

class InventarioPdfService {
  static Future<GeneratedDocument> generar({
    required DateTime fechaInicio,
    required DateTime fechaFin,
    required List<Map<String, dynamic>> movimientos,
    required bool incluirIngresos,
    required bool incluirSalidas,
    required bool incluirTraslados,
  }) async {
    final pdf = pw.Document();

    final secciones = <_InventarioPdfSection>[
      if (incluirIngresos)
        _InventarioPdfSection(
          titulo: 'INGRESOS',
          color: PdfColors.green700,
          items: movimientos
              .where(
                (item) =>
                    InventarioMovimientoUtils.clasificacion(item) == 'ingreso',
              )
              .toList(),
        ),
      if (incluirSalidas)
        _InventarioPdfSection(
          titulo: 'SALIDAS',
          color: PdfColors.orange700,
          items: movimientos
              .where(
                (item) =>
                    InventarioMovimientoUtils.clasificacion(item) == 'salida',
              )
              .toList(),
        ),
      if (incluirTraslados)
        _InventarioPdfSection(
          titulo: 'TRASLADOS',
          color: PdfColors.deepPurple700,
          items: movimientos
              .where(
                (item) =>
                    InventarioMovimientoUtils.clasificacion(item) == 'traslado',
              )
              .toList(),
        ),
    ];

    final rangoFechas = _formatearRangoFechas(fechaInicio, fechaFin);

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (context) {
          final widgets = <pw.Widget>[
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'REPORTE DE INVENTARIO',
                      style: pw.TextStyle(
                        fontSize: 22,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.teal800,
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Text(
                      'Cantidades históricas por paquete, caja o unidad',
                      style: const pw.TextStyle(
                        fontSize: 10,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ],
                ),
                pw.Text(
                  'Fecha: $rangoFechas',
                  style: const pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.grey700,
                  ),
                ),
              ],
            ),
            pw.SizedBox(height: 14),
            pw.Divider(color: PdfColors.grey400),
            pw.SizedBox(height: 12),
          ];

          for (final seccion in secciones) {
            widgets.addAll([
              pw.Container(
                width: double.infinity,
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: pw.BoxDecoration(
                  color: seccion.color,
                  borderRadius: const pw.BorderRadius.all(
                    pw.Radius.circular(8),
                  ),
                ),
                child: pw.Text(
                  '${seccion.titulo} (${seccion.items.length})',
                  style: pw.TextStyle(
                    color: PdfColors.white,
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              pw.SizedBox(height: 8),
            ]);

            if (seccion.items.isEmpty) {
              widgets.add(
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.all(12),
                  margin: const pw.EdgeInsets.only(bottom: 14),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: PdfColors.grey300),
                    borderRadius: const pw.BorderRadius.all(
                      pw.Radius.circular(8),
                    ),
                  ),
                  child: pw.Text(
                    'Sin movimientos en esta categoría.',
                    style: const pw.TextStyle(
                      fontSize: 10,
                      color: PdfColors.grey700,
                    ),
                  ),
                ),
              );
              continue;
            }

            widgets.add(
              pw.Table(
                border: pw.TableBorder.all(
                  color: PdfColors.grey400,
                  width: 0.5,
                ),
                columnWidths: const {
                  0: pw.FlexColumnWidth(1.7),
                  1: pw.FlexColumnWidth(1.7),
                  2: pw.FlexColumnWidth(3.0),
                  3: pw.FlexColumnWidth(2.0),
                  4: pw.FlexColumnWidth(2.2),
                  5: pw.FlexColumnWidth(2.4),
                },
                children: [
                  pw.TableRow(
                    decoration: const pw.BoxDecoration(
                      color: PdfColors.grey200,
                    ),
                    children: [
                      _celdaHeader('Fecha / Hora'),
                      _celdaHeader('Tipo'),
                      _celdaHeader('Producto'),
                      _celdaHeader('Almacén'),
                      _celdaHeader('Cantidad'),
                      _celdaHeader('Observaciones'),
                    ],
                  ),
                  ...seccion.items.map((item) {
                    final fecha = toLima(item['fecha']);
                    final codigo = InventarioMovimientoUtils.codigoProducto(
                      item,
                    );
                    final nombre =
                        item['producto_nombre']?.toString() ?? 'Desconocido';
                    final producto = codigo == null
                        ? nombre
                        : '$codigo · $nombre';
                    final almacen =
                        item['almacen_nombre']?.toString() ?? 'Sin almacén';
                    final subtipo = InventarioMovimientoUtils.subtipo(item);
                    final cantidad =
                        InventarioMovimientoUtils.formatCantidadMovimiento(
                          item,
                        );
                    final observaciones = (item['observaciones'] ?? '-')
                        .toString();

                    return pw.TableRow(
                      children: [
                        _celdaTexto(DateFormat('dd/MM HH:mm').format(fecha)),
                        _celdaTexto(subtipo),
                        _celdaTexto(producto),
                        _celdaTexto(almacen),
                        _celdaTexto(cantidad),
                        _celdaTexto(observaciones),
                      ],
                    );
                  }),
                ],
              ),
            );
            widgets.add(pw.SizedBox(height: 16));
          }

          return widgets;
        },
      ),
    );

    final bytes = await pdf.save();
    final nombreArchivo =
        'Inventario_${DateFormat('ddMMyyyy_HHmm').format(DateTime.now())}.pdf';

    return GeneratedDocument(
      bytes: bytes,
      fileName: nombreArchivo,
      kind: DocumentKind.pdf,
    );
  }

  static String _formatearRangoFechas(DateTime inicio, DateTime fin) {
    final inicioTxt = DateFormat('dd/MM/yyyy').format(inicio);
    final finTxt = DateFormat('dd/MM/yyyy').format(fin);
    if (inicio.year == fin.year &&
        inicio.month == fin.month &&
        inicio.day == fin.day) {
      return inicioTxt;
    }
    return '$inicioTxt al $finTxt';
  }

  static pw.Widget _celdaHeader(String texto) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(4),
      child: pw.Text(
        texto,
        style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
        textAlign: pw.TextAlign.center,
      ),
    );
  }

  static pw.Widget _celdaTexto(String texto) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(4),
      child: pw.Text(texto, style: const pw.TextStyle(fontSize: 7.5)),
    );
  }
}

class _InventarioPdfSection {
  final String titulo;
  final PdfColor color;
  final List<Map<String, dynamic>> items;

  const _InventarioPdfSection({
    required this.titulo,
    required this.color,
    required this.items,
  });
}
