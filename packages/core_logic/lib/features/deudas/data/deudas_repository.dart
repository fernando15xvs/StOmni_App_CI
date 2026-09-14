import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';
import '../../ventas/data/ventas_repository.dart';
import '../../gastos/data/gastos_repository.dart';
import 'debt_payment_request_store.dart';

final debtPaymentRequestStoreProvider = Provider<DebtPaymentRequestStore>((ref) {
  return DebtPaymentRequestStore();
});

final deudasRepositoryProvider = Provider<DeudasRepository>((ref) {
  return DeudasRepository(
    ref.read(supabaseProvider),
    ref.read(ventasRepositoryProvider),
    ref.read(gastosRepositoryProvider),
    ref.read(debtPaymentRequestStoreProvider),
  );
});

class DeudasRepository {
  final SupabaseClient _client;
  final VentasRepository _ventasRepo;
  final GastosRepository _gastosRepo;
  final DebtPaymentRequestStore _paymentRequestStore;

  DeudasRepository(
    this._client,
    this._ventasRepo,
    this._gastosRepo,
    this._paymentRequestStore,
  );

  Future<Map<String, List<dynamic>>> obtenerDeudasActivas() async {
    try {
      final ventasData = await _client
          .from('ventas')
          .select('*, clientes(nombre)')
          .eq('estado', 'pendiente');

      final gastosData = await _client
          .from('gastos')
          .select('*, proveedores(nombre)')
          .eq('estado', 'pendiente');

      return {'ventas': ventasData, 'gastos': gastosData};
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  Future<List<dynamic>> obtenerDetalleDeudasActor(
    int actorId,
    bool esCliente,
  ) async {
    try {
      if (esCliente) {
        return await _client
            .from('ventas')
            .select('*, clientes(nombre)')
            .eq('cliente_id', actorId)
            .eq('estado', 'pendiente')
            .order('fecha', ascending: false);
      }

      return await _client
          .from('gastos')
          .select('*, proveedores(nombre)')
          .eq('proveedor_id', actorId)
          .eq('estado', 'pendiente')
          .order('fecha', ascending: false);
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  Future<Map<String, dynamic>> registrarPagoDeuda({
    required bool esCliente,
    required int deudaId,
    required double monto,
    required String metodoPago,
    required String fechaIso,
    required double saldoActual,
    bool descontarDeCaja = false,
  }) async {
    try {
      final authUserId = _client.auth.currentUser?.id;
      if (authUserId == null || authUserId.trim().isEmpty) {
        throw const UserFacingException(
          'Debes iniciar sesión para registrar un pago.',
        );
      }

      final fingerprint = DebtPaymentRequestStore.buildFingerprint(
        authUserId: authUserId,
        esCliente: esCliente,
        deudaId: deudaId,
        monto: monto,
        metodoPago: metodoPago,
        saldoActual: saldoActual,
        descontarDeCaja: descontarDeCaja,
      );
      final intent = await _paymentRequestStore.getOrCreate(
        fingerprint: fingerprint,
      );

      // La intención se elimina únicamente cuando el backend devuelve un
      // resultado confirmado. Cualquier timeout/error incierto conserva el UUID
      // para que el siguiente intento no pueda duplicar un pago ya confirmado.
      final raw = await _client.rpc(
        'procesar_pago_deuda_v2',
        params: {
          'p_request_id': intent.requestId,
          'p_es_cliente': esCliente,
          'p_deuda_id': deudaId,
          'p_monto': monto,
          'p_metodo': metodoPago,
          'p_fecha': fechaIso,
          'p_descontar_de_caja': descontarDeCaja,
        },
      );

      if (raw is! Map) {
        throw const UserFacingException(
          'El servidor devolvió una respuesta de pago inválida.',
        );
      }

      final result = Map<String, dynamic>.from(raw);
      if (result['success'] != true) {
        throw const UserFacingException('El servidor no confirmó el pago.');
      }

      await _paymentRequestStore.markConfirmed(fingerprint);
      return result;
    } on UserFacingException {
      rethrow;
    } catch (e) {
      // No se marca la intención como confirmada ante errores o respuestas
      // inciertas. El mismo request_id se reutilizará en el siguiente intento.
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  Future<void> eliminarDeuda(int deudaId, bool esCliente) async {
    try {
      if (esCliente) {
        await _ventasRepo.anularVenta(
          ventaId: deudaId,
          motivo: 'Deuda eliminada/anulada',
        );
      } else {
        await _gastosRepo.eliminarGasto(deudaId);
      }
    } on UserFacingException {
      rethrow;
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }
}
