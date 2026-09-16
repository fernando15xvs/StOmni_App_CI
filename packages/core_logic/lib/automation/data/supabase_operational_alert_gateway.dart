import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/app_time.dart';
import '../application/operational_alert_gateway.dart';
import '../domain/operational_alert.dart';

class SupabaseOperationalAlertGateway implements OperationalAlertGateway {
  const SupabaseOperationalAlertGateway(this.client);

  final SupabaseClient client;

  @override
  Future<int> refresh() async {
    final raw = await client.rpc('refresh_operational_alerts_v1');
    if (raw is! Map) {
      throw const FormatException('Respuesta de alertas inválida.');
    }
    final map = Map<String, dynamic>.from(raw);
    final detected = _int(map['detected']);
    if (map['success'] != true || detected == null || detected < 0) {
      throw const FormatException(
        'No se pudo confirmar el refresco de alertas.',
      );
    }
    return detected;
  }

  @override
  Future<List<OperationalAlert>> list({
    OperationalAlertStatus? status,
    int limit = 100,
  }) async {
    final raw = await client.rpc(
      'list_operational_alerts_v1',
      params: {'p_status': status?.databaseValue, 'p_limit': limit},
    );
    if (raw is! List) {
      throw const FormatException('El listado de alertas es inválido.');
    }
    return raw.map(_decode).toList(growable: false);
  }

  @override
  Future<void> acknowledge(String alertId) async {
    final raw = await client.rpc(
      'acknowledge_operational_alert_v1',
      params: {'p_alert_id': alertId},
    );
    _expectStatus(raw, OperationalAlertStatus.acknowledged);
  }

  @override
  Future<String> createTask({
    required String title,
    required String message,
    DateTime? dueAt,
    OperationalAlertSeverity severity = OperationalAlertSeverity.info,
  }) async {
    final raw = await client.rpc(
      'create_operational_task_v1',
      params: {
        'p_title': title.trim(),
        'p_message': message.trim(),
        'p_due_at': dueAt == null ? null : AppTime.toIsoLima(dueAt),
        'p_severity': severity.databaseValue,
      },
    );
    if (raw is! Map) throw const FormatException('Tarea operativa inválida.');
    final id = raw['id']?.toString().trim() ?? '';
    if (id.isEmpty || raw['status']?.toString() != 'open') {
      throw const FormatException(
        'El servidor no confirmó la tarea operativa.',
      );
    }
    return id;
  }

  @override
  Future<void> resolve(String alertId) async {
    final raw = await client.rpc(
      'resolve_operational_alert_v1',
      params: {'p_alert_id': alertId},
    );
    _expectStatus(raw, OperationalAlertStatus.resolved);
  }

  @override
  Future<OperationalAlertSettings> getSettings() async {
    final raw = await client.rpc('get_operational_alert_settings_v1');
    return _decodeSettings(raw);
  }

  @override
  Future<OperationalAlertSettings> updateSettings(
    OperationalAlertSettings current,
    OperationalAlertSettings next,
  ) async {
    final raw = await client.rpc(
      'update_operational_alert_settings_v1',
      params: {
        'p_expected_revision': current.revision,
        'p_settings': _encodeSettings(next),
      },
    );
    return _decodeSettings(raw);
  }

  OperationalAlert _decode(Object? raw) {
    if (raw is! Map) throw const FormatException('Alerta inválida.');
    final map = Map<String, dynamic>.from(raw);
    final id = map['id']?.toString().trim() ?? '';
    final title = map['title']?.toString().trim() ?? '';
    final message = map['message']?.toString().trim() ?? '';
    final first = DateTime.tryParse(map['first_detected_at']?.toString() ?? '');
    final last = DateTime.tryParse(map['last_detected_at']?.toString() ?? '');
    final metadata = map['metadata'];
    if (id.isEmpty ||
        title.isEmpty ||
        message.isEmpty ||
        first == null ||
        last == null ||
        metadata is! Map) {
      throw const FormatException('Contrato de alerta incompleto.');
    }
    return OperationalAlert(
      id: id,
      category: OperationalAlertCategory.parse(
        map['category']?.toString() ?? '',
      ),
      severity: OperationalAlertSeverity.parse(
        map['severity']?.toString() ?? '',
      ),
      status: OperationalAlertStatus.parse(map['status']?.toString() ?? ''),
      entityType: _text(map['entity_type']),
      entityId: _text(map['entity_id']),
      title: title,
      message: message,
      dueAt: _date(map['due_at']),
      firstDetectedAt: first,
      lastDetectedAt: last,
      acknowledgedAt: _date(map['acknowledged_at']),
      resolvedAt: _date(map['resolved_at']),
      metadata: Map<String, dynamic>.from(metadata),
    );
  }

  OperationalAlertSettings _decodeSettings(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Configuración de alertas inválida.');
    }
    final map = Map<String, dynamic>.from(raw);
    bool boolField(String key) {
      final value = map[key];
      if (value is! bool) throw FormatException('Campo $key inválido.');
      return value;
    }

    int intField(String key) {
      final value = _int(map[key]);
      if (value == null) throw FormatException('Campo $key inválido.');
      return value;
    }

    return OperationalAlertSettings(
      lowStockEnabled: boolField('low_stock_enabled'),
      expiryEnabled: boolField('expiry_enabled'),
      expiryWarningDays: intField('expiry_warning_days'),
      debtOverdueEnabled: boolField('debt_overdue_enabled'),
      debtOverdueDays: intField('debt_overdue_days'),
      purchasePendingEnabled: boolField('purchase_pending_enabled'),
      purchasePendingDays: intField('purchase_pending_days'),
      cashSessionEnabled: boolField('cash_session_enabled'),
      cashSessionMaxHours: intField('cash_session_max_hours'),
      revision: intField('revision'),
    );
  }

  Map<String, dynamic> _encodeSettings(OperationalAlertSettings value) => {
    'low_stock_enabled': value.lowStockEnabled,
    'expiry_enabled': value.expiryEnabled,
    'expiry_warning_days': value.expiryWarningDays,
    'debt_overdue_enabled': value.debtOverdueEnabled,
    'debt_overdue_days': value.debtOverdueDays,
    'purchase_pending_enabled': value.purchasePendingEnabled,
    'purchase_pending_days': value.purchasePendingDays,
    'cash_session_enabled': value.cashSessionEnabled,
    'cash_session_max_hours': value.cashSessionMaxHours,
  };

  void _expectStatus(Object? raw, OperationalAlertStatus expected) {
    if (raw is! Map || raw['status']?.toString() != expected.databaseValue) {
      throw const FormatException(
        'El servidor no confirmó el cambio de alerta.',
      );
    }
  }

  int? _int(Object? value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');

  String? _text(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  DateTime? _date(Object? value) =>
      value == null ? null : DateTime.tryParse(value.toString());
}
