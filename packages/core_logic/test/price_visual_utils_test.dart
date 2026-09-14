import 'package:flutter_test/flutter_test.dart';
import 'package:core_logic/core_logic.dart';

void main() {
  group('PriceVisualUtils - getPrecioVisual', () {
    test('1. cajas completas: 2C, PCS 10, precio base S/ 2.00, total S/ 40.00 -> mostrar S/ 20.00', () {
      final precio = PriceVisualUtils.getPrecioVisual(
        precioUnitarioBase: 2.00,
        pcs: 10,
        tipoVentaProducto: 'ambos',
        cantidadBase: 20, // 2C = 20 piezas
      );
      expect(precio, 20.00);
      
      final sufijo = PriceVisualUtils.getSufijoVisual(
        pcs: 10,
        tipoVentaProducto: 'ambos',
        cantidadBase: 20,
      );
      expect(sufijo, '');
    });

    test('2. venta mixta: 1C 2U, PCS 10, precio base S/ 4.00, total S/ 48.00 -> mostrar S/ 4.00', () {
      final precio = PriceVisualUtils.getPrecioVisual(
        precioUnitarioBase: 4.00,
        pcs: 10,
        tipoVentaProducto: 'ambos',
        cantidadBase: 12, // 1C 2U = 12 piezas
      );
      expect(precio, 4.00);
      
      final sufijo = PriceVisualUtils.getSufijoVisual(
        pcs: 10,
        tipoVentaProducto: 'ambos',
        cantidadBase: 12,
      );
      expect(sufijo, ' / und.');
    });

    test('3. SOLO_CAJAS, 3 cajas, PCS 40, precio base S/ 4.00, total S/ 480.00 -> mostrar S/ 160.00', () {
      final precio = PriceVisualUtils.getPrecioVisual(
        precioUnitarioBase: 4.00,
        pcs: 40,
        tipoVentaProducto: 'solo_cajas',
        cantidadBase: 120, // 3 cajas = 120 piezas
      );
      expect(precio, 160.00);
      
      final sufijo = PriceVisualUtils.getSufijoVisual(
        pcs: 40,
        tipoVentaProducto: 'solo_cajas',
        cantidadBase: 120,
      );
      expect(sufijo, '');
    });

    test('4. SOLO_UNIDADES: precio visual siempre es base', () {
      final precio = PriceVisualUtils.getPrecioVisual(
        precioUnitarioBase: 5.00,
        pcs: 12,
        tipoVentaProducto: 'solo_unidades',
        cantidadBase: 24, // 24 piezas
      );
      expect(precio, 5.00);
    });

    test('5. PCS cero o negativo usa fallback seguro a 1 y asume cajas cerradas si divide exacto', () {
      final precio = PriceVisualUtils.getPrecioVisual(
        precioUnitarioBase: 3.50,
        pcs: 0,
        tipoVentaProducto: 'ambos',
        cantidadBase: 5,
      );
      // pcs se fuerza a 1 internamente
      // cantidadBase 5 >= 1 y % 1 == 0, por ende es caja (1x) -> precio * 1
      expect(precio, 3.50);
    });

    test('6. Tipo desconocido: fallback a precio unitario base', () {
      final precio = PriceVisualUtils.getPrecioVisual(
        precioUnitarioBase: 10.00,
        pcs: 5,
        tipoVentaProducto: 'otro_tipo',
        cantidadBase: 10,
      );
      expect(precio, 10.00);
    });

    test('7. Unidades sueltas (cantidad menor a PCS)', () {
      final precio = PriceVisualUtils.getPrecioVisual(
        precioUnitarioBase: 2.00,
        pcs: 10,
        tipoVentaProducto: 'ambos',
        cantidadBase: 3, // solo 3 unidades
      );
      expect(precio, 2.00);
      
      final sufijo = PriceVisualUtils.getSufijoVisual(
        pcs: 10,
        tipoVentaProducto: 'ambos',
        cantidadBase: 3,
      );
      expect(sufijo, ' / und.');
    });
    
    test('8. Cantidad cero: caso extremo asume mixto o cero cajas enteras según la regla', () {
      final precio = PriceVisualUtils.getPrecioVisual(
        precioUnitarioBase: 2.00,
        pcs: 10,
        tipoVentaProducto: 'ambos',
        cantidadBase: 0, 
      );
      // cantidadBase >= pcs es falso (0 >= 10 es falso)
      expect(precio, 2.00);
    });
  });
}
