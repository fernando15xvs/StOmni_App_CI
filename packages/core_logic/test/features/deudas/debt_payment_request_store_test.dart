import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('reutiliza request_id mientras el pago no fue confirmado', () async {
    var sequence = 0;
    final store = DebtPaymentRequestStore(
      requestIdFactory: () => 'request-${++sequence}',
    );
    final fingerprint = DebtPaymentRequestStore.buildFingerprint(
      authUserId: 'user-a',
      esCliente: true,
      deudaId: 10,
      monto: 100,
      metodoPago: 'Efectivo',
      saldoActual: 250,
      descontarDeCaja: false,
    );

    final first = await store.getOrCreate(fingerprint: fingerprint);
    final retry = await store.getOrCreate(fingerprint: fingerprint);

    expect(first.requestId, 'request-1');
    expect(retry.requestId, first.requestId);
    expect(sequence, 1);
  });

  test('despues de confirmacion un pago posterior obtiene otro UUID', () async {
    var sequence = 0;
    final store = DebtPaymentRequestStore(
      requestIdFactory: () => 'request-${++sequence}',
    );
    final fingerprint = DebtPaymentRequestStore.buildFingerprint(
      authUserId: 'user-a',
      esCliente: false,
      deudaId: 22,
      monto: 40,
      metodoPago: 'Yape',
      saldoActual: 100,
      descontarDeCaja: false,
    );

    final first = await store.getOrCreate(fingerprint: fingerprint);
    await store.markConfirmed(fingerprint);
    final second = await store.getOrCreate(fingerprint: fingerprint);

    expect(first.requestId, 'request-1');
    expect(second.requestId, 'request-2');
  });

  test('saldo, monto, metodo y usuario forman parte de la huella', () {
    String fingerprint({
      String user = 'user-a',
      double monto = 50,
      double saldo = 100,
      String metodo = 'Efectivo',
    }) {
      return DebtPaymentRequestStore.buildFingerprint(
        authUserId: user,
        esCliente: true,
        deudaId: 1,
        monto: monto,
        metodoPago: metodo,
        saldoActual: saldo,
        descontarDeCaja: false,
      );
    }

    final base = fingerprint();
    expect(fingerprint(saldo: 50), isNot(base));
    expect(fingerprint(monto: 25), isNot(base));
    expect(fingerprint(metodo: 'Plin'), isNot(base));
    expect(fingerprint(user: 'user-b'), isNot(base));
  });

  test('normaliza centavos y metodo para un retry equivalente', () {
    final first = DebtPaymentRequestStore.buildFingerprint(
      authUserId: ' user-a ',
      esCliente: true,
      deudaId: 5,
      monto: 10.001,
      metodoPago: ' EFECTIVO ',
      saldoActual: 80.001,
      descontarDeCaja: false,
    );
    final retry = DebtPaymentRequestStore.buildFingerprint(
      authUserId: 'user-a',
      esCliente: true,
      deudaId: 5,
      monto: 10.00,
      metodoPago: 'efectivo',
      saldoActual: 80.00,
      descontarDeCaja: false,
    );

    expect(retry, first);
  });
}
