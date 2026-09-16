import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../lib/features/ventas/presentation/controllers/carrito_controller.dart';

void main() {
  test('selección mantiene estado tipado e inmutable y limpia al terminar', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(carritoProvider.notifier);
    final before = container.read(carritoProvider);
    controller.actualizarProducto(1, const [
      SaleCartLine(
        productId: 1,
        quantity: 2,
        subtotal: 20,
        commercialUnit: 'unidad',
      ),
    ]);
    expect(before.isEmpty, isTrue);
    expect(container.read(carritoProvider).totalAmount, 20);
    expect(controller.resumenCantidades, '2 unidades');
    controller.eliminarProducto(1);
    expect(container.read(carritoProvider).isEmpty, isTrue);
    controller.actualizarProducto(2, const [
      SaleCartLine(
        productId: 2,
        quantity: 1,
        subtotal: 10,
        commercialUnit: 'caja',
      ),
    ]);
    controller.limpiarCarrito();
    expect(container.read(carritoProvider).isEmpty, isTrue);
  });
}
