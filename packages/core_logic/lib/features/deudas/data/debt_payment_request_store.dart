import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:core_logic/core_logic.dart';

class DebtPaymentRequestIntent {
  const DebtPaymentRequestIntent({
    required this.requestId,
    required this.fingerprint,
    required this.createdAt,
  });

  final String requestId;
  final String fingerprint;
  final String createdAt;

  factory DebtPaymentRequestIntent.fromJson(Map<String, dynamic> json) {
    return DebtPaymentRequestIntent(
      requestId: json['request_id']?.toString() ?? '',
      fingerprint: json['fingerprint']?.toString() ?? '',
      createdAt: json['created_at']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'request_id': requestId,
    'fingerprint': fingerprint,
    'created_at': createdAt,
  };
}

/// Conserva el UUID de un pago hasta que el backend confirma su resultado.
///
/// Si PostgreSQL confirma el pago pero la respuesta se pierde, el siguiente
/// intento con los mismos datos reutiliza el mismo request_id y el backend
/// idempotente devuelve el resultado ya procesado sin insertar otro pago.
class DebtPaymentRequestStore {
  DebtPaymentRequestStore({String Function()? requestIdFactory})
    : _requestIdFactory = requestIdFactory ?? const Uuid().v4;

  static const _storageKey = 'debt_payment_request_intents_v1';
  static const _retention = Duration(days: 7);

  final String Function() _requestIdFactory;

  static String buildFingerprint({
    required String authUserId,
    required bool esCliente,
    required int deudaId,
    required double monto,
    required String metodoPago,
    required double saldoActual,
    required bool descontarDeCaja,
  }) {
    final userId = authUserId.trim();
    if (userId.isEmpty) {
      throw ArgumentError('El pago requiere un usuario autenticado.');
    }

    final metodo = metodoPago.trim().toLowerCase();
    final montoCentavos = (monto * 100).round();
    final saldoCentavos = (saldoActual * 100).round();

    return [
      'user=$userId',
      'tipo=${esCliente ? 'cliente' : 'proveedor'}',
      'deuda=$deudaId',
      'monto=$montoCentavos',
      'saldo=$saldoCentavos',
      'metodo=$metodo',
      'caja=${descontarDeCaja ? 1 : 0}',
    ].join('|');
  }

  Future<DebtPaymentRequestIntent> getOrCreate({
    required String fingerprint,
  }) async {
    if (fingerprint.trim().isEmpty) {
      throw ArgumentError('La huella del pago no puede estar vacía.');
    }

    final prefs = await SharedPreferences.getInstance();
    final intents = _decode(prefs.getString(_storageKey));
    _removeExpired(intents);

    final existing = intents[fingerprint];
    if (existing != null && existing.requestId.trim().isNotEmpty) {
      await _save(prefs, intents);
      return existing;
    }

    final intent = DebtPaymentRequestIntent(
      requestId: _requestIdFactory(),
      fingerprint: fingerprint,
      createdAt: AppTime.nowUtc().toIso8601String(),
    );
    intents[fingerprint] = intent;
    await _save(prefs, intents);
    return intent;
  }

  Future<void> markConfirmed(String fingerprint) async {
    final prefs = await SharedPreferences.getInstance();
    final intents = _decode(prefs.getString(_storageKey));
    if (intents.remove(fingerprint) != null) {
      await _save(prefs, intents);
    }
  }

  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }

  Map<String, DebtPaymentRequestIntent> _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return <String, DebtPaymentRequestIntent>{};
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, DebtPaymentRequestIntent>{};

      final result = <String, DebtPaymentRequestIntent>{};
      for (final entry in decoded.entries) {
        if (entry.value is! Map) continue;
        final intent = DebtPaymentRequestIntent.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
        if (intent.requestId.isEmpty || intent.fingerprint != entry.key) continue;
        result[entry.key.toString()] = intent;
      }
      return result;
    } catch (_) {
      // Un almacenamiento corrupto nunca debe reutilizar un request_id dudoso.
      return <String, DebtPaymentRequestIntent>{};
    }
  }

  void _removeExpired(Map<String, DebtPaymentRequestIntent> intents) {
    final cutoff = AppTime.nowUtc().subtract(_retention);
    intents.removeWhere((_, intent) {
      final createdAt = DateTime.tryParse(intent.createdAt)?.toUtc();
      return createdAt == null || createdAt.isBefore(cutoff);
    });
  }

  Future<void> _save(
    SharedPreferences prefs,
    Map<String, DebtPaymentRequestIntent> intents,
  ) async {
    if (intents.isEmpty) {
      await prefs.remove(_storageKey);
      return;
    }

    final encoded = <String, dynamic>{
      for (final entry in intents.entries) entry.key: entry.value.toJson(),
    };
    final ok = await prefs.setString(_storageKey, jsonEncode(encoded));
    if (!ok) {
      throw StateError(
        'No se pudo guardar la protección de idempotencia del pago.',
      );
    }
  }
}
