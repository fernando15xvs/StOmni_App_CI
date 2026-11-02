import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mobile_app/features/balance/pages/balance_page.dart';
import 'package:mobile_app/features/reportes/navigation/reportes_navigation.dart';
import 'package:mobile_app/features/reportes/pages/reportes_page.dart';
import 'package:mobile_app/features/reportes/providers/reportes_provider.dart';
import 'package:mobile_app/platform/realtime/realtime_sync_service.dart';

class _FakeBalanceRepository extends Fake implements BalanceRepository {
  @override
  Future<Map<String, dynamic>> getDashboardSummary(
    DateTime inicio,
    DateTime fin,
  ) async => {'ventas_hoy': 0, 'gastos_hoy': 0};

  @override
  Future<List<Map<String, dynamic>>> getMovimientos(
    String tipo,
    DateTime inicio,
    DateTime fin,
  ) async => [];

  @override
  Future<List<Map<String, dynamic>>> getVentasParaDescuento(
    DateTime inicio,
    DateTime fin,
  ) async => [];
}

class _UnusedReportingUseCase extends Fake
    implements LoadReportingSnapshotUseCase {}

class _UnusedRealtimeFinancialService extends Fake
    implements RealtimeFinancialSyncService {}

class _CapturingReportsNotifier extends ReportesNotifier {
  _CapturingReportsNotifier(this.requests) : super(_UnusedReportingUseCase());

  final List<ReportesParams> requests;

  @override
  Future<void> cargarDatos(
    ReportesParams params,
    int revisionInventario,
    int revisionFinanciera, {
    bool silent = false,
    bool force = false,
  }) async {
    requests.add(params);
  }
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('es');
  });

  testWidgets('Balance abre Reportes en Financiero y permite volver', (
    tester,
  ) async {
    final requests = <ReportesParams>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          balanceRepositoryProvider.overrideWith(
            (ref) => _FakeBalanceRepository(),
          ),
          reportesProvider.overrideWith(
            (ref) => _CapturingReportsNotifier(requests),
          ),
          realtimeFinancialSyncServiceProvider.overrideWith(
            (ref) => _UnusedRealtimeFinancialService(),
          ),
          financialRealtimeEventStreamProvider.overrideWith(
            (ref) => const Stream<FinancialRealtimeEvent>.empty(),
          ),
        ],
        child: const MaterialApp(home: BalancePage()),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('Histórico financiero'), findsOneWidget);

    await tester.ensureVisible(find.text('Histórico financiero'));
    await tester.tap(find.text('Histórico financiero'));
    await tester.pumpAndSettle();

    expect(find.byType(ReportesPage), findsOneWidget);
    final tabs = tester.widget<TabBar>(find.byType(TabBar).last);
    expect(tabs.controller?.index, ReportesTab.financiero.index);
    expect(requests, isNotEmpty);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ReportesPage), findsNothing);
  });

  testWidgets('Reportes aplica rango personalizado y filtro de Egresos', (
    tester,
  ) async {
    final requests = <ReportesParams>[];
    final inicio = DateTime(2026, 10, 1);
    final fin = DateTime(2026, 10, 30);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          reportesProvider.overrideWith(
            (ref) => _CapturingReportsNotifier(requests),
          ),
          realtimeFinancialSyncServiceProvider.overrideWith(
            (ref) => _UnusedRealtimeFinancialService(),
          ),
        ],
        child: MaterialApp(
          home: ReportesPage(
            initialContext: ReportesInitialContext(
              tab: ReportesTab.financiero,
              financialFilter: ReportesFinancialFilter.egresos,
              period: ReportesPeriod.mensual,
              customRange: DateTimeRange(start: inicio, end: fin),
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Personalizado'), findsOneWidget);
    expect(requests, isNotEmpty);
    expect(requests.last.fechaInicio, inicio);
    expect(requests.last.fechaFin, DateTime(2026, 10, 30, 23, 59, 59));

    final labels = tester.widgetList<Text>(find.text('Egresos'));
    expect(
      labels.any(
        (label) =>
            label.style?.fontWeight == FontWeight.bold &&
            label.style?.fontSize == 14,
      ),
      isTrue,
    );

    await tester.tap(find.text('Inventario'));
    await tester.pumpAndSettle();
    final tabs = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabs.controller?.index, ReportesTab.inventario.index);
  });
}
