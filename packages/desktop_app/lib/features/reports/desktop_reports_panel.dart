import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final desktopReportingUseCaseProvider = Provider<LoadReportingSnapshotUseCase>((ref) {
  return LoadReportingSnapshotUseCase(
    gateway: SupabaseReportingGateway(ref.read(supabaseProvider)),
    authorizer: ref.read(operationAuthorizerProvider),
  );
});

final desktopReportingSnapshotProvider = FutureProvider.autoDispose<ReportingSnapshot>((ref) {
  final now = AppTime.now();
  final start = DateTime(now.year, now.month, 1);
  return ref.read(desktopReportingUseCaseProvider).execute(start: start, end: now);
});

class DesktopReportsPanel extends ConsumerWidget {
  const DesktopReportsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(desktopReportingSnapshotProvider);
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Reportes y finanzas',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 5),
                    const Text('Resumen del mes actual protegido por reports.view_profit.'),
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Recargar',
                onPressed: () => ref.invalidate(desktopReportingSnapshotProvider),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Expanded(
            child: snapshot.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Text(
                    ErrorMapper.map(error),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              data: (data) => _ReportContent(data: data),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportContent extends StatelessWidget {
  const _ReportContent({required this.data});

  final ReportingSnapshot data;

  @override
  Widget build(BuildContext context) {
    final recent = data.financialMovements.take(20).toList(growable: false);
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _MetricCard(label: 'Ingresos', value: data.income)),
            const SizedBox(width: 12),
            Expanded(child: _MetricCard(label: 'Egresos', value: data.expenses)),
            const SizedBox(width: 12),
            Expanded(child: _MetricCard(label: 'Flujo neto', value: data.netCashFlow)),
            const SizedBox(width: 12),
            Expanded(child: _MetricCard(label: 'Descuentos', value: data.totalDiscounts)),
          ],
        ),
        const SizedBox(height: 18),
        Expanded(
          child: Card(
            child: recent.isEmpty
                ? const Center(child: Text('No hay movimientos financieros este mes.'))
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: recent.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final movement = recent[index];
                      final income = movement.type == FinancialMovementType.income;
                      return ListTile(
                        leading: Icon(income ? Icons.trending_up : Icons.trending_down),
                        title: Text(movement.description),
                        subtitle: Text(AppFormatters.limaDateTime(movement.date)),
                        trailing: Text(
                          '${income ? '+' : '-'} ${AppFormatters.currency(movement.amount)}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Text(
              AppFormatters.currency(value),
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
