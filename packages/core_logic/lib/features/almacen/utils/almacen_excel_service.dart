import 'package:excel/excel.dart';
import 'package:intl/intl.dart';

// IMPORTAMOS EL NUEVO HELPER
import '../../../documents/domain/generated_document.dart';
import '../../../utils/app_formatters.dart';
import '../../../utils/stock_utils.dart';
import '../../../utils/price_visual_utils.dart';

class AlmacenExcelService {
  static CellStyle _crearEstiloCabecera() {
    return CellStyle(
      bold: true,
      fontColorHex: ExcelColor.white,
      backgroundColorHex: ExcelColor.fromHexString('#0F9D58'),
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
    );
  }

  static String _formatearMoneda(dynamic valor) {
    return AppFormatters.currency(AppFormatters.toDouble(valor));
  }

  static String _formatearEmpaque(Map<String, dynamic> producto) {
    final tipoVenta = StockUtils.getTipoVentaFromMap(producto);

    switch (tipoVenta) {
      case SaleUnitType.paquete:
        return 'Paquetes';
      case SaleUnitType.cajaPaquetes:
        return 'Caja + Paquetes';
      case SaleUnitType.cajaUnidades:
        return 'Caja + Unidades';
      case SaleUnitType.caja:
        return 'Cajas';
      case SaleUnitType.unidad:
        return 'Unidades';
    }
  }

  static int obtenerStock(Map<String, dynamic> producto, int almacenId) {
    final inventario = producto['inventario_almacen'];
    if (inventario == null || inventario is! List) return 0;

    // Evitar el uso de orElse: () => null que causa crash en Dart null safety con listas fuertemente tipadas
    final iter = inventario.where((inv) => inv['almacen_id'] == almacenId);
    if (iter.isEmpty) return 0;

    final item = iter.first;
    if (item is! Map) return 0;
    final valor = item['cantidad'];
    if (valor is num) return valor.toInt();
    return int.tryParse(valor?.toString() ?? '') ?? 0;
  }

  static List<CellValue?> _crearFila(List<dynamic> datos) {
    return datos.map((valor) {
      if (valor == null) return null;
      if (valor is int) return IntCellValue(valor);
      if (valor is double) return DoubleCellValue(valor);
      if (valor is bool) return BoolCellValue(valor);
      return TextCellValue(valor.toString());
    }).toList();
  }

