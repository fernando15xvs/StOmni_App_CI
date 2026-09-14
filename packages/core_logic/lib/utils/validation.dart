import 'package:flutter/services.dart';

class AppValidation {
  static final numericFormatter = FilteringTextInputFormatter.allow(
    RegExp(r'^[0-9]+$'),
  );
  static final decimalFormatter = FilteringTextInputFormatter.allow(
    RegExp(r'^\d+(?:\.\d{0,2})?$'),
  );

  static String? positiveInt(String? value, String fieldName) {
    if (value == null || value.trim().isEmpty) {
      return '$fieldName es obligatorio';
    }
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 0) {
      return '$fieldName debe ser un número entero positivo';
    }
    return null;
  }

  static String? positiveDecimal(String? value, String fieldName) {
    if (value == null || value.trim().isEmpty) {
      return '$fieldName es obligatorio';
    }
    final parsed = double.tryParse(value.trim());
    if (parsed == null || parsed < 0) {
      return '$fieldName debe ser un número positivo';
    }
    return null;
  }
}
