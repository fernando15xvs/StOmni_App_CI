import 'dart:convert';
import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('artefacto copia bytes y no admite rutas como nombre de descarga', () {
    final input = [1, 2, 3];
    final document = GeneratedDocument(bytes: input, fileName: '../reporte', kind: DocumentKind.pdf);
    input[0] = 9;
    final output = document.bytes;
    output[1] = 9;
    expect(document.bytes, [1, 2, 3]);
    expect(document.fileName, 'reporte.pdf');
    expect(document.mimeType, 'application/pdf');
    expect(() => GeneratedDocument(bytes: [], fileName: 'empty', kind: DocumentKind.pdf), throwsArgumentError);
  });

  test('generación de ticket y cotización funciona sin assets ni plugins', () async {
    for (final type in TipoDocumento.values) {
      final bytes = await PdfGeneratorService.generarPdf(
        type, {'id': 1, 'fecha': '2026-09-04T10:00:00-05:00', 'total': 20.0}, [], null,
      );
      expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
    }
  });

  test('reportes PDF y Excel devuelven contenido sin elegir destino', () async {
    final date = DateTime(2026, 9, 4);
    final documents = await Future.wait([
      StockAlertPdfService.generar(productos: [], almacenes: [], mapaMarcas: {}),
      HistorialPagosPdfService.generar(pagos: [], nombreEmpleado: 'Empleado', rangoFechas: 'Septiembre', total: 0),
      DetallePdfService.generar(fechaInicio: date, fechaFin: date, totalIngresos: 0,
        totalEgresos: 0, totalDescuentos: 0, desglose: {}),
      InventarioPdfService.generar(fechaInicio: date, fechaFin: date, movimientos: [],
        incluirIngresos: true, incluirSalidas: true, incluirTraslados: true),
      AlmacenExcelService.generar(configalmacenes: [], productosCompletos: [], mapaMarcas: {}),
      ReporteExcelService.generar(fechaInicio: date, fechaFin: date,
        snapshot: const ReportesExcelSnapshot(), incluirVentas: true,
        incluirAbonos: false, incluirGastos: false, incluirPersonal: false),
    ]);
    for (final document in documents) {
      if (document.kind == DocumentKind.pdf) {
        expect(ascii.decode(document.bytes.take(5).toList()), '%PDF-');
      } else {
        expect(document.bytes.take(2), [0x50, 0x4b]);
      }
      expect(document.fileName, endsWith('.${document.kind.name}'));
    }
  });
}
