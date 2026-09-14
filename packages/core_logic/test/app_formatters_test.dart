import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppFormatters', () {
    test('formats currency values in Peruvian Soles', () {
      expect(AppFormatters.currency(1234.5), 'S/ 1,234.50');
      expect(AppFormatters.currency(10), 'S/ 10.00');
    });

    test('parses dynamic values safely', () {
      expect(AppFormatters.toDouble('12.5'), 12.5);
      expect(AppFormatters.toInt('12'), 12);
      expect(AppFormatters.toInt(null), 0);
    });
  });
}
