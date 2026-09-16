import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desktop_inventory_controller.dart';
import 'desktop_product_editor.dart';
import 'desktop_product_units_editor.dart';

class DesktopProductsPanel extends ConsumerStatefulWidget {
  const DesktopProductsPanel({super.key});

  @override
  ConsumerState<DesktopProductsPanel> createState() =>
      _DesktopProductsPanelState();
}

class _DesktopProductsPanelState extends ConsumerState<DesktopProductsPanel> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _edit([DesktopInventoryItem? item]) async {
    final result = await showDialog<Object?>(
      context: context,
      builder: (context) => DesktopProductEditor(product: item?.product),
    );
    if (result != null) {
      ref.invalidate(desktopInventorySnapshotProvider);
    }
  }

  Future<void> _units(DesktopInventoryItem item) async {
    final result = await showDialog<Object?>(
      context: context,
      builder: (context) => DesktopProductUnitsEditor(item: item),
    );
    if (result != null) {
      ref.invalidate(desktopInventorySnapshotProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(desktopInventoryProvider(_query));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Productos',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'Ficha comercial, precios y presentaciones configurables.',
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add),
                label: const Text('Nuevo producto'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
          child: TextField(
            controller: _search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Buscar por nombre o código',
            ),
            onChanged: (value) => setState(() => _query = value.trim()),
          ),
        ),
        Expanded(
          child: rows.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(child: Text(error.toString())),
            data: (items) => items.isEmpty
                ? const Center(child: Text('No hay productos para mostrar.'))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                    itemCount: items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      return Card(
                        child: ListTile(
                          title: Text(
                            item.product.nombre,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            '${item.codeLabel} · ${item.saleTypeLabel} · stock ${item.totalStock}',
                          ),
                          trailing: Wrap(
                            spacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => _units(item),
                                icon: const Icon(Icons.straighten),
                                label: const Text('Unidades'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () => _edit(item),
                                icon: const Icon(Icons.edit_outlined),
                                label: const Text('Editar'),
                              ),
                            ],
                          ),
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