  static Future<GeneratedDocument> generar({
    required List<Map<String, dynamic>> configalmacenes,
    required List<Map<String, dynamic>> productosCompletos,
    required Map<int, String> mapaMarcas,
    String? nombreArchivoPersonalizado,
  }) async {
    var excel = Excel.createExcel();
    excel.delete('Sheet1');
    Sheet sheet = excel['Inventario'];
    Sheet resumen = excel['Resumen por Almacén'];

    final headerStyle = _crearEstiloCabecera();
    CellStyle centerStyle = CellStyle(
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
    );

    // =================== HOJA DE INVENTARIO ===================
    List<dynamic> headers = [
      "Código",
      "Producto",
      "Marca",
      "Modalidad",
      "Contenido",
      "Precio principal (S/)",
      "Precio base empaque (S/)",
      "Precio empaque completo (S/)",
      "Costo Ref. (S/)",
      "Venta sin Stock",
    ];
    for (var alm in configalmacenes) {
      headers.add("Stock ${alm['nombre']}");
    }
    headers.add("TOTAL STOCK");

    sheet.appendRow(_crearFila(headers));
    for (int i = 0; i < headers.length; i++) {
      sheet
              .cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0))
              .cellStyle =
          headerStyle;
      if (i == 0) {
        sheet.setColumnWidth(i, 18.0);
      } else if (i == 1) {
        sheet.setColumnWidth(i, 40.0);
      } else if (i == 4) {
        sheet.setColumnWidth(i, 26.0);
      } else if (i >= 10) {
        sheet.setColumnWidth(i, 22.0);
      } else {
        sheet.setColumnWidth(i, 18.0);
      }
    }

    int rowIndex = 1;
    Map<int, int> totalPorAlmacen = {for (var a in configalmacenes) a['id']: 0};

    for (var p in productosCompletos) {
      final SaleUnitType tipoVenta = StockUtils.getTipoVentaFromMap(p);
      String unidad = _formatearEmpaque(p);
      int pcs = (p['cantidad_por_caja'] as num?)?.toInt() ?? 1;

      String nombreMarca = mapaMarcas[p['proveedor_id']] ?? 'Genérico';
      bool permiteSinStock = p['permitir_sin_stock'] ?? false;
      final precioPrincipal = PriceVisualUtils.getPrecioPrincipalInventario(p);
      final precioBaseEmpaque = PriceVisualUtils.getPrecioBaseEmpaque(p);
      final precioEmpaqueCompleto = PriceVisualUtils.getPrecioEmpaqueCompleto(
        p,
      );

      List<dynamic> row = [
        p['codigo'] ?? '',
        p['nombre'],
        nombreMarca,
        unidad,
        StockUtils.usaContenidoInformativo(tipoVenta, pcs)
            ? StockUtils.descripcionContenido(pcs, tipoVenta)
            : '-',
        _formatearMoneda(precioPrincipal),
        _formatearMoneda(precioBaseEmpaque),
        _formatearMoneda(precioEmpaqueCompleto),
        _formatearMoneda(p['precio_compra']),
        permiteSinStock ? "Sí" : "No",
      ];

      int totalProd = 0;
      for (var alm in configalmacenes) {
        int cant = obtenerStock(p, alm['id']);
        totalProd += cant;
        totalPorAlmacen[alm['id']] = (totalPorAlmacen[alm['id']] ?? 0) + cant;
        row.add(StockUtils.formatStock(cant, pcs, tipoVenta)); // HELPER
      }
      row.add(StockUtils.formatStock(totalProd, pcs, tipoVenta)); // HELPER
      sheet.appendRow(_crearFila(row));

      sheet
              .cell(
                CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: rowIndex),
              )
              .cellStyle =
          centerStyle;
      sheet
              .cell(
                CellIndex.indexByColumnRow(columnIndex: 2, rowIndex: rowIndex),
              )
              .cellStyle =
          centerStyle;
      sheet
              .cell(
                CellIndex.indexByColumnRow(columnIndex: 3, rowIndex: rowIndex),
              )
              .cellStyle =
          centerStyle;
      sheet
              .cell(
                CellIndex.indexByColumnRow(columnIndex: 9, rowIndex: rowIndex),
              )
              .cellStyle =
          centerStyle;
      for (int i = 10; i < headers.length; i++) {
        sheet
                .cell(
                  CellIndex.indexByColumnRow(
                    columnIndex: i,
                    rowIndex: rowIndex,
                  ),
                )
                .cellStyle =
            centerStyle;
      }
      rowIndex++;
    }

    // =================== HOJA DE RESUMEN ===================
    resumen.appendRow(_crearFila(["Almacén", "Total de stock base"]));
    resumen
            .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0))
            .cellStyle =
        headerStyle;
    resumen
            .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 0))
            .cellStyle =
        headerStyle;
    resumen.setColumnWidth(0, 30);
    resumen.setColumnWidth(1, 20);

    int resumenRow = 1;
    for (var alm in configalmacenes) {
      int total = totalPorAlmacen[alm['id']] ?? 0;
      resumen.appendRow(_crearFila([alm['nombre'], total]));
      resumen
              .cell(
                CellIndex.indexByColumnRow(
                  columnIndex: 0,
                  rowIndex: resumenRow,
                ),
              )
              .cellStyle =
          centerStyle;
      resumen
              .cell(
                CellIndex.indexByColumnRow(
                  columnIndex: 1,
                  rowIndex: resumenRow,
                ),
              )
              .cellStyle =
          centerStyle;
      resumenRow++;
    }

    // =================== GUARDADO ===================
    final bytes = excel.encode();
    if (bytes == null) throw Exception('No se pudo generar el archivo Excel');

    final nombreArchivo =
        nombreArchivoPersonalizado ??
        "Inventario_${DateFormat('ddMMyyyy_HHmm').format(DateTime.now())}.xlsx";

    return GeneratedDocument(
      bytes: bytes,
      fileName: nombreArchivo,
      kind: DocumentKind.xlsx,
    );
  }
}
