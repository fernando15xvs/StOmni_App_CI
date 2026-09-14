import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_operation_policy.dart';

class _MetricGateway implements ConfigurableMetricGateway {
  _MetricGateway({List<ConfigurableMetricDefinition>? rows})
      : rows = rows ?? const [
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
}

class _ReportingGateway implements ReportingGateway {
  _ReportingGateway({this.inventoryMovements = const []});

  final List<InventoryMovementRecord> inventoryMovements;

  @override
  Future<ReportingSnapshot> loadPeriod({
    required DateTime start,
    required DateTime end,
  }) async {
    return ReportingSnapshot(
      financialMovements: [
        FinancialMovementRecord(
          type: FinancialMovementType.income,
          amount: 100,
          description: 'Venta',
          date: start,
          saleId: 10,
        ),
        FinancialMovementRecord(
          type: FinancialMovementType.income,
          amount: 50,
          description: 'Venta',
          date: start,
          saleId: 11,
        ),
        FinancialMovementRecord(
          type: FinancialMovementType.expense,
          amount: 30,
          description: 'Gasto',
          date: start,
        ),
      ],
      inventoryMovements: inventoryMovements,
      totalDiscounts: 5,
    );
  }
}

void main() {
  test('evalúa únicamente métricas habilitadas con fuentes tipadas', () async {
    final useCase = ConfigurableMetricsUseCase(
      metrics: _MetricGateway(),
      reporting: _ReportingGateway(),
      authorizer: TestOperationAuthorizer(),
    );
    final values = await useCase.evaluate(
      start: DateTime(2026, 9, 1),
      end: DateTime(2026, 9, 5),
    );
    expect(values.map((value) => value.value), [120, 2]);
  });

  test('entradas y salidas cuentan movimientos, no suman unidades incompatibles', () async {
    final metrics = _MetricGateway(rows: const [
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
    ]);
    final reporting = _ReportingGateway(inventoryMovements: [
      InventoryMovementRecord(
        productId: 1,
        productName: 'Cable',
        warehouseName: 'Principal',
        movementType: 'ENTRADA',
        date: DateTime(2026, 9, 2),
        quantity: 100,
        entryQuantity: 100,
        exitQuantity: 0,
        unitLabel: 'metros',
      ),
      InventoryMovementRecord(
        productId: 2,
        productName: 'Adhesivo',
        warehouseName: 'Principal',
        movementType: 'ENTRADA',
        date: DateTime(2026, 9, 2),
        quantity: 2.5,
        entryQuantity: 2.5,
        exitQuantity: 0,
        unitLabel: 'kg',
      ),
      InventoryMovementRecord(
        productId: 3,
        productName: 'Foco',
        warehouseName: 'Principal',
        movementType: 'SALIDA',
        date: DateTime(2026, 9, 3),
        quantity: -12,
        entryQuantity: 0,
        exitQuantity: 12,
        unitLabel: 'unidades',
      ),
    ]);

    final values = await ConfigurableMetricsUseCase(
      metrics: metrics,
      reporting: reporting,
      authorizer: TestOperationAuthorizer(),
    ).evaluate(
      start: DateTime(2026, 9, 1),
      end: DateTime(2026, 9, 5),
    );

    expect(values.map((value) => value.value), [2, 1]);
  });

  test('rechaza posiciones duplicadas antes de persistir', () async {
    final gateway = _MetricGateway();
    final useCase = ConfigurableMetricsUseCase(
      metrics: gateway,
      reporting: _ReportingGateway(),
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
