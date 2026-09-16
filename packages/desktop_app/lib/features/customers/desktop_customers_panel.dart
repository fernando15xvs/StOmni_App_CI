import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final desktopCustomerUseCaseProvider = Provider<CustomerUseCase>(
  (ref) => CustomerUseCase(SupabaseCustomerGateway(Supabase.instance.client)),
);

final _desktopCustomersProvider = FutureProvider.autoDispose
    .family<List<CustomerRecord>, String>((ref, query) {
      return ref.watch(desktopCustomerUseCaseProvider).list(query: query);
    });

class DesktopCustomersPanel extends ConsumerStatefulWidget {
  const DesktopCustomersPanel({super.key});

  @override
  ConsumerState<DesktopCustomersPanel> createState() =>
      _DesktopCustomersPanelState();
}

class _DesktopCustomersPanelState extends ConsumerState<DesktopCustomersPanel> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _edit([CustomerRecord? customer]) async {
    final name = TextEditingController(text: customer?.name ?? '');
    final document = TextEditingController(text: customer?.document ?? '');
    final address = TextEditingController(text: customer?.address ?? '');
    final phone = TextEditingController(text: customer?.phone ?? '');
    var documentType = customer?.documentType ?? '';
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(customer == null ? 'Nuevo cliente' : 'Editar cliente'),
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
                    decoration: const InputDecoration(labelText: 'DNI / RUC'),
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
                      DropdownMenuItem(
                        value: '0',
                        child: Text('Otro / sin documento'),
                      ),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => documentType = value ?? ''),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: address,
                    decoration: const InputDecoration(labelText: 'Dirección'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: phone,
                    decoration: const InputDecoration(labelText: 'Teléfono'),
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
                      .read(desktopCustomerUseCaseProvider)
                      .save(
                        CustomerDraft(
                          name: name.text,
                          document: document.text,
                          address: address.text,
                          documentType: documentType,
                          phone: phone.text,
                        ),
                        id: customer?.id,
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
    address.dispose();
    phone.dispose();
    if (saved == true) ref.invalidate(_desktopCustomersProvider(_query));
  }

  Future<void> _delete(CustomerRecord customer) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar cliente'),
        content: Text(
          '¿Eliminar a ${customer.name}? Si tiene historial relacionado, el servidor puede impedirlo.',
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
    try {
      await ref.read(desktopCustomerUseCaseProvider).delete(customer.id);
      ref.invalidate(_desktopCustomersProvider(_query));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final customers = ref.watch(_desktopCustomersProvider(_query));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Clientes',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Nuevo cliente'),
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
          child: customers.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(child: Text(error.toString())),
            data: (rows) => rows.isEmpty
                ? const Center(child: Text('No hay clientes para mostrar.'))
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(28, 0, 28, 28),
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      return Card(
                        child: ListTile(
                          title: Text(
                            row.name,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            [
                              if (row.document.isNotEmpty) row.document,
                              if (row.phone?.isNotEmpty == true) row.phone!,
                              if (row.address.isNotEmpty) row.address,
                            ].join(' · '),
                          ),
                          trailing: Wrap(
                            children: [
                              IconButton(
                                tooltip: 'Editar',
                                onPressed: () => _edit(row),
                                icon: const Icon(Icons.edit_outlined),
                              ),
                              IconButton(
                                tooltip: 'Eliminar',
                                onPressed: () => _delete(row),
                                icon: const Icon(Icons.delete_outline),
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
