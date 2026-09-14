import 'package:flutter_test/flutter_test.dart';
import 'package:core_logic/core_logic.dart';

void main() {
  group('AppRoles', () {
    test('normaliza únicamente los roles técnicos permitidos', () {
      expect(AppRoles.normalize('ADMIN'), AppRoles.admin);
      expect(AppRoles.normalize(' operador '), AppRoles.operador);
      expect(AppRoles.normalize('administrador'), isNull);
      expect(AppRoles.normalize('vendedor'), isNull);
      expect(AppRoles.normalize('almacenero'), isNull);
      expect(AppRoles.normalize(null), isNull);
    });

    test('identifica admin y operador correctamente', () {
      expect(AppRoles.isAdmin('admin'), isTrue);
      expect(AppRoles.isAdmin('operador'), isFalse);
      expect(AppRoles.isOperador('operador'), isTrue);
      expect(AppRoles.isOperador('admin'), isFalse);
    });
  });
}
