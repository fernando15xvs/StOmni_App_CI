import 'package:flutter_test/flutter_test.dart';
import 'package:core_logic/core_logic.dart';

void main() {
  group('StockUtils', () {
    test('calcula el total de piezas correctamente', () {
      expect(StockUtils.calcularTotalPiezas(cajas: 2, unidades: 0, tipoVenta: SaleUnitType.caja, pcs: 12), 2);
      expect(StockUtils.calcularTotalPiezas(cajas: 0, unidades: 3, tipoVenta: SaleUnitType.unidad, pcs: 12), 3);
      expect(StockUtils.calcularTotalPiezas(cajas: 2, unidades: 3, tipoVenta: SaleUnitType.ambos, pcs: 12), 27);
    });

    test('normaliza el precio unitario a partir de precio por caja', () {
      expect(
        StockUtils.calcularPrecioUnitario(
          precioUnidad: 2.5,
          precioCaja: 30.0,
          pcs: 12,
          tipoUnidad: 'caja',
        ),
        30.0,
      );
      expect(
        StockUtils.calcularPrecioUnitario(
          precioUnidad: 2.5,
          precioCaja: 0,
          pcs: 12,
          tipoUnidad: 'unidad',
        ),
        2.5,
      );
    });

    test('getTipoVentaFromMap mapea correctamente la base de datos', () {
      expect(StockUtils.getTipoVentaFromMap({'tipo_venta': 'UNIDAD'}), SaleUnitType.unidad);
      expect(StockUtils.getTipoVentaFromMap({'tipo_venta': 'CAJA'}), SaleUnitType.caja);
      expect(StockUtils.getTipoVentaFromMap({'tipo_venta': 'SOLO_CAJAS'}), SaleUnitType.caja);
      expect(StockUtils.getTipoVentaFromMap({'tipo_venta': 'AMBOS'}), SaleUnitType.ambos);
      expect(StockUtils.getTipoVentaFromMap({'tipo_venta': 'CAJA_UNIDAD'}), SaleUnitType.ambos);
      
      // Fallbacks
      expect(StockUtils.getTipoVentaFromMap({'unidad_medida': 'Cajas', 'cantidad_por_caja': 1}), SaleUnitType.caja);
      expect(StockUtils.getTipoVentaFromMap({'unidad_medida': 'Unidades', 'cantidad_por_caja': 1}), SaleUnitType.unidad);
    });

    test('formatStock formatea correctamente la UI', () {
      expect(StockUtils.formatStock(5, 12, SaleUnitType.unidad), '5 Unidades');
      expect(StockUtils.formatStock(5, 12, SaleUnitType.caja), '5 Cajas');
      expect(StockUtils.formatStock(27, 12, SaleUnitType.ambos), '2 Cajas y 3 Unidades');
      expect(StockUtils.formatStock(5, 1, SaleUnitType.ambos), '5 Unidades');
    });
  });
}
