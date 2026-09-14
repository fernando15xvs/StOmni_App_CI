import '../../../utils/app_formatters.dart';
import 'fiscal_policy.dart';
import 'sale_models.dart';

class VentaFormRules {
  const VentaFormRules._();

  static String? validar({
    required FiscalPolicy fiscalPolicy,
    required bool esCredito,
    required String tipoComprobante,
    required DateTime fecha,
    required DateTime ahora,
    required double subtotalBruto,
    required double valorDescuentoIngresado,
    required bool descuentoEsPorcentaje,
    required double descuentoGlobalMonto,
    required double descuentoGlobalPorcentaje,
    required String motivoDescuento,
    required double totalFinal,
    required double totalPagado,
    required double montoAbono,
    required String documentoCliente,
    required String nombreCliente,
  }) {
    if (subtotalBruto <= 0) {
      return 'El subtotal de la venta debe ser mayor a S/ 0.00.';
    }
    if (valorDescuentoIngresado < 0) {
      return 'El descuento no puede ser negativo.';
    }
    if (descuentoEsPorcentaje && valorDescuentoIngresado > 100) {
      return 'El descuento no puede superar el 100 %.';
    }
    if (!descuentoEsPorcentaje && descuentoGlobalMonto > subtotalBruto) {
      return 'El descuento no puede superar el subtotal.';
    }
    if (descuentoGlobalMonto >= subtotalBruto && descuentoGlobalMonto > 0) {
      return 'El descuento debe dejar un total mayor a S/ 0.00.';
    }
    if (descuentoGlobalPorcentaje >= 10 && motivoDescuento.trim().isEmpty) {
      return 'Los descuentos de 10 % o más requieren un motivo.';
    }

    if (!esCredito) {
      if ((totalPagado - totalFinal).abs() > 0.01) {
        return 'Los pagos deben sumar exactamente '
            '${AppFormatters.currency(totalFinal)}.';
      }
    } else {
      if (montoAbono < 0) return 'El abono no puede ser negativo.';
      if (montoAbono > totalFinal) {
        return 'El abono no puede ser mayor al total.';
      }
    }

    return fiscalPolicy.validate(
      FiscalSaleDraft(
        documentCode: tipoComprobante.trim().toLowerCase(),
        date: fecha,
        isCredit: esCredito,
        total: totalFinal,
        customer: SaleCustomer(
          ruc: documentoCliente,
          nombre: nombreCliente,
          direccion: '',
        ),
      ),
      now: ahora,
    );
  }
}
