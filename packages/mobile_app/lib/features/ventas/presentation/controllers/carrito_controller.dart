import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final carritoProvider = NotifierProvider<CarritoController, SaleCart>(
  CarritoController.new,
);

class CarritoController extends Notifier<SaleCart> {
  @override
  SaleCart build() => SaleCart.empty();

  void actualizarProducto(int productoId, Iterable<SaleCartLine> nuevosItems) {
    state = state.replaceProductLines(productoId, nuevosItems);
  }

  void eliminarProducto(int productoId) {
    state = state.removeProduct(productoId);
  }

  void limpiarCarrito() => state = SaleCart.empty();

  double get totalDinero => state.totalAmount;
  int get totalItems => state.lineCount;
  String get resumenCantidades => SaleCartSummaryFormatter.format(state);
}
