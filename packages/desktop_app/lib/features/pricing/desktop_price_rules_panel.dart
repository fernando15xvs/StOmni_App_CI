import 'package:core_logic/core_logic.dart';
import 'package:core_logic/features/ventas/domain/sale_pricing.dart';
import 'package:core_logic/features/ventas/providers/sale_pricing_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../inventory/desktop_inventory_controller.dart';

final desktopPriceRulesProvider = FutureProvider.autoDispose<List<SalePriceRule>>((ref) =>
    ref.watch(manageSalePriceRulesUseCaseProvider).list());

class DesktopPriceRulesPanel extends ConsumerStatefulWidget {
  const DesktopPriceRulesPanel({super.key});

  @override
  ConsumerState<DesktopPriceRulesPanel> createState() => _DesktopPriceRulesPanelState();
}

class _DesktopPriceRulesPanelState extends ConsumerState<DesktopPriceRulesPanel> {
  Future<void> _edit([SalePriceRule? current]) async {
    final catalog = await ref.read(desktopInventorySnapshotProvider.future);
    if (!mounted || catalog.products.isEmpty) return;
    var productId = current?.productId ?? catalog.products.first.product.id;
    final name = TextEditingController(text: current?.name ?? '');
    final presentation = TextEditingController(text: current?.presentationCode ?? '');
    final minQuantity = TextEditingController(text: '${current?.minQuantity ?? 1}');
    final value = TextEditingController(
      text: current?.fixedPrice?.toString() ?? current?.discountPercent?.toString() ?? '',
    );
    final priority = TextEditingController(text: '${current?.priority ?? 0}');
    var fixedMode = current?.fixedPrice != null || current == null;
    var active = current?.active ?? true;

    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(current == null ? 'Nueva regla de precio' : 'Editar regla de precio'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(controller: name, decoration: const InputDecoration(labelText: 'Nombre')),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: productId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Producto'),
                    items: catalog.products.map((row) => DropdownMenuItem(
                      value: row.product.id,
                      child: Text(row.product.nombre, overflow: TextOverflow.ellipsis),
                    )).toList(growable: false),
                    onChanged: (v) { if (v != null) setDialogState(() => productId = v); },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: presentation,
                    decoration: const InputDecoration(
                      labelText: 'Presentación (opcional)',
                      helperText: 'Ej.: unidad, caja, kg. Vacío = todas.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: minQuantity,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Cantidad mínima'),
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: true, label: Text('Precio fijo')),
                      ButtonSegment(value: false, label: Text('% descuento')),
                    ],
                    selected: {fixedMode},
                    onSelectionChanged: (set) => setDialogState(() => fixedMode = set.first),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: value,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: fixedMode ? 'Precio autorizado' : 'Descuento %'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: priority,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Prioridad',
                      helperText: 'Si varias reglas coinciden, gana la prioridad mayor.',
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Regla activa'),
                    value: active,
                    onChanged: (v) => setDialogState(() => active = v),
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
      try {
        final parsedValue = double.parse(value.text.trim().replaceAll(',', '.'));
        await ref.read(manageSalePriceRulesUseCaseProvider).save(
          SalePriceRuleDraft(
            name: name.text,
            productId: productId,
            presentationCode: presentation.text.trim().isEmpty ? null : presentation.text,
            minQuantity: double.parse(minQuantity.text.trim().replaceAll(',', '.')),
            priority: int.tryParse(priority.text.trim()) ?? 0,
            active: active,
            fixedPrice: fixedMode ? parsedValue : null,
            discountPercent: fixedMode ? null : parsedValue,
          ),
          id: current?.id,
        );
        ref.invalidate(desktopPriceRulesProvider);
      } catch (error) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMapper.map(error))),
        );
      }
    }
    name.dispose();
    presentation.dispose();
    minQuantity.dispose();
    value.dispose();
    priority.dispose();
  }

  Future<void> _delete(SalePriceRule rule) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar regla'),
        content: Text('¿Eliminar “${rule.name}”?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await ref.read(manageSalePriceRulesUseCaseProvider).delete(rule.id);
      ref.invalidate(desktopPriceRulesProvider);
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMapper.map(error))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final rules = ref.watch(desktopPriceRulesProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Precios y promociones', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              const Text('Reglas autoritativas aplicadas por producto, presentación y cantidad.'),
            ])),
            FilledButton.icon(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('Nueva regla')),
          ]),
        ),
        Expanded(child: rules.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(ErrorMapper.map(e))),
          data: (rows) => rows.isEmpty
              ? const Center(child: Text('No hay reglas de precio configuradas.'))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    final rule = row.fixedPrice != null
                        ? 'S/ ${row.fixedPrice!.toStringAsFixed(2)}'
                        : '${row.discountPercent!.toStringAsFixed(2)}% descuento';
                    return Card(child: ListTile(
                      leading: Icon(row.active ? Icons.sell : Icons.sell_outlined),
                      title: Text(row.name),
                      subtitle: Text('${row.productName} · ${row.presentationCode ?? 'todas'} · desde ${CommercialPresentation.formatNumber(row.minQuantity)} · $rule'),
                      trailing: Wrap(spacing: 4, children: [
                        IconButton(onPressed: () => _edit(row), icon: const Icon(Icons.edit_outlined)),
                        IconButton(onPressed: () => _delete(row), icon: const Icon(Icons.delete_outline)),
                      ]),
                    ));
                  },
                ),
        )),
      ],
    );
  }
}
