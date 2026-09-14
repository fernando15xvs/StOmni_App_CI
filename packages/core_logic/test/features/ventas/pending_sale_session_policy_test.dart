import 'package:flutter_test/flutter_test.dart';

import 'package:core_logic/core_logic.dart';

void main() {
  test('venta nueva solo sincroniza con la sesión que la creó', () {
    expect(
      PendingSaleSessionPolicy.puedeSincronizar(
        authUserIdOrigen: 'user-a',
        authUserIdActual: 'user-a',
      ),
      isTrue,
    );
    expect(
      PendingSaleSessionPolicy.puedeSincronizar(
        authUserIdOrigen: 'user-a',
        authUserIdActual: 'user-b',
      ),
      isFalse,
    );
    expect(
      PendingSaleSessionPolicy.puedeSincronizar(
        authUserIdOrigen: 'user-a',
        authUserIdActual: null,
      ),
      isFalse,
    );
  });

  test('venta histórica sin auth_user_id conserva compatibilidad', () {
    expect(
      PendingSaleSessionPolicy.puedeSincronizar(
        authUserIdOrigen: null,
        authUserIdActual: 'user-b',
      ),
      isTrue,
    );
    expect(
      PendingSaleSessionPolicy.puedeSincronizar(
        authUserIdOrigen: '',
        authUserIdActual: null,
      ),
      isTrue,
    );
  });
}
