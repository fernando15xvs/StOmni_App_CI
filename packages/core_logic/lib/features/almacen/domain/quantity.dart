import 'dart:math' as math;

/// Cantidad decimal de precisión fija representada internamente en unidades
/// menores enteras. Evita que las reglas de negocio dependan de comparaciones
/// directas entre doubles para decidir si una cantidad es válida.
class FixedQuantity implements Comparable<FixedQuantity> {
  const FixedQuantity._(this.minorUnits, this.scale);

  factory FixedQuantity.fromMinorUnits(int minorUnits, {required int scale}) {
    _validateScale(scale);
    return FixedQuantity._(minorUnits, scale);
  }

  factory FixedQuantity.fromDouble(double value, {required int scale}) {
    _validateScale(scale);
    if (!value.isFinite) {
      throw ArgumentError.value(value, 'value', 'La cantidad debe ser finita.');
    }
    final factor = _factor(scale);
    final scaled = value * factor;
    final rounded = scaled.round();
    final tolerance = math.max(1.0, scaled.abs()) * 1e-9;
    if ((scaled - rounded).abs() > tolerance) {
      throw ArgumentError.value(
        value,
        'value',
        'La cantidad excede la precisión permitida de $scale decimales.',
      );
    }
    return FixedQuantity._(rounded, scale);
  }

  final int minorUnits;
  final int scale;

  static const int maxScale = 6;

  bool get isZero => minorUnits == 0;
  bool get isPositive => minorUnits > 0;
  bool get isNegative => minorUnits < 0;
  bool get isInteger => scale == 0 || minorUnits % _factor(scale) == 0;

  double get value => minorUnits / _factor(scale);

  FixedQuantity rescale(int newScale) {
    _validateScale(newScale);
    if (newScale == scale) return this;
    if (newScale > scale) {
      return FixedQuantity._(
        minorUnits * _factor(newScale - scale),
        newScale,
      );
    }
    final divisor = _factor(scale - newScale);
    if (minorUnits % divisor != 0) {
      throw StateError(
        'La cantidad no puede reducirse a $newScale decimales sin perder precisión.',
      );
    }
    return FixedQuantity._(minorUnits ~/ divisor, newScale);
  }

  FixedQuantity add(FixedQuantity other) {
    final targetScale = scale >= other.scale ? scale : other.scale;
    final left = rescale(targetScale);
    final right = other.rescale(targetScale);
    return FixedQuantity._(left.minorUnits + right.minorUnits, targetScale);
  }

  FixedQuantity subtract(FixedQuantity other) {
    final targetScale = scale >= other.scale ? scale : other.scale;
    final left = rescale(targetScale);
    final right = other.rescale(targetScale);
    return FixedQuantity._(left.minorUnits - right.minorUnits, targetScale);
  }

  String format() {
    if (scale == 0) return minorUnits.toString();
    final negative = minorUnits < 0;
    final absolute = minorUnits.abs();
    final factor = _factor(scale);
    final integer = absolute ~/ factor;
    final decimals = (absolute % factor).toString().padLeft(scale, '0');
    final trimmed = decimals.replaceFirst(RegExp(r'0+$'), '');
    final text = trimmed.isEmpty ? '$integer' : '$integer.$trimmed';
    return negative ? '-$text' : text;
  }

  @override
  int compareTo(FixedQuantity other) {
    final targetScale = scale >= other.scale ? scale : other.scale;
    return rescale(targetScale).minorUnits.compareTo(
      other.rescale(targetScale).minorUnits,
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is! FixedQuantity) return false;
    final targetScale = scale >= other.scale ? scale : other.scale;
    return rescale(targetScale).minorUnits ==
        other.rescale(targetScale).minorUnits;
  }

  @override
  int get hashCode {
    var normalizedMinor = minorUnits;
    var normalizedScale = scale;
    while (normalizedScale > 0 && normalizedMinor % 10 == 0) {
      normalizedMinor ~/= 10;
      normalizedScale--;
    }
    return Object.hash(normalizedMinor, normalizedScale);
  }

  @override
  String toString() => format();

  static void _validateScale(int scale) {
    if (scale < 0 || scale > maxScale) {
      throw ArgumentError.value(
        scale,
        'scale',
        'La precisión debe estar entre 0 y $maxScale decimales.',
      );
    }
  }

  static int _factor(int scale) {
    var result = 1;
    for (var i = 0; i < scale; i++) {
      result *= 10;
    }
    return result;
  }
}
