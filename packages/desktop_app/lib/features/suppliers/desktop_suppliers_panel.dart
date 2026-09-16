import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final desktopSupplierUseCaseProvider = Provider<SupplierUseCase>(
  (ref) => SupplierUseCase(SupabaseSupplierGateway(Supabase.instance.client)),
);

final _desktopSuppliersProvider = FutureProvider.autoDispose
    .family<List<SupplierRecord>, String>((ref, query) {
      return ref.watch(desktopSupplierUseCaseProvider).list(query: query);
    });

class DesktopSuppliersPanel extends ConsumerStatefulWidget {
  const DesktopSuppliersPanel({super.key});

  @override
  ConsumerState<DesktopSuppliersPanel> createState() =>
      _DesktopSuppliersPanelState();
}

class _DesktopSuppliersPanelState extends ConsumerState<DesktopSuppliersPanel> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _edit([SupplierRecord? supplier]) async {
    final name = TextEditingController(text: supplier?.name ?? '');
    final document = TextEditingController(text: supplier?.document ?? '');
    final phone = TextEditingController(text: supplier?.phone ?? '');
    final address = TextEditingController(text: supplier?.address ?? '');
    var active = supplier?.active ?? true;
    var documentType = supplier?.documentType ?? '';
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            supplier == null ? 'Nuevo proveedor' : 'Editar proveedor',
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Nombre / razón social',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: document,
                    decoration: const InputDecoration(labelText: 'RUC / DNI'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: documentType.isEmpty ? null : documentType,
                    decoration: const InputDecoration(
                      labelText: 'Tipo de documento',
                    ),
                    items: const [
                      DropdownMenuItem(value: '1', child: Text('DNI')),
                      DropdownMenuItem(value: '6', child: Text('RUC')),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => documentType = value ?? ''),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: phone,
                    decoration: const InputDecoration(labelText: 'Teléfono'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: address,
                    decoration: const InputDecoration(labelText: 'Dirección'),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Proveedor activo'),
                    value: active,
                    onChanged: (value) => setDialogState(() => active = value),
                  ),
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
              onPressed: () async {
                try {
                  await ref
                      .read(desktopSupplierUseCaseProvider)
                      .save(
                        SupplierDraft(
                          name: name.text,
                          document: document.text,
                          documentType: documentType,
                          phone: phone.text,
                          address: address.text,
                          active: active,
                        ),
                        id: supplier?.id,
                      );
                  if (dialogContext.mounted) Navigator.pop(dialogContext, true);
                } catch (error) {
                  if (!dialogContext.mounted) return;
                  ScaffoldMessenger.of(
                    dialogContext,
                  ).showSnackBar(SnackBar(content: Text(error.toString())));
                }
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    document.dispose();
    phone.dispose();
    address.dispose();
    if (saved == true) ref.invalidate(_desktopSuppliersProvider(_query));
  }

  Future<void> _deactivate(SupplierRecord supplier) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Desactivar proveedor'),
        content: Text(
          '¿Desactivar a ${supplier.name}? Su historial se conservará.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Desactivar'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ref.read(desktopSupplierUseCaseProvider).deactivate(supplier.id);
      ref.invalidate(_desktopSuppliersProvider(_query));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final suppliers = ref.watch(_desktopSuppliersProvider(_query));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Proveedores',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add_business),
                label: const Text('Nuevo proveedor'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
          child: TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Buscar por nombre, DNI o RUC',
            ),
            onChanged: (value) => setState(() => _query = value.trim()),
          ),
        ),
        Expanded(
          child: suppliers.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(child: Text(error.toString())),
            data: (rows) => rows.isEmpty
                ? const Center(child: Text('No hay proveedores para mostrar.'))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            row.active
                                ? Icons.business
                                : Icons.business_outlined,
                          ),
                          title: Text(
                            row.name,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            [
                              if (row.document.isNotEmpty) row.document,
                              row.active ? 'Activo' : 'Inactivo',
                              if (row.phone?.isNotEmpty == true) row.phone!,
                            ].join(' · '),
                          ),
                          trailing: Wrap(
                            children: [
                              IconButton(
                                tooltip: 'Editar',
                                onPressed: () => _edit(row),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              if (row.active)
                                IconButton(
                                  tooltip: 'Desactivar',
                                  onPressed: () => _deactivate(row),
                                  icon: const Icon(Icons.person_off_outlined),
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
