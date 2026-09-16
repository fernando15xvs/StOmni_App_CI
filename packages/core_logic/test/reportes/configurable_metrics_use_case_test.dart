import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_operation_policy.dart';

class _MetricGateway implements ConfigurableMetricGateway {
  _MetricGateway({
    List<ConfigurableMetricDefinition>? rows,
    Map<MetricSource, double>? dashboardValues,
  }) : dashboardValues =
           dashboardValues ??
           const {MetricSource.netCashFlow: 120, MetricSource.salesCount: 2},
       rows =
           rows ??
           const [
             ConfigurableMetricDefinition(
               source: MetricSource.netCashFlow,
               label: 'Caja neta',
               position: 0,
               enabled: true,
               format: MetricFormat.currency,
             ),
             ConfigurableMetricDefinition(
               source: MetricSource.salesCount,
               label: 'Ventas',
               position: 1,
               enabled: true,
               format: MetricFormat.number,
             ),
           ];

  List<ConfigurableMetricDefinition> rows;
  final Map<MetricSource, double> dashboardValues;
  int writes = 0;

  @override
  Future<List<ConfigurableMetricDefinition>> listDefinitions() async => rows;

  @override
  Future<List<ConfigurableMetricDefinition>> saveDefinitions(
    List<ConfigurableMetricDefinition> definitions,
  ) async {
    writes++;
    rows = List.unmodifiable(definitions);
    return rows;
  }

  @override
  Future<ConfigurableDashboardSnapshot> loadDashboard({
    required DateTime start,
    required DateTime end,
    String? branchId,
  }) async {
    return ConfigurableDashboardSnapshot(
      start: start,
      end: end,
      branchId: branchId,
      metrics: [
        for (final definition in rows.where((row) => row.enabled))
          MetricValue(
            definition: definition,
            value: dashboardValues[definition.source],
            available: dashboardValues.containsKey(definition.source),
          ),
      ],
    );
  }
}

void main() {
  test('evalúa únicamente métricas habilitadas con fuentes tipadas', () async {
    final useCase = ConfigurableMetricsUseCase(
      metrics: _MetricGateway(),
      authorizer: TestOperationAuthorizer(),
    );
    final values = await useCase.evaluate(
      start: DateTime(2026, 9, 1),
      end: DateTime(2026, 9, 5),
    );
    expect(values.map((value) => value.value), [120, 2]);
  });

  test('propaga conteos agregados de entradas y salidas', () async {
    final metrics = _MetricGateway(
      rows: const [
        ConfigurableMetricDefinition(
          source: MetricSource.inventoryEntries,
          label: 'Entradas',
          position: 0,
          enabled: true,
          format: MetricFormat.number,
        ),
        ConfigurableMetricDefinition(
          source: MetricSource.inventoryExits,
          label: 'Salidas',
          position: 1,
          enabled: true,
          format: MetricFormat.number,
        ),
      ],
      dashboardValues: const {
        MetricSource.inventoryEntries: 2,
        MetricSource.inventoryExits: 1,
      },
    );

    final values = await ConfigurableMetricsUseCase(
      metrics: metrics,
      authorizer: TestOperationAuthorizer(),
    ).evaluate(start: DateTime(2026, 9, 1), end: DateTime(2026, 9, 5));

    expect(values.map((value) => value.value), [2, 1]);
  });

  test('rechaza posiciones duplicadas antes de persistir', () async {
    final gateway = _MetricGateway();
    final useCase = ConfigurableMetricsUseCase(
      metrics: gateway,
      authorizer: TestOperationAuthorizer(),
    );
    await expectLater(
      useCase.save(const [
        ConfigurableMetricDefinition(
          source: MetricSource.income,
          label: 'A',
          position: 0,
          enabled: true,
          format: MetricFormat.currency,
        ),
        ConfigurableMetricDefinition(
          source: MetricSource.expenses,
          label: 'B',
          position: 0,
          enabled: true,
          format: MetricFormat.currency,
        ),
      ]),
      throwsA(isA<UserFacingException>()),
    );
    expect(gateway.writes, 0);
  });
}
