import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/business_assistant_gateway.dart';
import '../domain/business_assistant.dart';

class SupabaseBusinessAssistantGateway implements BusinessAssistantGateway {
  const SupabaseBusinessAssistantGateway(this.client);

  final SupabaseClient client;

  @override
  Future<BusinessAssistantSettings> getSettings() async {
    final raw = await client.rpc('get_business_assistant_settings_v1');
    return _decodeSettings(raw);
  }

  @override
  Future<BusinessAssistantSettings> updateSettings({
    required int expectedRevision,
    required bool enabled,
    required int maxResultItems,
    required int defaultPeriodDays,
  }) async {
    final raw = await client.rpc(
      'update_business_assistant_settings_v1',
      params: {
        'p_expected_revision': expectedRevision,
        'p_enabled': enabled,
        'p_max_result_items': maxResultItems,
        'p_default_period_days': defaultPeriodDays,
      },
    );
    return _decodeSettings(raw);
  }

  @override
  Future<BusinessAssistantContext> loadContext({
    required BusinessAssistantIntent intent,
    int? periodDays,
    String? branchId,
    int? limit,
  }) async {
    final raw = await client.rpc(
      'get_business_assistant_context_v1',
      params: {
        'p_intent': intent.databaseValue,
        'p_period_days': periodDays,
        'p_branch_id': branchId,
        'p_limit': limit,
      },
    );
    if (raw is! Map) {
      throw const FormatException('El contexto del asistente es inválido.');
    }
    final map = Map<String, dynamic>.from(raw);
    final generatedAt = DateTime.tryParse(
      map['generated_at']?.toString() ?? '',
    );
    final rawItems = map['items'];
    final parsedPeriod = map['period_days'] is num
        ? (map['period_days'] as num).toInt()
        : int.tryParse(map['period_days']?.toString() ?? '');
    if (generatedAt == null ||
        rawItems is! List ||
        parsedPeriod == null ||
        parsedPeriod < 1) {
      throw const FormatException(
        'Contrato de contexto del asistente incompleto.',
      );
    }
    return BusinessAssistantContext(
      intent: BusinessAssistantIntent.parse(map['intent']?.toString() ?? ''),
      periodDays: parsedPeriod,
      branchId: map['branch_id']?.toString(),
      branchName: map['branch_name']?.toString(),
      items: rawItems.map((item) {
        if (item is! Map) {
          throw const FormatException(
            'Elemento del contexto del asistente inválido.',
          );
        }
        return Map<String, dynamic>.from(item);
      }),
      note: map['note']?.toString(),
      generatedAt: generatedAt,
    );
  }

  BusinessAssistantSettings _decodeSettings(Object? raw) {
    if (raw is! Map)
      throw const FormatException('Configuración del asistente inválida.');
    final map = Map<String, dynamic>.from(raw);
    final maxItems = map['max_result_items'] is num
        ? (map['max_result_items'] as num).toInt()
        : int.tryParse(map['max_result_items']?.toString() ?? '');
    final period = map['default_period_days'] is num
        ? (map['default_period_days'] as num).toInt()
        : int.tryParse(map['default_period_days']?.toString() ?? '');
    final revision = map['revision'] is num
        ? (map['revision'] as num).toInt()
        : int.tryParse(map['revision']?.toString() ?? '');
    if (map['enabled'] is! bool ||
        maxItems == null ||
        period == null ||
        revision == null ||
        maxItems < 1 ||
        maxItems > 50 ||
        period < 1 ||
        period > 365 ||
        revision < 1) {
      throw const FormatException(
        'Contrato de configuración del asistente incompleto.',
      );
    }
    return BusinessAssistantSettings(
      enabled: map['enabled'] as bool,
      maxResultItems: maxItems,
      defaultPeriodDays: period,
      revision: revision,
    );
  }
}
