import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class MetricasConfigurablesPage extends ConsumerStatefulWidget {
  const MetricasConfigurablesPage({super.key});

  @override
  ConsumerState<MetricasConfigurablesPage> createState() =>
      _MetricasConfigurablesPageState();
}

class _MetricasConfigurablesPageState
    extends ConsumerState<MetricasConfigurablesPage> {
  bool _busy = false;
  int _periodDays = 30;

  DateTime get _end => AppTime.now();
  DateTime get _start => _end.subtract(Duration(days: _periodDays));

  Future<List<MetricValue>> _values() =>
      ref.read(configurableMetricsUseCaseProvider).evaluate(start: _start, end: _end);

  Future<void> _configure() async {
    final original = await ref.read(configurableMetricsUseCaseProvider).definitions();
    if (!mounted) return;
    final enabled = {for (final row in original) row.source: row.enabled};
    final labels = {
      for (final row in original) row.source: TextEditingController(text: row.label),
    };
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Configurar métricas'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final row in original)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: enabled[row.source] ?? false,
                      onChanged: (value) => setDialogState(() => enabled[row.source] = value),
                      title: TextField(
                        controller: labels[row.source],
                        decoration: InputDecoration(labelText: _sourceName(row.source)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (accepted == true && mounted) {
      setState(() => _busy = true);
      try {
        await ref.read(configurableMetricsUseCaseProvider).save([
          for (var index = 0; index < original.length; index++)
            ConfigurableMetricDefinition(
              source: original[index].source,
              label: labels[original[index].source]!.text,
              position: index,
              enabled: enabled[original[index].source] ?? false,
              format: original[index].format,
            ),
        ]);
        if (mounted) setState(() {});
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(ErrorMapper.map(error)), backgroundColor: Colors.red),
          );
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
    for (final controller in labels.values) {
      controller.dispose();
    }
  }

  String _sourceName(MetricSource source) => switch (source) {
        MetricSource.income => 'Ingresos cobrados',
        MetricSource.expenses => 'Gastos pagados',
        MetricSource.netCashFlow => 'Flujo neto',
        MetricSource.discounts => 'Descuentos',
        MetricSource.salesCount => 'Cantidad de ventas',
        MetricSource.inventoryEntries => 'Entradas de inventario',
        MetricSource.inventoryExits => 'Salidas de inventario',
        MetricSource.salesRevenue => 'Ventas',
        MetricSource.grossMargin => 'Margen bruto',
        MetricSource.inventoryTurnover => 'Rotación de inventario',
        MetricSource.deadInventoryItems => 'Inventario inmovilizado',
        MetricSource.accountsReceivable => 'Cuentas por cobrar',
        MetricSource.cashPerformancePercent => 'Rendimiento de caja',
      };

  String _format(MetricValue value) {
    if (!value.available || value.value == null) return 'No disponible';
    return value.definition.format == MetricFormat.currency
        ? AppFormatters.currency(value.value!)
        : CommercialPresentation.formatNumber(value.value!);
  }

  String get _periodLabel => switch (_periodDays) {
        7 => 'Últimos 7 días',
        30 => 'Últimos 30 días',
        90 => 'Últimos 90 días',
        365 => 'Últimos 365 días',
        _ => 'Periodo personalizado',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Métricas'),
        actions: [
          PopupMenuButton<int>(
            tooltip: 'Periodo',
            initialValue: _periodDays,
            onSelected: (days) => setState(() => _periodDays = days),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 7, child: Text('Últimos 7 días')),
              PopupMenuItem(value: 30, child: Text('Últimos 30 días')),
              PopupMenuItem(value: 90, child: Text('Últimos 90 días')),
              PopupMenuItem(value: 365, child: Text('Últimos 365 días')),
            ],
            icon: const Icon(Icons.date_range_outlined),
          ),
          IconButton(
            tooltip: 'Configurar',
            onPressed: _busy ? null : _configure,
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      body: FutureBuilder<List<MetricValue>>(
        future: _values(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text(ErrorMapper.map(snapshot.error!)));
          }
          final values = snapshot.data ?? const <MetricValue>[];
          if (values.isEmpty) return const Center(child: Text('No hay métricas activas.'));
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: values.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final value = values[index];
              return Card(
                child: ListTile(
                  title: Text(value.definition.label),
                  subtitle: Text(
                    value.note?.trim().isNotEmpty == true
                        ? '$_periodLabel · ${value.note}'
                        : _periodLabel,
                  ),
                  trailing: Text(
                    _format(value),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: value.available ? null : Theme.of(context).colorScheme.outline,
                        ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
