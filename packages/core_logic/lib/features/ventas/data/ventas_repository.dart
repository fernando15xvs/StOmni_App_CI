import '../../../providers/supabase_provider.dart';
import '../../../utils/app_time.dart';
import '../../almacen/data/supabase_product_unit_configuration_gateway.dart';
import '../application/sale_processing_models.dart';
import '../domain/sale_cart.dart';
import 'quotation_sale_cart_mapper.dart';
import 'sale_detail_presentation_mapper.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

final ventasRepositoryProvider = Provider<VentasRepository>((ref) {
  return VentasRepository(ref.read(supabaseProvider));
});

class VentasRepository {
  final SupabaseClient _client;

  VentasRepository(this._client);

  Future<Map<String, dynamic>> processSaleRpc({
    required String requestId,
    required int clienteId,
    required double total,
    required String fecha,
    required bool esCredito,
    required double montoAbono,
    required List<Map<String, dynamic>> detalles,
    required List<Map<String, dynamic>> pagos,
    int? cotizacionId,
    int? vendedorId,
    String tipoComprobante = 'ticket_interno',
    double descuentoGlobalPorcentaje = 0,
    double descuentoGlobalMonto = 0,
    String? motivoDescuento,
    double subtotalBruto = 0,
    int? descuentoAutorizadoPor,
  }) async {
    final usesConfiguredUnits = detalles.any(
      (detail) => detail['unit_profile_revision'] != null,
    );
    final rpcLabel = usesConfiguredUnits
        ? 'process_sale_with_units_v4'
        : 'process_sale_v4';
    final params = <String, dynamic>{
      'p_request_id': requestId,
      'p_cliente_id': clienteId,
      'p_total': total,
      'p_fecha': fecha,
      'p_es_credito': esCredito,
      'p_monto_abono': montoAbono,
      'p_detalles': detalles,
      'p_pagos': pagos,
      'p_cotizacion_id': cotizacionId,
      'p_vendedor_id': vendedorId,
      'p_tipo_comprobante': tipoComprobante,
      'p_descuento_global_porcentaje': descuentoGlobalPorcentaje,
      'p_descuento_global_monto': descuentoGlobalMonto,
      'p_motivo_descuento': motivoDescuento,
      'p_subtotal_bruto': subtotalBruto,
      'p_descuento_autorizado_por': descuentoAutorizadoPor,
    };

    try {
      // Los nombres permanecen literales para que el gate RPC pueda demostrar
      // exactamente qué entrypoints son ejecutables desde el cliente.
      final result = usesConfiguredUnits
          ? await _client.rpc('process_sale_with_units_v4', params: params)
          : await _client.rpc('process_sale_v4', params: params);
      if (result is Map<String, dynamic>) return result;
      if (result is Map) return Map<String, dynamic>.from(result);
      throw StateError('$rpcLabel devolvió una respuesta inválida.');
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    } catch (e) {
      throw Exception('Error en Supabase ($rpcLabel): $e');
    }
  }

  Future<void> anularVenta({
    required int ventaId,
    required String motivo,
  }) async {
    try {
      await _client.rpc(
        'anular_venta_v2',
        params: {'p_venta_id': ventaId, 'p_motivo': motivo.trim()},
      );
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    } catch (e) {
      throw Exception('Error al anular la venta: $e');
    }
  }

  Future<Map<String, dynamic>> obtenerVentaCompleta(int ventaId) async {
    try {
      final futures = await Future.wait(<Future<dynamic>>[
        _client
            .from('ventas')
            .select('*, clientes(*), empleados!ventas_vendedor_id_fkey(*)')
            .eq('id', ventaId)
            .single(),
        _client
            .from('detalle_ventas')
            .select(
              '*, productos(id, codigo, nombre, unidad_medida, cantidad_por_caja, '
              'tipo_venta, precio_unidad, precio_caja)',
            )
            .eq('venta_id', ventaId),
        _client.from('pagos_venta').select('*').eq('venta_id', ventaId),
      ]);
      return {
        'venta': futures[0],
        'detalles': SaleDetailPresentationMapper.restoreMany(futures[1]),
        'pagos': futures[2],
      };
    } catch (e) {
      throw Exception('Error al cargar la venta completa: $e');
    }
  }

