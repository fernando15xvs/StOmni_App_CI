import 'commercial_presentation.dart';
import 'quantity.dart';

/// Configuración persistida de las unidades comerciales de un producto.
///
/// El backend histórico conserva enteros. Si la unidad base admite decimales,
/// [storageScale] representa la cantidad en unidades menores enteras: por
/// ejemplo 10.500 kg se almacena como 10500 cuando la precisión base es 3.
class ProductUnitConfiguration {
  ProductUnitConfiguration({required this.revision, required this.profile}) {
    if (revision < 1) throw ArgumentError('La revisión debe ser positiva.');
    PresentationPolicy.validate(profile);
  }

  final int revision;
  final ProductUnitProfile profile;

  int get storagePrecision => profile.baseUnit.quantityPrecision;

  int get storageScale {
    var result = 1;
    for (var i = 0; i < storagePrecision; i++) {
      result *= 10;
    }
    return result;
  }

  bool get usesScaledStorage => storageScale > 1;

  int toStoredBaseQuantity(double baseQuantity) {
    if (!baseQuantity.isFinite || baseQuantity < 0) {
      throw ArgumentError.value(baseQuantity, 'baseQuantity');
    }
    final stored = FixedQuantity.fromDouble(
      baseQuantity,
      scale: storagePrecision,
    ).minorUnits;
    if (stored.abs() > PresentationPolicy.maxStoredQuantity) {
      throw ArgumentError('La cantidad excede el rango del inventario.');
    }
    return stored;
  }

  double fromStoredBaseQuantity(num storedQuantity) {
    final value = storedQuantity.toDouble();
    if (!value.isFinite || value != value.roundToDouble()) {
      throw ArgumentError.value(storedQuantity, 'storedQuantity');
    }
    return FixedQuantity.fromMinorUnits(
      value.toInt(),
      scale: storagePrecision,
    ).value;
  }

  int storedQuantityFor(String code, double commercialQuantity) {
    return toStoredBaseQuantity(
      PresentationPolicy.baseQuantity(profile, code, commercialQuantity),
    );
  }
}

class PresentationPolicy {
  const PresentationPolicy._();

  static const maxPresentations = 20;
  static const maxFactor = 1000000000000.0;
  static const maxStoredQuantity = 2147483647;
  static final RegExp _controlCharacters = RegExp(r'[\u0000-\u001f\u007f]');

  static void validate(ProductUnitProfile profile) {
    if (profile.presentations.isEmpty ||
        profile.presentations.length > maxPresentations) {
      throw ArgumentError(
        'Se permiten entre 1 y $maxPresentations presentaciones por producto.',
      );
    }
    for (final unit in profile.presentations) {
      final singular = unit.singularLabel.trim();
      final plural = unit.pluralLabel.trim();
      if (!RegExp(r'^[a-z][a-z0-9_]{0,39}$').hasMatch(unit.code) ||
          singular.isEmpty ||
          plural.isEmpty ||
          singular.length > 60 ||
          plural.length > 60 ||
          _controlCharacters.hasMatch(singular) ||
          _controlCharacters.hasMatch(plural)) {
        throw ArgumentError(
          'El código o las etiquetas de la presentación no son válidos.',
        );
      }
      if (!unit.baseQuantity.isFinite ||
          unit.baseQuantity <= 0 ||
          unit.baseQuantity > maxFactor ||
          unit.quantityPrecision < 0 ||
          unit.quantityPrecision > FixedQuantity.maxScale) {
        throw ArgumentError(
          'La equivalencia o precisión de la presentación no es válida.',
        );
      }
    }

    final basePrecision = profile.baseUnit.quantityPrecision;
    for (final unit in profile.presentations) {
      final minimumCommercial = 1 / _pow10(unit.quantityPrecision);
      final minimumBase = minimumCommercial * unit.baseQuantity;
      try {
        FixedQuantity.fromDouble(minimumBase, scale: basePrecision);
      } on ArgumentError {
        throw ArgumentError(
          'La presentación ${unit.code} requiere más precisión que la unidad base.',
        );
      }
    }
  }

  static double baseQuantity(
    ProductUnitProfile profile,
    String code,
    double quantity,
  ) {
    validate(profile);
    final presentation = profile.find(code);
    if (presentation == null) {
      throw ArgumentError('La presentación no pertenece al producto.');
    }
    final commercial = presentation.commercialQuantity(quantity);
    if (!commercial.isPositive) {
      throw ArgumentError('La cantidad debe ser positiva.');
    }
    final base = commercial.value * presentation.baseQuantity;
    if (!base.isFinite || base <= 0 || base > maxFactor) {
      throw ArgumentError('La cantidad base excede el rango permitido.');
    }
    FixedQuantity.fromDouble(base, scale: profile.baseUnit.quantityPrecision);
    return base;
  }

  static int _pow10(int precision) {
    var result = 1;
    for (var i = 0; i < precision; i++) {
      result *= 10;
    }
    return result;
  }
}

/// Contrato de compatibilidad de perfiles v1 no escalados.
class IntegerPresentationPolicy {
  const IntegerPresentationPolicy._();

  static const maxQuantity = PresentationPolicy.maxStoredQuantity;

  static void validate(ProductUnitProfile profile) {
    PresentationPolicy.validate(profile);
    for (final unit in profile.presentations) {
      if (unit.allowsFractionalSale ||
          unit.quantityPrecision != 0 ||
          unit.baseQuantity != unit.baseQuantity.roundToDouble() ||
          unit.baseQuantity > maxQuantity) {
        throw ArgumentError(
          'Este perfil requiere almacenamiento escalado y no pertenece al contrato v1.',
        );
      }
    }
  }

  static int baseQuantity(
    ProductUnitProfile profile,
    String code,
    double quantity,
  ) {
    validate(profile);
    if (!quantity.isFinite ||
        quantity <= 0 ||
        quantity != quantity.roundToDouble() ||
        quantity > maxQuantity) {
      throw ArgumentError(
        'La cantidad debe ser un entero positivo dentro del rango del inventario.',
      );
    }
    final value = PresentationPolicy.baseQuantity(profile, code, quantity);
    if (value <= 0 ||
        value > maxQuantity ||
        value != value.roundToDouble()) {
      throw ArgumentError('La cantidad base excede el rango del inventario.');
    }
    return value.toInt();
  }
}
