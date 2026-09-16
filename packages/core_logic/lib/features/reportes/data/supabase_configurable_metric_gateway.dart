import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../utils/app_time.dart';
import '../application/configurable_metrics_use_case.dart';
import '../domain/configurable_metric.dart';

class SupabaseConfigurableMetricGateway implements ConfigurableMetricGateway {
  const SupabaseConfigurableMetricGateway(this.client);

  final SupabaseClient client;

  @override
  Future<List<ConfigurableMetricDefinition>> listDefinitions() async {
    final raw = await client.rpc('list_business_metrics_v1');
    if (raw is! List)
      throw const FormatException('Las métricas son inválidas.');
    return raw.map(_decodeDefinition).toList(growable: false);
  }

  @override
  Future<List<ConfigurableMetricDefinition>> saveDefinitions(
    List<ConfigurableMetricDefinition> definitions,
  ) async {
    final raw = await client.rpc(
      'save_business_metrics_v1',
      params: {
        'p_definitions': definitions
            .map(
              (definition) => <String, dynamic>{
                'source': definition.source.databaseValue,
                'label': definition.label.trim(),
                'position': definition.position,
                'enabled': definition.enabled,
                'format': definition.format.databaseValue,
              },
            )
            .toList(growable: false),
      },
    );
    if (raw is! List)
      throw const FormatException('Las métricas guardadas son inválidas.');
    return raw.map(_decodeDefinition).toList(growable: false);
  }

  @override
  Future<ConfigurableDashboardSnapshot> loadDashboard({
    required DateTime start,
    required DateTime end,
    String? branchId,
  }) async {
    final raw = await client.rpc(
      'get_configurable_dashboard_v1',
      params: {
        'p_start': AppTime.toIsoLima(start),
        'p_end': AppTime.toIsoLima(end),
        'p_branch_id': branchId,
      },
    );
    if (raw is! Map) {
      throw const FormatException('El dashboard configurable es inválido.');
    }
    final map = Map<String, dynamic>.from(raw);
    final parsedStart = DateTime.tryParse(map['start']?.toString() ?? '');
    final parsedEnd = DateTime.tryParse(map['end']?.toString() ?? '');
    final rawMetrics = map['metrics'];
    if (parsedStart == null || parsedEnd == null || rawMetrics is! List) {
      throw const FormatException('Contrato de dashboard incompleto.');
    }

    final metrics = rawMetrics
        .map((entry) {
          if (entry is! Map) {
            throw const FormatException('Métrica de dashboard inválida.');
          }
          final metric = Map<String, dynamic>.from(entry);
          final available = metric['available'] == true;
          final rawValue = metric['value'];
          final value = rawValue == null
              ? null
              : rawValue is num
              ? rawValue.toDouble()
              : double.tryParse(rawValue.toString());
          if (available && value == null) {
            throw const FormatException(
              'Valor de métrica disponible inválido.',
            );
          }
          return MetricValue(
            definition: _decodeDefinition(metric),
            value: value,
            available: available,
            note: metric['note']?.toString(),
          );
        })
        .toList(growable: false);

    return ConfigurableDashboardSnapshot(
      start: parsedStart,
      end: parsedEnd,
      branchId: map['branch_id']?.toString(),
      branchName: map['branch_name']?.toString(),
      scopeNote: map['scope_note']?.toString(),
      metrics: metrics,
    );
  }

  ConfigurableMetricDefinition _decodeDefinition(Object? raw) {
    if (raw is! Map)
      throw const FormatException('Definición de métrica inválida.');
    final map = Map<String, dynamic>.from(raw);
    final position = map['position'] is num
        ? (map['position'] as num).toInt()
        : int.tryParse(map['position']?.toString() ?? '');
    final label = map['label']?.toString().trim() ?? '';
    if (position == null ||
        position < 0 ||
        label.isEmpty ||
        map['enabled'] is! bool && !map.containsKey('available')) {
      throw const FormatException('Contrato de métrica incompleto.');
    }
    return ConfigurableMetricDefinition(
      source: MetricSource.parse(map['source']?.toString() ?? ''),
      label: label,
      position: position,
      enabled: map['enabled'] is bool ? map['enabled'] as bool : true,
      format: MetricFormat.parse(map['format']?.toString() ?? ''),
    );
  }
}
