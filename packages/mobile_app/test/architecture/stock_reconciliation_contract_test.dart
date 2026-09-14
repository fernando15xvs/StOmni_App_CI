import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  late String sql;

  setUpAll(() {
    sql = repositoryFile('scripts/fase5_stock_reconciliation.sql').readAsStringSync();
  });

  test('conciliacion usa id como orden estable y no fecha', () {
    expect(
      sql,
      contains('ORDER BY m.producto_id, m.almacen_id, m.id DESC'),
    );
    expect(
      sql,
      isNot(contains('ORDER BY m.producto_id, m.almacen_id, m.fecha DESC')),
    );
  });

  test('conciliacion compara ultimo saldo contra inventario actual', () {
    expect(sql, contains('l.saldo IS DISTINCT FROM ia.cantidad::numeric'));
    expect(sql, contains("THEN 'diferencia'"));
    expect(sql, contains("THEN 'sin_kardex'"));
  });

  test('auditoria distingue negativos permitidos de prohibidos', () {
    expect(sql, contains('p.permitir_sin_stock'));
    expect(sql, contains('negativos_no_permitidos'));
  });

  test('script de conciliacion es estrictamente read-only', () {
    final writeStatement = RegExp(
      r'^\s*(UPDATE|INSERT|DELETE|TRUNCATE)\b',
      caseSensitive: false,
      multiLine: true,
    );

    expect(sql, isNot(contains(writeStatement)));
  });
}
