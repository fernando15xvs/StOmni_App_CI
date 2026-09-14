import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desktop_dashboard_controller.dart';

class DesktopDashboardPanel extends ConsumerWidget {
  const DesktopDashboardPanel({
    super.key,
    required this.role,
    required this.offlineAuthorization,
  });

  final String role;
  final bool offlineAuthorization;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dashboard = ref.watch(desktopDashboardProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: dashboard.when(
            loading: () => const Padding(
              padding: EdgeInsets.only(top: 72),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => _DashboardError(
              error: ErrorMapper.map(error),
              onRetry: () => ref.invalidate(desktopDashboardProvider),
            ),
            data: (data) => _DashboardContent(
              data: data,
              role: role,
              offlineAuthorization: offlineAuthorization,
              onRefresh: () => ref.invalidate(desktopDashboardProvider),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashboardContent extends StatelessWidget {
  const _DashboardContent({
    required this.data,
    required this.role,
    required this.offlineAuthorization,
    required this.onRefresh,
  });

  final DesktopDashboardData data;
  final String role;
  final bool offlineAuthorization;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final summary = data.summary;
    final configurable = data.configurableMetrics;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Hola, ${data.userName}',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    offlineAuthorization
                        ? 'Datos en modo offline; el último resumen remoto puede no estar disponible.'
                        : 'Resumen operativo de hoy',
                  ),
                ],
              ),
            ),
            IconButton.filledTonal(
              tooltip: 'Actualizar dashboard',
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 28),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _MetricCard(
              icon: Icons.point_of_sale_outlined,
              label: 'Ventas de hoy',
              value: AppFormatters.currency(summary.ventasHoy),
            ),
            _MetricCard(
              icon: Icons.payments_outlined,
              label: 'Gastos de hoy',
              value: AppFormatters.currency(summary.gastosHoy),
            ),
            _MetricCard(
              icon: Icons.trending_up,
              label: 'Resultado del día',
              value: AppFormatters.currency(summary.resultadoOperativoHoy),
            ),
            _MetricCard(
              icon: Icons.inventory_2_outlined,
              label: 'Productos activos',
              value: summary.totalProductos.toString(),
            ),
            _MetricCard(
              icon: Icons.warning_amber_rounded,
              label: 'Stock bajo',
              value: summary.lowStockCount.toString(),
            ),
            _MetricCard(
              icon: Icons.remove_shopping_cart_outlined,
              label: 'Sin stock',
              value: summary.outOfStockCount.toString(),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: _BalanceCard(
                icon: Icons.account_balance_wallet_outlined,
                title: 'Por cobrar',
                value: AppFormatters.currency(summary.deudasPorCobrar),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _BalanceCard(
                icon: Icons.receipt_long_outlined,
                title: 'Por pagar',
                value: AppFormatters.currency(summary.deudasPorPagar),
              ),
            ),
          ],
        ),
        if (configurable != null) ...[
          const SizedBox(height: 30),
          Text(
            'Indicadores configurables · últimos 30 días',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
          ),
          if (configurable.scopeNote?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 6),
            Text(configurable.scopeNote!),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              for (final metric in configurable.metrics)
                _MetricCard(
                  icon: _metricIcon(metric.definition.source),
                  label: metric.definition.label,
                  value: _formatMetric(metric),
                  note: metric.note,
                  muted: !metric.available,
                ),
            ],
          ),
        ],
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                const Icon(Icons.security_outlined),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Sesión autorizada como ${role == 'sin_rol' ? 'usuario' : role}. '
                    'Ventas e inventario usan el mismo core que la aplicación móvil.',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _formatMetric(MetricValue metric) {
    if (!metric.available || metric.value == null) return 'No disponible';
    return metric.definition.format == MetricFormat.currency
        ? AppFormatters.currency(metric.value!)
        : CommercialPresentation.formatNumber(metric.value!);
  }

  static IconData _metricIcon(MetricSource source) => switch (source) {
        MetricSource.income || MetricSource.salesRevenue => Icons.trending_up,
        MetricSource.expenses => Icons.trending_down,
        MetricSource.netCashFlow || MetricSource.cashPerformancePercent => Icons.insights_outlined,
        MetricSource.discounts => Icons.percent,
        MetricSource.salesCount => Icons.receipt_long_outlined,
        MetricSource.inventoryEntries => Icons.add_box_outlined,
        MetricSource.inventoryExits => Icons.indeterminate_check_box_outlined,
        MetricSource.grossMargin => Icons.show_chart,
        MetricSource.inventoryTurnover => Icons.sync,
        MetricSource.deadInventoryItems => Icons.inventory_2_outlined,
        MetricSource.accountsReceivable => Icons.account_balance_wallet_outlined,
      };
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    this.note,
    this.muted = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? note;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final color = muted ? Theme.of(context).colorScheme.outline : null;
    return Card(
      child: SizedBox(
        width: 270,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 28, color: color),
              const SizedBox(height: 16),
              Text(label, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              Text(
                value,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
              if (note?.trim().isNotEmpty == true) ...[
                const SizedBox(height: 8),
                Text(note!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({
    required this.icon,
    required this.title,
    required this.value,
  });

  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          children: [
            Icon(icon, size: 34),
            const SizedBox(width: 18),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 5),
                Text(
                  value,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardError extends StatelessWidget {
  const _DashboardError({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 64),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.cloud_off_outlined,
                    size: 44,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'No se pudo cargar el dashboard',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
                  ),
                  const SizedBox(height: 10),
                  Text(error, textAlign: TextAlign.center),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reintentar'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
