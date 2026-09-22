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
    expect(
      sql,
      contains('CREATE CONSTRAINT TRIGGER trigger_stock_alert_evaluar_tx'),
    );
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

    expect(esAgotado(anterior: stockInicial, actual: stockFinal), isTrue);
    expect(
      esStockBajo(anterior: stockInicial, actual: stockFinal, minimo: minimo),
      isFalse,
    );
  });

  test('instalador global queda retirado en SaaS', () {
    final script = repositoryFile(
      'scripts/trigger_notificaciones.sql',
    ).readAsStringSync();
    const retired = 'RETIRED: pre-SaaS global stock push installer';

    expect(script, contains(retired));
    expect(script, contains('tenant-aware operational_alerts'));
    expect(script, isNot(contains('net.http_post(')));
    expect(script, isNot(contains("'included_segments'")));
    expect(script, isNot(contains('trigger_stock_alert_evaluar_tx')));
  });

  test('F6.2 usa alertas tenant-aware y event-driven', () {
    final migration = repositoryFile(
      'supabase/migrations/20260908051200_saas_operational_alert_event_driven_stock.sql',
    ).readAsStringSync();

    expect(migration, contains('refresh_low_stock_alert_for_product'));
    expect(migration, contains('operational_stock_alert_evaluate_tx'));
    expect(migration, contains('ia.organization_id=p_organization_id'));
    expect(migration, isNot(contains('included_segments')));
    expect(migration, isNot(contains('net.http_post(')));
  });

  test('fuente pre-bootstrap no versiona credenciales OneSignal', () {
    final migration = repositoryFile(
      'supabase/migration_sources/pre_bootstrap/20260821191000_stock_alert_transactional_fix.sql',
    ).readAsStringSync();

    expect(migration, contains('vault.decrypted_secrets'));
    expect(migration, contains('onesignal_rest_api_key'));
    expect(migration, isNot(contains('os_v2_')));
    expect(migration, isNot(contains('Basic os_')));
  });
}
