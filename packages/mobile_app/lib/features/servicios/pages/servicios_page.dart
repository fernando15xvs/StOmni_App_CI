import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ServiciosPage extends ConsumerStatefulWidget {
  const ServiciosPage({super.key});

  @override
  ConsumerState<ServiciosPage> createState() => _ServiciosPageState();
}

class _ServiciosPageState extends ConsumerState<ServiciosPage> {
  bool _busy = false;

  Future<List<ServiceRecord>> _load() =>
      ref.read(serviceCatalogUseCaseProvider).list(includeInactive: true);

  Future<void> _edit([ServiceRecord? current]) async {
    final code = TextEditingController(text: current?.code ?? '');
    final name = TextEditingController(text: current?.name ?? '');
    final description = TextEditingController(text: current?.description ?? '');
    final price = TextEditingController(
      text: current == null
          ? ''
          : CommercialPresentation.formatNumber(current.unitPrice),
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(current == null ? 'Nuevo servicio' : 'Editar servicio'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: code,
                  decoration: const InputDecoration(labelText: 'Código'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Nombre'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: description,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Descripción'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: price,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Precio de venta',
                  ),
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
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      final unitPrice = double.tryParse(price.text.trim().replaceAll(',', '.'));
      if (unitPrice == null || unitPrice < 0) {
        _message('Ingresa un precio válido.', error: true);
      } else {
        setState(() => _busy = true);
        try {
          await ref
              .read(serviceCatalogUseCaseProvider)
              .save(
                ServiceDraft(
                  serviceId: current?.id,
                  code: code.text,
                  name: name.text,
                  description: description.text,
                  unitPrice: unitPrice,
                ),
              );
          if (mounted) setState(() {});
        } catch (error) {
          if (mounted) _message(ErrorMapper.map(error), error: true);
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      }
    }
    code.dispose();
    name.dispose();
    description.dispose();
    price.dispose();
  }

  Future<void> _deactivate(ServiceRecord service) async {
    setState(() => _busy = true);
    try {
      await ref.read(serviceCatalogUseCaseProvider).deactivate(service.id);
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) _message(ErrorMapper.map(error), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), backgroundColor: error ? Colors.red : null),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Servicios')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : () => _edit(),
        icon: const Icon(Icons.add_business_outlined),
        label: const Text('Nuevo servicio'),
      ),
      body: FutureBuilder<List<ServiceRecord>>(
        future: _load(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text(ErrorMapper.map(snapshot.error!)));
          }
          final rows = snapshot.data ?? const <ServiceRecord>[];
          if (rows.isEmpty)
            return const Center(child: Text('No hay servicios registrados.'));
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final row = rows[index];
              return Card(
                child: ListTile(
                  leading: Icon(
                    row.active
                        ? Icons.design_services_outlined
                        : Icons.block_outlined,
                  ),
                  title: Text('${row.code} · ${row.name}'),
                  subtitle: Text(
                    '${row.description}\n${AppFormatters.currency(row.unitPrice)} · ${row.active ? 'Activo' : 'Inactivo'}',
                  ),
                  isThreeLine: row.description.isNotEmpty,
                  onTap: _busy || !row.active ? null : () => _edit(row),
                  trailing: row.active
                      ? IconButton(
                          tooltip: 'Desactivar',
                          onPressed: _busy ? null : () => _deactivate(row),
                          icon: const Icon(Icons.archive_outlined),
                        )
                      : null,
                ),
              );
            },
          );
        },
      ),
    );
  }
}
