import '../domain/sale_models.dart';
import 'sale_cart_mapper.dart';

/// Codec versionado; no cambia las claves de la cola histórica.
class PendingSaleMapper {
  const PendingSaleMapper._();

  static SaleCustomer decodeCustomer(Map<String, dynamic> row) => SaleCustomer(
    ruc: row['ruc']?.toString() ?? '',
    nombre: row['nombre']?.toString() ?? '',
    direccion: row['direccion']?.toString() ?? '',
  );

  static Map<String, dynamic> encodeCustomer(SaleCustomer customer) => {
    'ruc': customer.ruc, 'nombre': customer.nombre, 'direccion': customer.direccion,
  };

  static SalePayment decodePayment(Map<String, dynamic> row) {
    final raw = row['monto'];
    final amount = raw is num ? raw.toDouble() : double.tryParse(raw?.toString() ?? '0');
    if (amount == null || !amount.isFinite) {
      throw const FormatException('Importe de pago inválido.');
    }
    return SalePayment(metodo: row['metodo']?.toString() ?? '', monto: amount);
  }

  static Map<String, dynamic> encodePayment(SalePayment payment) =>
      {'metodo': payment.metodo, 'monto': payment.monto};

  static PendingSale decode(Map<String, dynamic> map) {
    final version = map['schema_version'];
    if (version != null && version != 1 && version != 2) {
      throw const FormatException('Versión de venta pendiente no compatible.');
    }
    final rawCliente = map['cliente'];
    final rawPagos = map['pagos'];
    final rawDetalles = map['detalles'];
    final rawAuthUserId = map['auth_user_id']?.toString().trim();
    final rawTipoComprobante = map['tipo_comprobante']?.toString().trim();

    return PendingSale(
      requestId: map['request_id']?.toString() ?? '',
      fecha: map['fecha']?.toString() ?? '',
      esCredito: map['es_credito'] == true,
      totalAPagar: (map['total_a_pagar'] as num?)?.toDouble() ?? 0.0,
      montoAbono: (map['monto_abono'] as num?)?.toDouble() ?? 0.0,
      montoDeuda: (map['monto_deuda'] as num?)?.toDouble() ?? 0.0,
      concepto: map['concepto']?.toString() ?? '',
      cotizacionId: (map['cotizacion_id'] as num?)?.toInt(),
      vendedorId: (map['vendedor_id'] as num?)?.toInt(),
      authUserId: rawAuthUserId == null || rawAuthUserId.isEmpty
          ? null
          : rawAuthUserId,
      tipoComprobante:
          rawTipoComprobante == null || rawTipoComprobante.isEmpty
          ? 'ticket_interno'
          : rawTipoComprobante.toLowerCase(),
      subtotalBruto: (map['subtotal_bruto'] as num?)?.toDouble() ?? 0.0,
      descuentoGlobalPorcentaje:
          (map['descuento_global_porcentaje'] as num?)?.toDouble() ?? 0.0,
      descuentoGlobalMonto:
          (map['descuento_global_monto'] as num?)?.toDouble() ?? 0.0,
      motivoDescuento: map['motivo_descuento']?.toString() ?? '',
      descuentoAutorizadoPor:
          (map['descuento_autorizado_por'] as num?)?.toInt(),
      cliente: decodeCustomer(
        rawCliente is Map
            ? Map<String, dynamic>.from(rawCliente)
            : const <String, dynamic>{},
      ),
      pagos: _rows(rawPagos).map(decodePayment),
      detalles: SaleCartMapper.decode(_rows(rawDetalles)),
    );
  }

  static Map<String, dynamic> encode(PendingSale sale) => {
    'schema_version': 2,
    'request_id': sale.requestId,
    'fecha': sale.fecha,
    'es_credito': sale.esCredito,
    'total_a_pagar': sale.totalAPagar,
    'monto_abono': sale.montoAbono,
    'monto_deuda': sale.montoDeuda,
    'concepto': sale.concepto,
    'cotizacion_id': sale.cotizacionId,
    'vendedor_id': sale.vendedorId,
    'auth_user_id': sale.authUserId,
    'tipo_comprobante': sale.tipoComprobante,
    'subtotal_bruto': sale.subtotalBruto,
    'descuento_global_porcentaje': sale.descuentoGlobalPorcentaje,
    'descuento_global_monto': sale.descuentoGlobalMonto,
    'motivo_descuento': sale.motivoDescuento,
    'descuento_autorizado_por': sale.descuentoAutorizadoPor,
    'cliente': encodeCustomer(sale.cliente),
    'pagos': sale.pagos.map(encodePayment).toList(growable: false),
    'detalles': SaleCartMapper.encode(sale.detalles),
  };

  static Iterable<Map<String, dynamic>> _rows(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List || raw.any((row) => row is! Map)) {
      throw const FormatException('La venta pendiente contiene líneas inválidas.');
    }
    return raw.map((row) => Map<String, dynamic>.from(row as Map));
  }
}
