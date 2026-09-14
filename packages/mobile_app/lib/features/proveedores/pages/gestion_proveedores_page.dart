import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:core_logic/core_logic.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_form_styles.dart';
import '../providers/supplier_use_case_provider.dart';

class GestionProveedoresPage extends ConsumerStatefulWidget {
  const GestionProveedoresPage({super.key});

  @override
  ConsumerState<GestionProveedoresPage> createState() =>
      _GestionProveedoresPageState();
}

class _GestionProveedoresPageState
    extends ConsumerState<GestionProveedoresPage> {
  List<SupplierRecord> _proveedores = const [];
  bool _cargando = true;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cargarProveedores();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _cargarProveedores([String? query]) async {
    if (mounted) setState(() => _cargando = true);
    try {
      final data = await ref
          .read(supplierUseCaseProvider)
          .list(query: query ?? _search.text);
      if (!mounted) return;
      setState(() {
        _proveedores = data;
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _cargando = false);
      _mostrarError(e);
    }
  }

  Future<void> _llamar(String? telefono) async {
    final value = telefono?.trim() ?? '';
    if (value.isEmpty) return;
    final url = Uri.parse('tel:$value');
    try {
      if (await canLaunchUrl(url)) await launchUrl(url);
    } catch (e) {
      _mostrarError(e);
    }
  }

  Future<void> _desactivar(SupplierRecord supplier) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Desactivar proveedor?'),
        content: const Text(
          'El proveedor dejará de estar activo, pero sus compras y todo su historial se conservarán.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Desactivar', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      await ref.read(supplierUseCaseProvider).deactivate(supplier.id);
      await _cargarProveedores();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Proveedor desactivado')),
        );
      }
    } catch (e) {
      _mostrarError(e);
    }
  }

  Future<void> _mostrarDialogoProveedor([SupplierRecord? supplier]) async {
    final nombreCtrl = TextEditingController(text: supplier?.name ?? '');
    final documentoCtrl = TextEditingController(text: supplier?.document ?? '');
    final telCtrl = TextEditingController(text: supplier?.phone ?? '');
    final dirCtrl = TextEditingController(text: supplier?.address ?? '');
    var active = supplier?.active ?? true;
    var consulting = false;
    String? estadoSunat;
    String? condicionSunat;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> consultar() async {
            final doc = documentoCtrl.text.trim();
            if (doc.length != 8 && doc.length != 11) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('El RUC/DNI debe tener 8 u 11 dígitos')),
              );
              return;
            }
            setDialogState(() {
              consulting = true;
              estadoSunat = null;
              condicionSunat = null;
            });
            try {
              final tipo = doc.length == 8 ? 'dni' : 'ruc';
              final data = await ref
                  .read(personaLookupRepositoryProvider)
                  .consultar(numero: doc, tipo: tipo);
              if (data != null && context.mounted) {
                setDialogState(() {
                  if (tipo == 'dni') {
                    nombreCtrl.text = [
                      data['nombres'],
                      data['apellido_paterno'],
                      data['apellido_materno'],
                    ].map((value) => value?.toString().trim() ?? '').where((value) => value.isNotEmpty).join(' ');
                  } else {
                    nombreCtrl.text = data['razon_social']?.toString() ?? '';
                  }
                  final api = data['data'];
                  if (api is Map) {
                    final address = api['direccion']?.toString().trim() ?? '';
                    if (address.isNotEmpty) dirCtrl.text = address;
                    estadoSunat = api['estado']?.toString();
                    condicionSunat = api['condicion']?.toString();
                  }
                });
              }
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(ErrorMapper.map(e))),
                );
              }
            } finally {
              if (context.mounted) setDialogState(() => consulting = false);
            }
          }

          return AlertDialog(
            title: Text(supplier == null ? 'Nuevo Proveedor' : 'Editar Proveedor'),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: documentoCtrl,
                            keyboardType: TextInputType.number,
                            decoration: AppFormStyles.inputDecor(
                              context,
                              'RUC / DNI *',
                              icon: Icons.numbers,
                              primaryColor: AppColors.proveedores,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: consulting ? null : consultar,
                          icon: consulting
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.search),
                          tooltip: 'Consultar SUNAT/RENIEC',
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: nombreCtrl,
                      decoration: AppFormStyles.inputDecor(
                        context,
                        'Nombre / razón social *',
                        icon: Icons.business,
                        primaryColor: AppColors.proveedores,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (estadoSunat != null || condicionSunat != null)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (estadoSunat != null) Text('Estado SUNAT: $estadoSunat'),
                              if (condicionSunat != null) Text('Condición: $condicionSunat'),
                            ],
                          ),
                        ),
                      ),
                    TextField(
                      controller: telCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: AppFormStyles.inputDecor(
                        context,
                        'Teléfono',
                        icon: Icons.phone,
                        primaryColor: AppColors.proveedores,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: dirCtrl,
                      decoration: AppFormStyles.inputDecor(
                        context,
                        'Dirección',
                        icon: Icons.location_on,
                        primaryColor: AppColors.proveedores,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(active ? 'Proveedor activo' : 'Proveedor inactivo'),
                      value: active,
                      onChanged: (value) => setDialogState(() => active = value),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    final document = documentoCtrl.text.trim();
                    await ref.read(supplierUseCaseProvider).save(
                          SupplierDraft(
                            name: nombreCtrl.text,
                            document: document,
                            documentType: document.length == 8
                                ? '1'
                                : (document.length == 11 ? '6' : null),
                            phone: telCtrl.text,
                            address: dirCtrl.text,
                            active: active,
                          ),
                          id: supplier?.id,
                        );
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                    await _cargarProveedores();
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(ErrorMapper.map(e))),
                      );
                    }
                  }
                },
                child: const Text('Guardar'),
              ),
            ],
          );
        },
      ),
    );

    nombreCtrl.dispose();
    documentoCtrl.dispose();
    telCtrl.dispose();
    dirCtrl.dispose();
  }

  void _mostrarError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ErrorMapper.map(error)), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Proveedores'),
        backgroundColor: AppColors.proveedores,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar por nombre, DNI o RUC',
              ),
              onChanged: (value) => _cargarProveedores(value),
            ),
          ),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _cargarProveedores,
                    child: _proveedores.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: const [
                              SizedBox(height: 180),
                              Center(child: Text('No hay proveedores para mostrar.')),
                            ],
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                            itemCount: _proveedores.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final supplier = _proveedores[index];
                              return Card(
                                child: ListTile(
                                  leading: CircleAvatar(
                                    child: Icon(
                                      supplier.active ? Icons.business : Icons.business_outlined,
                                    ),
                                  ),
                                  title: Text(supplier.name),
                                  subtitle: Text([
                                    if (supplier.document.isNotEmpty) supplier.document,
                                    supplier.active ? 'Activo' : 'Inactivo',
                                    if (supplier.address?.isNotEmpty == true) supplier.address!,
                                  ].join(' · ')),
                                  onTap: () => _mostrarDialogoProveedor(supplier),
                                  trailing: Wrap(
                                    children: [
                                      if (supplier.phone?.isNotEmpty == true)
                                        IconButton(
                                          tooltip: 'Llamar',
                                          onPressed: () => _llamar(supplier.phone),
                                          icon: const Icon(Icons.phone_outlined),
                                        ),
                                      if (supplier.active)
                                        IconButton(
                                          tooltip: 'Desactivar',
                                          onPressed: () => _desactivar(supplier),
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
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.proveedores,
        foregroundColor: Colors.white,
        onPressed: () => _mostrarDialogoProveedor(),
        icon: const Icon(Icons.add_business),
        label: const Text('Nuevo proveedor'),
      ),
    );
  }
}
