import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  bool esAgotado({required int anterior, required int actual}) {
    return anterior > 0 && actual <= 0;
  }

  bool esStockBajo({
    required int anterior,
    required int actual,
    required int minimo,
  }) {
    return !esAgotado(anterior: anterior, actual: actual) &&
        anterior > minimo &&
        actual <= minimo &&
        actual > 0;
  }

  test('alerta de stock evalua el delta total al final de la transaccion', () {
    final sql = repositoryFile(
      'supabase/migration_sources/pre_bootstrap/20260821191000_stock_alert_transactional_fix.sql',
    ).readAsStringSync();

    expect(sql, contains('stock_alert_tx_context'));
    expect(sql, contains('delta_total'));
    expect(sql, contains('CREATE CONSTRAINT TRIGGER trigger_stock_alert_evaluar_tx'));
    expect(sql, contains('DEFERRABLE INITIALLY DEFERRED'));
    expect(
      sql,
      contains(
        'v_stock_total_viejo := v_stock_total_nuevo + COALESCE(v_delta_total, 0);',
      ),
    );
    expect(sql, contains('DELETE FROM public.stock_alert_tx_context'));
  });

  test('traslado puro 13 a 13 no genera ninguna alerta', () {
    const stockInicial = 13;
    const salida = 4;
    const entrada = 4;
    const minimo = 10;

    final deltaTotal = salida - entrada;
    final stockFinal = stockInicial - salida + entrada;
    final stockAnteriorReconstruido = stockFinal + deltaTotal;

    expect(stockFinal, 13);
    expect(deltaTotal, 0);
    expect(
      esStockBajo(
        anterior: stockAnteriorReconstruido,
        actual: stockFinal,
        minimo: minimo,
      ),
      isFalse,
    );
    expect(
      esAgotado(anterior: stockAnteriorReconstruido, actual: stockFinal),
      isFalse,
    );
  });

  test('venta 13 a 9 genera stock bajo y no agotado', () {
    const stockInicial = 13;
    const venta = 4;
    const minimo = 10;

    final stockFinal = stockInicial - venta;
    final stockAnteriorReconstruido = stockFinal + venta;

    expect(stockFinal, 9);
    expect(stockAnteriorReconstruido, 13);
    expect(
      esStockBajo(
        anterior: stockAnteriorReconstruido,
        actual: stockFinal,
        minimo: minimo,
      ),
      isTrue,
    );
    expect(
      esAgotado(anterior: stockAnteriorReconstruido, actual: stockFinal),
      isFalse,
    );
  });

  test('venta 9 a 0 genera agotado aunque ya estaba bajo el minimo', () {
    const stockInicial = 9;
    const venta = 9;
    const minimo = 10;

    final stockFinal = stockInicial - venta;
    final stockAnteriorReconstruido = stockFinal + venta;

    expect(stockFinal, 0);
    expect(
      esAgotado(anterior: stockAnteriorReconstruido, actual: stockFinal),
      isTrue,
    );
    expect(
      esStockBajo(
        anterior: stockAnteriorReconstruido,
        actual: stockFinal,
        minimo: minimo,
      ),
      isFalse,
    );
  });

  test('salto directo 13 a 0 prioriza agotado y evita doble alerta', () {
    const stockInicial = 13;
    const stockFinal = 0;
    const minimo = 10;

    expect(
      esAgotado(anterior: stockInicial, actual: stockFinal),
      isTrue,
    );
    expect(
      esStockBajo(
        anterior: stockInicial,
        actual: stockFinal,
        minimo: minimo,
      ),
      isFalse,
    );
  });

  test('scripts incluyen mensajes separados para stock bajo y agotado', () {
    final script = repositoryFile('scripts/trigger_notificaciones.sql').readAsStringSync();

    expect(script, contains("v_tipo_alerta := 'agotado'"));
    expect(script, contains("v_tipo_alerta := 'stock_bajo'"));
    expect(script, contains("chr(128680) || ' ' || chr(161) || 'Producto Agotado!'"));
    expect(script, contains("chr(9888) || chr(65039) || ' Alerta de Stock Bajo'"));
    expect(script, contains("'stock_alert_type', 'agotado'"));
    expect(script, contains("'stock_alert_type', 'stock_bajo'"));
  });

  test('script operativo queda ASCII para evitar mojibake al copiar', () {
    final script = repositoryFile('scripts/trigger_notificaciones.sql').readAsStringSync();

    expect(script.runes.every((rune) => rune <= 0x7f), isTrue);
    expect(script, isNot(contains('AsÃ')));
    expect(script, isNot(contains('ðŸ')));
    expect(script, isNot(contains('Â¡')));
    expect(script, isNot(contains('estÃ')));
    expect(script, contains('chr(225)'));
    expect(script, contains('chr(161)'));
  });

  test('scripts de notificacion no versionan credenciales REST de OneSignal', () {
    final script = repositoryFile('scripts/trigger_notificaciones.sql').readAsStringSync();
    final migration = repositoryFile(
      'supabase/migration_sources/pre_bootstrap/20260821191000_stock_alert_transactional_fix.sql',
    ).readAsStringSync();

    for (final source in [script, migration]) {
      expect(source, contains('vault.decrypted_secrets'));
      expect(source, contains('onesignal_rest_api_key'));
      expect(source, isNot(contains('os_v2_')));
      expect(source, isNot(contains('Basic os_')));
    }
  });

  test('alertas usan endpoint y autenticacion modernos de OneSignal', () {
    final script = repositoryFile('scripts/trigger_notificaciones.sql').readAsStringSync();
    final migration = repositoryFile(
      'supabase/migration_sources/pre_bootstrap/20260821191000_stock_alert_transactional_fix.sql',
    ).readAsStringSync();

    for (final source in [script, migration]) {
      expect(source, contains('https://api.onesignal.com/notifications'));
      expect(source, contains("'Authorization', 'Key ' || v_onesignal_rest_api_key"));
      expect(source, contains("'target_channel', 'push'"));
      expect(source, isNot(contains('https://onesignal.com/api/v1/notifications')));
      expect(source, isNot(contains("'Authorization', 'Basic '")));
    }
  });
}
