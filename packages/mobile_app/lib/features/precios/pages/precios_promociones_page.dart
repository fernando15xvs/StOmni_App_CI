import 'package:core_logic/core_logic.dart';
import 'package:core_logic/features/ventas/domain/sale_pricing.dart';
import 'package:core_logic/features/ventas/providers/sale_pricing_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../almacen/presentation/providers/inventory_use_case_providers.dart';

final mobilePriceRulesProvider = FutureProvider.autoDispose<List<SalePriceRule>>((ref) =>
    ref.watch(manageSalePriceRulesUseCaseProvider).list());

class PreciosPromocionesPage extends ConsumerStatefulWidget {
  const PreciosPromocionesPage({super.key});

  @override
  ConsumerState<PreciosPromocionesPage> createState() => _PreciosPromocionesPageState();
}

class _PreciosPromocionesPageState extends ConsumerState<PreciosPromocionesPage> {
  Future<void> _create() async {
    final products = await ref.read(searchProductsUseCaseProvider).call('');
    final active = products.where((p) => p.activo).toList(growable: false);
    if (!mounted || active.isEmpty) return;
    var productId = active.first.id;
    final name = TextEditingController();
    final presentation = TextEditingController();
    final quantity = TextEditingController(text: '1');
    final value = TextEditingController();
    var fixedMode = false;

    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Nueva regla de precio'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Nombre')),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                initialValue: productId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Producto'),
                items: active.map((p) => DropdownMenuItem(
                  value: p.id,
                  child: Text(p.nombre, overflow: TextOverflow.ellipsis),
                )).toList(growable: false),
                onChanged: (v) { if (v != null) setDialogState(() => productId = v); },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: presentation,
                decoration: const InputDecoration(
                  labelText: 'Presentación (opcional)',
                  helperText: 'Ej.: unidad, caja, kg. Vacío = todas.',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: quantity,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Cantidad mínima'),
              ),
              const SizedBox(height: 10),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('% descuento')),
                  ButtonSegment(value: true, label: Text('Precio fijo')),
                ],
                selected: {fixedMode},
                onSelectionChanged: (v) => setDialogState(() => fixedMode = v.first),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: value,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: fixedMode ? 'Precio autorizado' : 'Descuento %'),
              ),
            ]),
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
        final parsed = double.parse(value.text.trim().replaceAll(',', '.'));
        await ref.read(manageSalePriceRulesUseCaseProvider).save(SalePriceRuleDraft(
          name: name.text,
          productId: productId,
          presentationCode: presentation.text.trim().isEmpty ? null : presentation.text,
          minQuantity: double.parse(quantity.text.trim().replaceAll(',', '.')),
          priority: 0,
          active: true,
          fixedPrice: fixedMode ? parsed : null,
          discountPercent: fixedMode ? null : parsed,
        ));
        ref.invalidate(mobilePriceRulesProvider);
      } catch (error) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMapper.map(error))),
        );
      }
    }
    name.dispose();
    presentation.dispose();
    quantity.dispose();
    value.dispose();
  }

  Future<void> _delete(SalePriceRule rule) async {
    final ok = await showDialog<bool>(
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
    if (ok != true) return;
    try {
      await ref.read(manageSalePriceRulesUseCaseProvider).delete(rule.id);
      ref.invalidate(mobilePriceRulesProvider);
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorMapper.map(error))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final rules = ref.watch(mobilePriceRulesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Precios y promociones')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('Nueva regla'),
      ),
      body: rules.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(ErrorMapper.map(e), textAlign: TextAlign.center),
        )),
        data: (rows) => rows.isEmpty
            ? const Center(child: Text('No hay reglas de precio configuradas.'))
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                itemCount: rows.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final row = rows[index];
                  final value = row.fixedPrice != null
                      ? 'S/ ${row.fixedPrice!.toStringAsFixed(2)}'
                      : '${row.discountPercent!.toStringAsFixed(2)}%';
                  return Card(child: ListTile(
                    leading: const Icon(Icons.sell_outlined),
                    title: Text(row.name),
                    subtitle: Text('${row.productName} · desde ${CommercialPresentation.formatNumber(row.minQuantity)} · $value'),
                    trailing: IconButton(
                      tooltip: 'Eliminar',
                      onPressed: () => _delete(row),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ));
                },
              ),
      ),
    );
  }
}