  Future<void> eliminarPago({required int pagoId, required int ventaId}) async {
    try {
      await _client.rpc(
        'eliminar_pago_venta_v1',
        params: {'p_pago_id': pagoId, 'p_venta_id': ventaId},
      );
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    } catch (e) {
      throw Exception('Error al eliminar pago: $e');
    }
  }

  Future<String> obtenerNombreProveedor(int proveedorId) async {
    try {
      final provData = await _client
          .from('proveedores')
          .select('nombre')
          .eq('id', proveedorId)
          .maybeSingle();
      return provData?['nombre']?.toString().trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<Map<String, dynamic>> obtenerDatosCatalogoParaVentas() async {
    try {
      final almacenes = await _client
          .from('almacenes')
          .select()
          .eq('activo', true)
          .order('id');
      final productosRaw = await _client
          .from('productos')
          .select('*, inventario_almacen(almacen_id, cantidad)')
          .eq('activo', true)
          .order('nombre');
      final productos = await SupabaseProductUnitConfigurationGateway(_client)
          .attach(List<Map<String, dynamic>>.from(productosRaw));
      final proveedores = await _client
          .from('proveedores')
          .select('id, nombre');
      return {
        'almacenes': almacenes,
        'productos': productos,
        'proveedores': proveedores,
      };
    } catch (e) {
      throw Exception('Error al obtener catálogo: $e');
    }
  }

  Future<List<dynamic>> obtenerDetallesVenta(int ventaId) async {
    final rows = await _client
        .from('detalle_ventas')
        .select('*, productos(*, categorias(nombre))')
        .eq('venta_id', ventaId);
    return SaleDetailPresentationMapper.restoreMany(rows);
  }

  Future<int> guardarCotizacion({
    required String requestId,
    required int clienteId,
    required double total,
    required DateTime fecha,
    required String observaciones,
    required int validezDias,
    required List<SaleProcessingLine> detalles,
  }) async {
    final usesConfiguredUnits = detalles.any(
      (line) => line.presentationRevision != null,
    );
    final rpcLabel = usesConfiguredUnits
        ? 'guardar_cotizacion_with_units_v2'
        : 'guardar_cotizacion_v2';
    final params = <String, dynamic>{
      'p_request_id': requestId,
      'p_cliente_id': clienteId,
      'p_total': total,
      'p_fecha': AppTime.toIsoLima(fecha),
      'p_observaciones': observaciones.trim(),
      'p_validez_dias': validezDias,
      'p_detalles': detalles.map((line) => <String, dynamic>{
        'producto_id': line.productId,
        'cantidad': line.quantity,
        'piezas_reales': line.storedBaseQuantity,
        'cantidad_base_comercial': line.baseQuantity,
        'stock_scale': line.storageScale,
        'precio_unitario': line.baseUnitPrice,
        'precio_unitario_comercial': line.commercialUnitPrice,
        'subtotal': line.subtotal,
        'almacen_id': line.warehouseId,
        'tipo_unidad': line.unitCode,
        if (line.presentationRevision != null)
          'unit_profile_revision': line.presentationRevision,
        if (line.commercialUnitLabel != null)
          'commercial_unit_label': line.commercialUnitLabel,
      }).toList(growable: false),
    };

    try {
      final response = usesConfiguredUnits
          ? await _client.rpc('guardar_cotizacion_with_units_v2', params: params)
          : await _client.rpc('guardar_cotizacion_v2', params: params);
      if (response is! Map) {
        throw StateError('$rpcLabel devolvió una respuesta inválida.');
      }
      final result = Map<String, dynamic>.from(response);
      if (result['success'] != true) {
        throw StateError(
          result['mensaje']?.toString() ?? 'No se pudo guardar la cotización.',
        );
      }
      final rawId = result['cotizacion_id'];
      if (rawId is! num || rawId <= 0 || rawId != rawId.roundToDouble()) {
        throw StateError('$rpcLabel no devolvió un identificador válido.');
      }
      return rawId.toInt();
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    } catch (e) {
      throw Exception('Error al guardar la cotización: $e');
    }
  }

  Future<List<Map<String, dynamic>>> listarCotizaciones() async {
    try {
      await _client.rpc('actualizar_cotizaciones_vencidas').catchError((_) {});
      final response = await _client
          .from('cotizaciones')
          .select(
            '*, clientes(nombre, dni_ruc, direccion), '
            'detalle_cotizaciones('
            '*, productos('
            'id, codigo, nombre, unidad_medida, cantidad_por_caja, '
            'tipo_venta, precio_unidad, precio_caja, proveedor_id, activo'
            '))',
          )
          .order('id', ascending: false);
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      throw Exception('Error al listar cotizaciones: $e');
    }
  }

  SaleCart construirCarritoDesdeCotizacion(
    Map<String, dynamic> cotizacion,
  ) => QuotationSaleCartMapper.decode(cotizacion);

  Future<Map<String, dynamic>> convertirCotizacionEnVenta({
    required int cotizacionId,
    required bool esCredito,
    required String metodoPago,
  }) async {
    final data = await obtenerCotizacionCompleta(cotizacionId);
    final cotizacion = Map<String, dynamic>.from(data['cotizacion'] as Map);
    final detalles = List<Map<String, dynamic>>.from(data['detalles'] as List);
    final total = (cotizacion['total'] as num).toDouble();
    final clienteId = (cotizacion['cliente_id'] as num).toInt();
    final detallesPayload = detalles
        .map(QuotationSaleCartMapper.processingDetail)
        .toList(growable: false);
    final pagos = esCredito
        ? <Map<String, dynamic>>[]
        : <Map<String, dynamic>>[
            {'metodo': metodoPago, 'monto': total},
          ];
    return processSaleRpc(
      requestId: const Uuid().v4(),
      clienteId: clienteId,
      total: total,
      fecha: AppTime.nowIso(),
      esCredito: esCredito,
      montoAbono: esCredito ? 0 : total,
      detalles: detallesPayload,
      pagos: pagos,
      cotizacionId: cotizacionId,
      tipoComprobante: 'ticket_interno',
      subtotalBruto: total,
    );
  }

  Future<Map<String, dynamic>> obtenerCotizacionCompleta(
    int cotizacionId,
  ) async {
    try {
      await _client.rpc('actualizar_cotizaciones_vencidas').catchError((_) {});
      final futures = await Future.wait(<Future<dynamic>>[
        _client
            .from('cotizaciones')
            .select('*, clientes(*)')
            .eq('id', cotizacionId)
            .single(),
        _client
            .from('detalle_cotizaciones')
            .select(
              '*, productos('
              'id, codigo, nombre, unidad_medida, cantidad_por_caja, '
              'tipo_venta, precio_unidad, precio_caja, activo'
              ')',
            )
            .eq('cotizacion_id', cotizacionId)
            .order('id'),
      ]);
      return {
        'cotizacion': futures[0],
        'detalles': QuotationSaleCartMapper.restoreManyForDisplay(futures[1]),
      };
    } catch (e) {
      throw Exception('Error al cargar la cotización completa: $e');
    }
  }

  Future<void> eliminarCotizacion(int cotizacionId) async {
    try {
      await _client.rpc(
        'eliminar_cotizacion_v2',
        params: {'p_cotizacion_id': cotizacionId},
      );
    } on PostgrestException catch (e) {
      throw Exception(e.message);
    } catch (e) {
      throw Exception('Error al eliminar la cotización: $e');
    }
  }
}
