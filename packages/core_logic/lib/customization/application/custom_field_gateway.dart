import '../domain/custom_field_definition.dart';

abstract interface class CustomFieldGateway {
  Future<List<CustomFieldDefinition>> listDefinitions(
    CustomFieldEntityType entityType, {
    bool includeInactive = false,
  });

  Future<CustomFieldDefinition> saveDefinition(
    CustomFieldDefinition definition,
  );

  Future<Map<String, dynamic>> setValues({
    required CustomFieldEntityType entityType,
    required int entityId,
    required Map<String, dynamic> values,
  });
}
