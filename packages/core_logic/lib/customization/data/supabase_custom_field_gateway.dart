import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/custom_field_gateway.dart';
import '../domain/custom_field_definition.dart';

class SupabaseCustomFieldGateway implements CustomFieldGateway {
  const SupabaseCustomFieldGateway(this.client);
  final SupabaseClient client;

  @override
  Future<List<CustomFieldDefinition>> listDefinitions(
    CustomFieldEntityType entityType, {
    bool includeInactive = false,
  }) async {
    final raw = await client.rpc(
      'list_custom_field_definitions_v1',
      params: {
        'p_entity_type': entityType.code,
        'p_include_inactive': includeInactive,
      },
    );
    if (raw is! List) {
      throw const FormatException(
        'Respuesta de campos configurables inválida.',
      );
    }
    return raw
        .map((row) {
          if (row is! Map) {
            throw const FormatException('Definición configurable inválida.');
          }
          return CustomFieldDefinition.fromMap(Map<String, dynamic>.from(row));
        })
        .toList(growable: false);
  }

  @override
  Future<CustomFieldDefinition> saveDefinition(
    CustomFieldDefinition definition,
  ) async {
    final raw = await client.rpc(
      'upsert_custom_field_definition_v1',
      params: {
        'p_definition_id': definition.id,
        'p_entity_type': definition.entityType.code,
        'p_code': definition.code,
        'p_label': definition.label,
        'p_value_type': definition.valueType.code,
        'p_required': definition.required,
        'p_item_types': definition.itemTypes
            .map((value) => value.code)
            .toList(),
        'p_options': definition.options,
        'p_validation': definition.validation.toMap(),
        'p_sort_order': definition.sortOrder,
        'p_status': definition.active ? 'active' : 'inactive',
      },
    );
    if (raw is! Map) {
      throw const FormatException(
        'Respuesta de definición configurable inválida.',
      );
    }
    return CustomFieldDefinition.fromMap(Map<String, dynamic>.from(raw));
  }

  @override
  Future<Map<String, dynamic>> setValues({
    required CustomFieldEntityType entityType,
    required int entityId,
    required Map<String, dynamic> values,
  }) async {
    final raw = await client.rpc(
      'set_entity_custom_fields_v1',
      params: {
        'p_entity_type': entityType.code,
        'p_entity_id': entityId,
        'p_values': values,
      },
    );
    if (raw is! Map) {
      throw const FormatException(
        'Respuesta de valores configurables inválida.',
      );
    }
    final map = Map<String, dynamic>.from(raw);
    final customFields = map['custom_fields'];
    if (customFields is! Map) {
      throw const FormatException('Valores configurables inválidos.');
    }
    return Map<String, dynamic>.from(customFields);
  }
}
