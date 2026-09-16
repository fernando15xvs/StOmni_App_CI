import 'package:excel/excel.dart';
import 'package:intl/intl.dart';

import '../../../documents/domain/generated_document.dart';
import '../../../utils/app_formatters.dart';
import '../../../utils/stock_utils.dart';
import '../domain/reportes_excel_snapshot.dart';

class ReporteExcelService {
  static CellStyle _crearEstiloCabecera() {
    return CellStyle(
      bold: true,
      fontColorHex: ExcelColor.white,
      backgroundColorHex: ExcelColor.fromHexString('#0F9D58'),
      horizontalAlign: HorizontalAlign.Center,
      verticalAlign: VerticalAlign.Center,
    );
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

  static String _presentacion(Map<String, dynamic> detalle) {
    final cantidad = (detalle['cantidad'] as num?)?.toInt() ?? 0;
    final tipo = StockUtils.normalizarTipoUnidad(
      detalle['tipo_unidad']?.toString(),
    );
    return '$cantidad ${StockUtils.etiquetaUnidadComercial(tipo, cantidad: cantidad)}';
  }

  static String _cantidadBase(Map<String, dynamic> detalle) {
    final cantidad = (detalle['piezas_reales'] as num?)?.toInt() ?? 0;
    final unidad = detalle['unidad_base_snapshot']?.toString().trim();
    final etiqueta = unidad == null || unidad.isEmpty ? 'Unidades' : unidad;
    final plural = cantidad == 1
        ? etiqueta.replaceFirst(RegExp(r's$'), '')
        : (etiqueta.endsWith('s') ? etiqueta : '${etiqueta}s');
    return '$cantidad $plural';
  }

  static double _precioComercial(Map<String, dynamic> detalle) {
    final directo = (detalle['precio_unitario_comercial'] as num?)?.toDouble();
    if (directo != null) return directo;
    final cantidad = (detalle['cantidad'] as num?)?.toDouble() ?? 0;
    final subtotal = (detalle['subtotal'] as num?)?.toDouble() ?? 0;
    return cantidad > 0 ? subtotal / cantidad : 0;
  }

  static double _subtotalFinal(Map<String, dynamic> detalle) {
    final finalValue = (detalle['subtotal_final'] as num?)?.toDouble();
    if (finalValue != null) return finalValue;
    return (detalle['subtotal'] as num?)?.toDouble() ?? 0;
  }

  static void _aplicarCabecera(
    Sheet sheet,
    List<String> encabezados, {
    required List<double> anchos,
  }) {
    final headerStyle = _crearEstiloCabecera();
    sheet.appendRow(_crearFila(encabezados));
    for (var i = 0; i < encabezados.length; i++) {
      sheet
              .cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0))
              .cellStyle =
          headerStyle;
      if (i < anchos.length) sheet.setColumnWidth(i, anchos[i]);
    }
  }

  static Future<GeneratedDocument> generar({
    required DateTime fechaInicio,
    required DateTime fechaFin,
    required ReportesExcelSnapshot snapshot,
    required bool incluirVentas,
    required bool incluirAbonos,
    required bool incluirGastos,
    required bool incluirPersonal,
  }) async {
    final excel = Excel.createExcel()..delete('Sheet1');

    if (incluirVentas) {
      final sheet = excel['Ventas Realizadas'];
      _aplicarCabecera(
        sheet,
        [
          'Fecha / Hora',
          'Nro. Venta',
          'Cliente',
          'Almacén',
          'Código',
          'Producto',
          'Presentación',
          'Cantidad base',
          'Precio comercial',
          'Precio base stock',
          'Subtotal final',
        ],
        anchos: [20, 12, 24, 18, 16, 30, 20, 20, 18, 18, 18],
      );

      for (final venta in snapshot.ventas) {
        final ventaId = (venta['id'] as num).toInt();
        final cliente = venta['clientes'] as Map?;
        final fecha = toLima(venta['fecha']);
        final detalles = snapshot.detallesVentas
            .where((d) => (d['venta_id'] as num?)?.toInt() == ventaId)
            .toList();

        for (final detalle in detalles) {
          final producto = Map<String, dynamic>.from(
            detalle['productos'] as Map? ?? const {},
          );
          sheet.appendRow(
            _crearFila([
              DateFormat('dd/MM/yyyy HH:mm').format(fecha),
              ventaId,
              cliente?['nombre']?.toString() ?? 'General',
              snapshot.almacenes[(detalle['almacen_id'] as num?)?.toInt()] ??
                  'General',
              producto['codigo']?.toString() ?? '',
              producto['nombre']?.toString() ?? 'Producto',
              _presentacion(detalle),
              _cantidadBase(detalle),
              _precioComercial(detalle),
              AppFormatters.toDouble(detalle['precio_unitario']),
              _subtotalFinal(detalle),
            ]),
          );
        }
      }
    }

    if (incluirAbonos) {
      final sheet = excel['Cobros Crédito'];
      _aplicarCabecera(
        sheet,
        [
          'Fecha / Hora Abono',
          'Nro. Venta',
          'Cliente',
          'Método',
          'Resumen Productos',
          'Deuda Restante Actual',
          'Monto del Abono',
        ],
        anchos: [20, 12, 24, 16, 48, 20, 18],
      );

      for (final pago in snapshot.pagosCredito) {
        final venta = Map<String, dynamic>.from(pago['ventas'] as Map);
        final ventaId = (venta['id'] as num).toInt();
        final cliente = venta['clientes'] as Map?;
        final detalles = snapshot.detallesAbonos
            .where((d) => (d['venta_id'] as num?)?.toInt() == ventaId)
            .toList();
        final resumen = detalles
            .map((d) {
              final producto = d['productos'] as Map?;
              return '${_presentacion(d)} de ${producto?['nombre'] ?? 'Producto'}';
            })
            .join(' + ');

        sheet.appendRow(
          _crearFila([
            AppFormatters.limaDateTimeLong(pago['fecha']),
            ventaId,
            cliente?['nombre']?.toString() ?? 'General',
            pago['metodo']?.toString() ?? 'Otro',
            resumen,
            AppFormatters.toDouble(venta['saldo']),
            AppFormatters.toDouble(pago['monto']),
          ]),
        );
      }
    }

    if (incluirGastos) {
      final sheet = excel['Gastos Egresos'];
      _aplicarCabecera(
        sheet,
        [
          'Fecha / Hora',
          'Proveedor',
          'Descripción del Gasto',
          'Categoría',
          'Método',
          'Monto Pagado',
        ],
        anchos: [20, 24, 34, 20, 16, 18],
      );
      for (final p in snapshot.pagosGasto) {
        final gasto = Map<String, dynamic>.from(p['gastos'] as Map);
        final proveedor = gasto['proveedores'] as Map?;
        sheet.appendRow(
          _crearFila([
            AppFormatters.limaDateTimeLong(p['fecha']),
            proveedor?['nombre']?.toString() ?? 'Varios',
            gasto['descripcion']?.toString() ?? '',
            gasto['categoria']?.toString() ?? '',
            p['metodo']?.toString() ?? 'Otro',
            AppFormatters.toDouble(p['monto']),
          ]),
        );
      }
    }

    if (incluirPersonal) {
      final sheet = excel['Pagos Personal'];
      _aplicarCabecera(
        sheet,
        ['Fecha / Hora', 'Empleado', 'Cargo', 'Concepto', 'Método', 'Monto'],
        anchos: [20, 24, 20, 30, 16, 18],
      );
      for (final p in snapshot.pagosPersonal) {
        final empleado = p['empleados'] as Map?;
        sheet.appendRow(
          _crearFila([
            AppFormatters.limaDateTimeLong(p['fecha']),
            empleado?['nombre']?.toString() ?? 'Personal de Baja',
            empleado?['cargo']?.toString() ?? '-',
            p['concepto']?.toString() ?? '',
            p['metodo']?.toString() ?? 'Otro',
            AppFormatters.toDouble(p['monto']),
          ]),
        );
      }
    }

    final bytes = excel.encode();
    if (bytes == null) {
      throw StateError('No se pudo generar el archivo Excel');
    }

    final nombreArchivo =
        'Reportes_Financieros_${DateFormat('ddMMyyyy_HHmm').format(DateTime.now())}.xlsx';

    return GeneratedDocument(
      bytes: bytes,
      fileName: nombreArchivo,
      kind: DocumentKind.xlsx,
    );
  }
}
