import '../../features/catalogo/domain/catalog_item_type.dart';

enum CustomFieldEntityType {
  catalogItem('catalog_item'),
  customer('customer'),
  supplier('supplier');

  const CustomFieldEntityType(this.code);
  final String code;

  static CustomFieldEntityType fromCode(Object? raw) {
    final code = raw?.toString().trim().toLowerCase();
    for (final value in values) {
      if (value.code == code) return value;
    }
    throw FormatException('Entidad de campo configurable desconocida: $code');
  }
}

enum CustomFieldValueType {
  text('text'),
  number('number'),
  boolean('boolean'),
  date('date'),
  select('select'),
  multiselect('multiselect');

  const CustomFieldValueType(this.code);
  final String code;

  static CustomFieldValueType fromCode(Object? raw) {
    final code = raw?.toString().trim().toLowerCase();
    for (final value in values) {
      if (value.code == code) return value;
    }
    throw FormatException('Tipo de campo configurable desconocido: $code');
  }
}

class CustomFieldValidation {
  const CustomFieldValidation({
    this.min,
    this.max,
    this.minLength,
    this.maxLength,
  });

  final num? min;
  final num? max;
  final int? minLength;
  final int? maxLength;

  factory CustomFieldValidation.fromMap(Map<String, dynamic> map) {
    int? integer(Object? value) {
      if (value == null) return null;
      if (value is! num || value != value.roundToDouble()) {
        throw const FormatException('Longitud de validación inválida.');
      }
      return value.toInt();
    }

    final allowed = {'min', 'max', 'min_length', 'max_length'};
    if (map.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Regla configurable no soportada.');
    }
    return CustomFieldValidation(
      min: map['min'] as num?,
      max: map['max'] as num?,
      minLength: integer(map['min_length']),
      maxLength: integer(map['max_length']),
    );
  }

  Map<String, dynamic> toMap() => {
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        if (minLength != null) 'min_length': minLength,
        if (maxLength != null) 'max_length': maxLength,
      };
}

class CustomFieldDefinition {
  CustomFieldDefinition({
    this.id,
    required this.entityType,
    required this.code,
    required this.label,
    required this.valueType,
    required this.required,
    Iterable<CatalogItemType> itemTypes = const [],
    Iterable<String> options = const [],
    this.validation = const CustomFieldValidation(),
    this.sortOrder = 0,
    this.active = true,
  })  : itemTypes = List<CatalogItemType>.unmodifiable(itemTypes),
        options = List<String>.unmodifiable(options);

  final String? id;
  final CustomFieldEntityType entityType;
  final String code;
  final String label;
  final CustomFieldValueType valueType;
  final bool required;
  final List<CatalogItemType> itemTypes;
  final List<String> options;
  final CustomFieldValidation validation;
  final int sortOrder;
  final bool active;

  bool appliesTo(CatalogItemType itemType) =>
      entityType != CustomFieldEntityType.catalogItem ||
      itemTypes.isEmpty ||
      itemTypes.contains(itemType);

  factory CustomFieldDefinition.fromMap(Map<String, dynamic> map) {
    final rawItems = map['item_types'];
    final rawOptions = map['options'];
    final rawValidation = map['validation'];
    if (rawItems is! List || rawOptions is! List || rawValidation is! Map) {
      throw const FormatException('Definición de campo configurable inválida.');
    }
    final id = map['id']?.toString().trim();
    final code = map['code']?.toString().trim() ?? '';
    final label = map['label']?.toString().trim() ?? '';
    final sortOrder = (map['sort_order'] as num?)?.toInt();
    if (id == null || id.isEmpty || code.isEmpty || label.isEmpty || sortOrder == null) {
      throw const FormatException('Definición de campo configurable incompleta.');
    }
    return CustomFieldDefinition(
      id: id,
      entityType: CustomFieldEntityType.fromCode(map['entity_type']),
      code: code,
      label: label,
      valueType: CustomFieldValueType.fromCode(map['value_type']),
      required: map['required'] == true,
      itemTypes: rawItems.map(CatalogItemType.fromCode),
      options: rawOptions.map((value) => value.toString()),
      validation: CustomFieldValidation.fromMap(
        Map<String, dynamic>.from(rawValidation),
      ),
      sortOrder: sortOrder,
      active: map['status']?.toString() == 'active',
    );
  }
}