import 'package:core_logic/auth/application/operation_authorizer.dart';
import 'package:core_logic/auth/domain/app_permission.dart';
import 'package:core_logic/features/reportes/application/reporting_use_case.dart';
import 'package:flutter_test/flutter_test.dart';

class _Gateway implements ReportingGateway {
  ReportingSnapshot? result;

  @override
  Future<ReportingSnapshot> loadPeriod({
    required DateTime start,
    required DateTime end,
  }) async => result!;
}

class _Authorizer implements OperationAuthorizer {
  _Authorizer({this.allowed = true});

  final bool allowed;
  @override
  String? currentAuthUserId = 'user-1';

  @override
  Future<String> require(
    Set<AppPermission> permissions, {
    bool allowOffline = false,
  }) async {
    if (!allowed || !permissions.contains(AppPermission.reportsViewProfit)) {
      throw StateError('denied');
    }
    return currentAuthUserId!;
  }
}

void main() {
  test('calcula ingresos, egresos y flujo neto sin mapas', () async {
    final gateway = _Gateway();
    gateway.result = ReportingSnapshot(
      financialMovements: [
        FinancialMovementRecord(
          type: FinancialMovementType.income,
          amount: 150,
          description: 'Venta',
          date: DateTime(2026, 9, 5),
        ),
        FinancialMovementRecord(
          type: FinancialMovementType.expense,
          amount: 40,
          description: 'Gasto',
          date: DateTime(2026, 9, 5),
        ),
      ],
      inventoryMovements: const [],
      totalDiscounts: 10,
    );

    final result = await LoadReportingSnapshotUseCase(
      gateway: gateway,
      authorizer: _Authorizer(),
    ).execute(
      start: DateTime(2026, 9, 1),
      end: DateTime(2026, 9, 5),
    );

    expect(result.income, 150);
    expect(result.expenses, 40);
    expect(result.netCashFlow, 110);
    expect(result.totalDiscounts, 10);
  });

  test('rechaza un periodo invertido antes de consultar', () {
    final useCase = LoadReportingSnapshotUseCase(
      gateway: _Gateway(),
      authorizer: _Authorizer(),
    );
    expect(
      () => useCase.execute(
        start: DateTime(2026, 9, 5),
        end: DateTime(2026, 9, 1),
      ),
      throwsArgumentError,
    );
  });

  test('requiere reports.view_profit', () async {
    final useCase = LoadReportingSnapshotUseCase(
      gateway: _Gateway(),
      authorizer: _Authorizer(allowed: false),
    );
    await expectLater(
      useCase.execute(
        start: DateTime(2026, 9, 1),
        end: DateTime(2026, 9, 5),
      ),
      throwsStateError,
    );
  });
}
