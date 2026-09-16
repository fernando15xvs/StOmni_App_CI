import 'package:core_logic/core_logic.dart';
import 'package:core_logic/features/catalogo/domain/product_variant_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/variantes_provider.dart';

class VariantesPage extends ConsumerStatefulWidget {
  const VariantesPage({super.key});

  @override
  ConsumerState<VariantesPage> createState() => _VariantesPageState();
}

class _VariantesPageState extends ConsumerState<VariantesPage> {
  bool _mutating = false;

  void _refresh() => ref.invalidate(productVariantGroupsProvider);

  Future<void> _edit([ProductVariantGroup? group]) async {
    final catalog = await ref.read(variantProductCatalogProvider.future);
    if (!mounted) return;
    final products = catalog.products.where((row) => row.active).toList();
    if (products.length < 2) {
      _message('Necesitas al menos dos productos activos.', error: true);
      return;
    }

    final name = TextEditingController(text: group?.name ?? '');
    final attrs = TextEditingController(
      text: group?.attributeNames.join(', ') ?? 'color, talla',
    );
    final selected = <int>{...?group?.members.map((row) => row.productId)};
    final values = <int, TextEditingController>{};
    for (final member in group?.members ?? const <ProductVariantMember>[]) {
      values[member.productId] = TextEditingController(
        text: group!.attributeNames
            .map((key) => member.attributes[key] ?? '')
            .join(', '),
      );
    }

    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final keys = attrs.text
              .split(',')
              .map((value) => value.trim().toLowerCase())
              .where((value) => value.isNotEmpty)
              .toList();
          for (final id in selected) {
            values.putIfAbsent(id, TextEditingController.new);
          }
          return AlertDialog(
            title: Text(
              group == null ? 'Nuevo grupo de variantes' : 'Editar variantes',
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: name,
                      decoration: const InputDecoration(
                        labelText: 'Nombre del grupo',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: attrs,
                      onChanged: (_) => setDialogState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Atributos separados por coma',
                        hintText: 'color, talla',
                      ),
                    ),
                    const SizedBox(height: 10),
                    ...products.map((item) {
                      final product = item.product;
                      final checked = selected.contains(product.id);
                      return Card(
                        child: Column(
                          children: [
                            CheckboxListTile(
                              title: Text(product.nombre),
                              subtitle: Text(product.codigo ?? 'Sin código'),
                              value: checked,
                              onChanged: (value) => setDialogState(() {
                                if (value == true) {
                                  selected.add(product.id);
                                  values.putIfAbsent(
                                    product.id,
                                    TextEditingController.new,
                                  );
                                } else {
                                  selected.remove(product.id);
                                }
                              }),
                            ),
                            if (checked)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  12,
                                ),
                                child: TextField(
                                  controller: values[product.id],
                                  decoration: InputDecoration(
                                    labelText: keys.isEmpty
                                        ? 'Valores'
                                        : 'Valores: ${keys.join(', ')}',
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
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
                          final parts = values[id]!.text
                              .split(',')
                              .map((e) => e.trim())
                              .toList();
                          if (parts.length != keys.length ||
                              parts.any((value) => value.isEmpty))
                            return;
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

    if (accepted == true && mounted) {
      final keys = attrs.text
          .split(',')
          .map((value) => value.trim().toLowerCase())
          .where((value) => value.isNotEmpty)
          .toList();
      setState(() => _mutating = true);
      try {
        await ref
            .read(productVariantUseCaseProvider)
            .save(
              ProductVariantGroupDraft(
                name: name.text,
                attributeNames: keys,
                members: selected.map((id) {
                  final parts = values[id]!.text
                      .split(',')
                      .map((e) => e.trim())
                      .toList();
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
          _message('Variantes guardadas.');
          _refresh();
        }
      } catch (error) {
        if (mounted) _message(ErrorMapper.map(error), error: true);
      } finally {
        if (mounted) setState(() => _mutating = false);
      }
    }

    name.dispose();
    attrs.dispose();
    for (final controller in values.values) {
      controller.dispose();
    }
  }

  Future<void> _delete(ProductVariantGroup group) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar grupo'),
        content: const Text(
          'Se elimina sólo la agrupación. Los productos y su historial permanecen intactos.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _mutating = true);
    try {
      await ref.read(productVariantUseCaseProvider).delete(group.id);
      _refresh();
    } catch (error) {
      if (mounted) _message(ErrorMapper.map(error), error: true);
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  void _message(String text, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), backgroundColor: error ? Colors.red : null),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(productVariantGroupsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Variantes de productos')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _mutating ? null : () => _edit(),
        icon: const Icon(Icons.account_tree_outlined),
        label: const Text('Nuevo grupo'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          _refresh();
          await ref.read(productVariantGroupsProvider.future);
        },
        child: groups.when(
          loading: () => ListView(
            children: const [
              SizedBox(height: 260),
              Center(child: CircularProgressIndicator()),
            ],
          ),
          error: (error, _) => ListView(
            children: [
              const SizedBox(height: 180),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  ErrorMapper.map(error),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          data: (rows) => rows.isEmpty
              ? ListView(
                  children: const [
                    SizedBox(height: 220),
                    Center(child: Text('No hay grupos de variantes.')),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final group = rows[index];
                    return Card(
                      child: ExpansionTile(
                        title: Text(group.name),
                        subtitle: Text(group.attributeNames.join(' · ')),
                        trailing: PopupMenuButton<String>(
                          enabled: !_mutating,
                          onSelected: (value) {
                            if (value == 'edit') _edit(group);
                            if (value == 'delete') _delete(group);
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Editar')),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Eliminar'),
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
                                    .map(
                                      (key) =>
                                          '$key: ${member.attributes[key] ?? '—'}',
                                    )
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
    );
  }
}
