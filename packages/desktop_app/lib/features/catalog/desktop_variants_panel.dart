import 'package:core_logic/business/providers/business_profile_providers.dart';
import 'package:core_logic/core_logic.dart';
import 'package:core_logic/features/catalogo/application/product_variant_use_case.dart';
import 'package:core_logic/features/catalogo/data/supabase_product_variant_gateway.dart';
import 'package:core_logic/features/catalogo/domain/product_variant_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../inventory/desktop_inventory_controller.dart';

final desktopVariantUseCaseProvider = Provider<ProductVariantUseCase>((ref) {
  return ProductVariantUseCase(
    gateway: SupabaseProductVariantGateway(ref.read(supabaseProvider)),
    businessProfile: ref.read(businessProfileGatewayProvider),
    authorizer: ref.read(operationAuthorizerProvider),
  );
});

final desktopVariantGroupsProvider = FutureProvider.autoDispose<List<ProductVariantGroup>>((ref) {
  return ref.watch(desktopVariantUseCaseProvider).list();
});

class DesktopVariantsPanel extends ConsumerStatefulWidget {
  const DesktopVariantsPanel({super.key});

  @override
  ConsumerState<DesktopVariantsPanel> createState() => _DesktopVariantsPanelState();
}

class _DesktopVariantsPanelState extends ConsumerState<DesktopVariantsPanel> {
  bool _mutating = false;

  void _refresh() => ref.invalidate(desktopVariantGroupsProvider);

  Future<void> _edit([ProductVariantGroup? group]) async {
    final inventory = await ref.read(desktopInventorySnapshotProvider.future);
    if (!mounted) return;
    final products = inventory.products.where((row) => row.active).toList();
    if (products.length < 2) {
      _message('Necesitas al menos dos productos activos para crear variantes.', error: true);
      return;
    }

    final name = TextEditingController(text: group?.name ?? '');
    final attributes = TextEditingController(
      text: group?.attributeNames.join(', ') ?? 'color, talla',
    );
    final selected = <int>{...?group?.members.map((row) => row.productId)};
    final values = <int, TextEditingController>{};
    for (final member in group?.members ?? const <ProductVariantMember>[]) {
      values[member.productId] = TextEditingController(
        text: group!.attributeNames.map((key) => member.attributes[key] ?? '').join(', '),
      );
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final keys = attributes.text
              .split(',')
              .map((value) => value.trim().toLowerCase())
              .where((value) => value.isNotEmpty)
              .toList();
          for (final id in selected) {
            values.putIfAbsent(id, TextEditingController.new);
          }
          return AlertDialog(
            title: Text(group == null ? 'Nuevo grupo de variantes' : 'Editar variantes'),
            content: SizedBox(
              width: 760,
              height: 560,
              child: Column(
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Nombre del grupo'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: attributes,
                    onChanged: (_) => setDialogState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Atributos separados por coma',
                      hintText: 'color, talla',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.builder(
                      itemCount: products.length,
                      itemBuilder: (context, index) {
                        final product = products[index].product;
                        final isSelected = selected.contains(product.id);
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: Column(
                              children: [
                                CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(product.nombre),
                                  subtitle: Text(product.codigo ?? 'Sin código'),
                                  value: isSelected,
                                  onChanged: (value) => setDialogState(() {
                                    if (value == true) {
                                      selected.add(product.id);
                                      values.putIfAbsent(product.id, TextEditingController.new);
                                    } else {
                                      selected.remove(product.id);
                                    }
                                  }),
                                ),
                                if (isSelected)
                                  TextField(
                                    controller: values[product.id],
                                    decoration: InputDecoration(
                                      labelText: keys.isEmpty
                                          ? 'Valores'
                                          : 'Valores: ${keys.join(', ')}',
                                      hintText: keys.map((key) => '<$key>').join(', '),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: selected.length < 2 || keys.isEmpty
                    ? null
                    : () {
                        for (final id in selected) {
                          final parts = values[id]!.text.split(',').map((e) => e.trim()).toList();
                          if (parts.length != keys.length || parts.any((value) => value.isEmpty)) return;
                        }
                        Navigator.pop(dialogContext, true);
                      },
                child: const Text('Guardar'),
              ),
            ],
          );
        },
      ),
    );

    if (saved == true && mounted) {
      final keys = attributes.text
          .split(',')
          .map((value) => value.trim().toLowerCase())
          .where((value) => value.isNotEmpty)
          .toList();
      setState(() => _mutating = true);
      try {
        await ref.read(desktopVariantUseCaseProvider).save(
              ProductVariantGroupDraft(
                name: name.text,
                attributeNames: keys,
                members: selected.map((id) {
                  final parts = values[id]!.text.split(',').map((e) => e.trim()).toList();
                  return ProductVariantMemberDraft(
                    productId: id,
                    attributes: {
                      for (var i = 0; i < keys.length; i++) keys[i]: parts[i],
                    },
                  );
                }),
              ),
              id: group?.id,
            );
        if (mounted) {
          _message('Grupo de variantes guardado.');
          _refresh();
        }
      } catch (error) {
        if (mounted) _message(ErrorMapper.map(error), error: true);
      } finally {
        if (mounted) setState(() => _mutating = false);
      }
    }

    name.dispose();
    attributes.dispose();
    for (final controller in values.values) {
      controller.dispose();
    }
  }

  Future<void> _delete(ProductVariantGroup group) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar grupo'),
        content: Text(
          '¿Eliminar “${group.name}”? Los productos, inventarios y ventas no se eliminan.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _mutating = true);
    try {
      await ref.read(desktopVariantUseCaseProvider).delete(group.id);
      _refresh();
    } catch (error) {
      if (mounted) _message(ErrorMapper.map(error), error: true);
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  void _message(String text, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(desktopVariantGroupsProvider);
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
                      'Variantes',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 5),
                    const Text('Agrupa productos existentes por atributos sin duplicar inventario.'),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: _mutating ? null : () => _edit(),
                icon: const Icon(Icons.add),
                label: const Text('Nuevo grupo'),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(onPressed: _mutating ? null : _refresh, icon: const Icon(Icons.refresh)),
            ],
          ),
          const SizedBox(height: 18),
          Expanded(
            child: groups.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(child: Text(ErrorMapper.map(error))),
              data: (rows) => rows.isEmpty
                  ? const Center(child: Text('Todavía no hay grupos de variantes.'))
                  : ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final group = rows[index];
                        return Card(
                          child: ExpansionTile(
                            title: Text(group.name),
                            subtitle: Text(group.attributeNames.join(' · ')),
                            trailing: Wrap(
                              children: [
                                IconButton(
                                  tooltip: 'Editar',
                                  onPressed: _mutating ? null : () => _edit(group),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                                IconButton(
                                  tooltip: 'Eliminar grupo',
                                  onPressed: _mutating ? null : () => _delete(group),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                            children: [
                              for (final member in group.members)
                                ListTile(
                                  dense: true,
                                  title: Text(member.productName),
                                  subtitle: Text(
                                    group.attributeNames
                                        .map((key) => '$key: ${member.attributes[key] ?? '—'}')
                                        .join(' · '),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
