import 'dart:convert';

import '../domain/commercial_presentation.dart';
import '../domain/product_unit_configuration.dart';

class ProductUnitConfigurationMapper {
  const ProductUnitConfigurationMapper._();

  static ProductUnitConfiguration? decodeNullable(Object? raw) {
    if (raw == null) return null;
    final value = raw is String ? jsonDecode(raw) : raw;
    if (value is! Map ||
        value['revision'] is! num ||
        value['revision'] != (value['revision'] as num).round() ||
        value['revision'] <= 0 ||
        value['profile'] is! Map) {
      throw const FormatException('La configuración de unidades está dañada.');
    }
    return ProductUnitConfiguration(
      revision: (value['revision'] as num).toInt(),
      profile: decodeProfile(
        Map<String, dynamic>.from(value['profile'] as Map),
      ),
    );
  }

  static ProductUnitProfile decodeProfile(Map<String, dynamic> value) {
    final rows = value['presentations'];
    final version = value['schema_version'];
    if (version != 2 ||
        rows is! List ||
        value['base_code'] is! String) {
      throw const FormatException('El perfil de unidades no es compatible.');
    }
    final units = rows
        .map((row) {
          if (row is! Map ||
              row['code'] is! String ||
              row['singular'] is! String ||
              row['plural'] is! String ||
              row['factor'] is! num ||
              row['fractional'] is! bool ||
              CommercialPresentation.normalizeCode(row['code'] as String) !=
                  row['code']) {
            throw const FormatException('La presentación está dañada.');
          }
          final precision = row['precision'];
          if (precision is! num || precision != precision.round()) {
            throw const FormatException(
              'La precisión de la presentación está dañada.',
            );
          }
          final fiscalRaw = row['fiscal_unit_code'];
          if (fiscalRaw != null && fiscalRaw is! String) {
            throw const FormatException(
              'El código fiscal de la presentación está dañado.',
            );
          }
          try {
            return CommercialPresentation(
              code: row['code'] as String,
              singularLabel: (row['singular'] as String).trim(),
              pluralLabel: (row['plural'] as String).trim(),
              baseQuantity: (row['factor'] as num).toDouble(),
              fiscalUnitCode: fiscalRaw as String?,
              quantityPrecision: precision.toInt(),
            );
          } on ArgumentError catch (error) {
            throw FormatException(
              error.message?.toString() ?? 'Presentación inválida.',
            );
          }
        })
        .toList(growable: false);
    final base = units.where((unit) => unit.code == value['base_code']);
    if (base.length != 1) {
      throw const FormatException('La unidad base no es válida.');
    }
    final profile = ProductUnitProfile(
      baseUnit: base.single,
      presentations: units,
    );
    PresentationPolicy.validate(profile);
    return profile;
  }

  static Map<String, dynamic> encode(ProductUnitConfiguration value) => {
    'revision': value.revision,
    'profile': encodeProfile(value.profile),
  };

  static Map<String, dynamic> encodeProfile(ProductUnitProfile profile) {
    PresentationPolicy.validate(profile);
    return {
      'schema_version': 2,
      'base_code': profile.baseUnit.code,
      'presentations': profile.presentations
          .map(
            (unit) => <String, dynamic>{
              'code': unit.code,
              'singular': unit.singularLabel.trim(),
              'plural': unit.pluralLabel.trim(),
              'factor': unit.baseQuantity,
              'fractional': unit.allowsFractionalSale,
              'precision': unit.quantityPrecision,
              if (unit.fiscalUnitCode != null)
                'fiscal_unit_code': unit.fiscalUnitCode,
            },
          )
          .toList(growable: false),
    };
  }
}
