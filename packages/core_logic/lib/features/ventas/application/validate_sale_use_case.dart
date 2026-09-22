import 'sale_line_persistence_mapper.dart';
import 'procesar_venta_command.dart';
import 'sale_processing_models.dart';

class ValidatedSale {
  ValidatedSale({
    required Iterable<SaleProcessingLine> lines,
    required this.subtotal,
  }) : lines = List<SaleProcessingLine>.unmodifiable(lines);
  final List<SaleProcessingLine> lines;
  final double subtotal;
}

/// Reglas comerciales compartidas, antes de consultar cliente o persistir.
class ValidateSaleUseCase {
  const ValidateSaleUseCase();

  ValidatedSale execute(ProcesarVentaCommand command) {
    if (command.requestId.trim().isEmpty)
      throw ArgumentError('requestId es obligatorio.');
    if (command.cart.isEmpty)
      throw ArgumentError('La venta no contiene productos.');
    for (final value in [
      command.totalAPagar,
      command.montoAbono,
      command.subtotalBruto,
      command.descuentoGlobalMonto,
      command.descuentoGlobalPorcentaje,
    ]) {
      if (!value.isFinite || value < 0) {
        throw StateError('La venta contiene un importe inválido.');
      }
    }
    if (command.totalAPagar <= 0 ||
        command.montoAbono > command.totalAPagar ||
        command.descuentoGlobalPorcentaje > 100) {
      throw StateError('El total, abono o descuento de la venta no es válido.');
    }
    if (command.descuentoGlobalPorcentaje >= 10 &&
        (command.motivoDescuento ?? '').trim().isEmpty) {
      throw StateError('Los descuentos de 10 % o más requieren un motivo.');
    }
    final lines = command.cart.lines
        .map(SaleLinePersistenceMapper.map)
        .toList(growable: false);
    final subtotal = lines.fold<double>(0, (sum, line) => sum + line.subtotal);
    if (!subtotal.isFinite ||
        subtotal <= 0 ||
        (command.subtotalBruto > 0 &&
            (subtotal - command.subtotalBruto).abs() > 0.02)) {
      throw StateError(
        'El subtotal del carrito cambió. Vuelve a revisar la venta.',
      );
    }
    if ((subtotal - command.descuentoGlobalMonto - command.totalAPagar).abs() >
        0.02) {
      throw StateError('El total no coincide con el subtotal y descuento.');
    }
    var paid = 0.0;
    for (final payment in command.payments) {
      if (payment.metodo.trim().isEmpty ||
          !payment.monto.isFinite ||
          payment.monto <= 0) {
        throw StateError('La venta contiene un pago inválido.');
      }
      paid += payment.monto;
    }
    final expectedPayment = command.esCredito
        ? command.montoAbono
        : command.totalAPagar;
    if (!paid.isFinite || (paid - expectedPayment).abs() > 0.01) {
      throw StateError(
        'Los pagos no coinciden con el importe que debe cobrarse.',
      );
    }
    return ValidatedSale(lines: lines, subtotal: subtotal);
  }
}
