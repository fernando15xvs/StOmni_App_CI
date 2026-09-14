import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../almacen/presentation/providers/inventory_use_case_providers.dart';

class TrazabilidadConfigPage extends ConsumerStatefulWidget {
  const TrazabilidadConfigPage({super.key});

  @override
  ConsumerState<TrazabilidadConfigPage> createState() =>
      _TrazabilidadConfigPageState();
}

class _TrazabilidadConfigPageState
    extends ConsumerState<TrazabilidadConfigPage> {
  int? _productId;
  ProductTraceabilityConfig? _config;
  BusinessProfile? _profile;
  bool _loading = false;
  bool _saving = false;
  bool _savingCapabilities = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadProfile);
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await ref.read(businessProfileGatewayProvider).load();
      if (mounted) setState(() => _profile = profile);
    } catch (error) {
      if (mounted) _message(ErrorMapper.map(error));
    }
  }

  Future<void> _saveCapabilities({
    required bool lot,
    required bool expiry,
    required bool serial,
  }) async {
    final current = _profile;
    if (current == null || _savingCapabilities) return;
    if (expiry && !lot) {
      _message('El seguimiento de vencimientos requiere activar lotes.');
      return;
    }
    final c = current.capabilities;
    setState(() => _savingCapabilities = true);
    try {
      final saved = await ref.read(updateBusinessCapabilitiesUseCaseProvider).execute(
            current,
            BusinessCapabilities(
              inventoryEnabled: c.inventoryEnabled,
              multipleBranches: c.multipleBranches,
              multipleWarehouses: c.multipleWarehouses,
              creditSales: c.creditSales,
              electronicInvoicing: c.electronicInvoicing,
              supplierManagement: c.supplierManagement,
              purchaseManagement: c.purchaseManagement,
              lotTracking: lot,
              expiryTracking: expiry,
              variants: c.variants,
              services: c.services,
              serialNumberTracking: serial,
            ),
          );
      if (mounted) {
        setState(() => _profile = saved);
        _message('Capacidades de trazabilidad actualizadas.');
      }
    } catch (error) {
      if (mounted) _message(ErrorMapper.map(error));
    } finally {
      if (mounted) setState(() => _savingCapabilities = false);
    }
  }

  Future<void> _load(int productId) async {
    setState(() {
      _productId = productId;
      _config = null;
      _loading = true;
    });
    try {
      final result = await ref
          .read(inventoryTraceabilityUseCaseProvider)
          .loadConfig(productId);
      if (mounted && _productId == productId) {
        setState(() => _config = result);
      }
    } catch (error) {
      if (mounted) _message(ErrorMapper.map(error));
    } finally {
      if (mounted && _productId == productId) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _save() async {
    final config = _config;
    if (config == null || _saving) return;
    setState(() => _saving = true);
    try {
      final saved = await ref.read(inventoryTraceabilityUseCaseProvider).saveConfig(
            productId: config.productId,
            expectedRevision: config.revision,
            mode: config.mode,
            expiryRequired: config.expiryRequired,
          );
      if (mounted) {
        setState(() => _config = saved);
        _message('Trazabilidad guardada.');
      }
    } catch (error) {
      if (mounted) _message(ErrorMapper.map(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trazabilidad')),
      body: FutureBuilder<List<ProductoBusqueda>>(
        future: ref.read(searchProductsUseCaseProvider).call(''),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(ErrorMapper.map(snapshot.error)),
            ));
          }
          final products = (snapshot.data ?? const <ProductoBusqueda>[])
              .where((row) => row.activo)
              .toList(growable: false);
          final caps = _profile?.capabilities;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Capacidades del negocio',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Primero puedes preconfigurar productos. Activa estas capacidades sólo cuando quieras comenzar a operar con trazabilidad.',
              ),
              const SizedBox(height: 8),
              if (caps == null)
                const LinearProgressIndicator()
              else ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Seguimiento por lote'),
                  value: caps.lotTracking,
                  onChanged: _savingCapabilities
                      ? null
                      : (value) => _saveCapabilities(
                            lot: value,
                            expiry: value ? caps.expiryTracking : false,
                            serial: caps.serialNumberTracking,
                          ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Fechas de vencimiento'),
                  subtitle: const Text('Requiere seguimiento por lote.'),
                  value: caps.expiryTracking,
                  onChanged: _savingCapabilities || !caps.lotTracking
                      ? null
                      : (value) => _saveCapabilities(
                            lot: caps.lotTracking,
                            expiry: value,
                            serial: caps.serialNumberTracking,
                          ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Números de serie'),
                  value: caps.serialNumberTracking,
                  onChanged: _savingCapabilities
                      ? null
                      : (value) => _saveCapabilities(
                            lot: caps.lotTracking,
                            expiry: caps.expiryTracking,
                            serial: value,
                          ),
                ),
              ],
              const Divider(height: 32),
              const Text(
                'Configuración por producto',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _productId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Producto'),
                items: products.map((row) => DropdownMenuItem(
                  value: row.id,
                  child: Text(row.nombre, overflow: TextOverflow.ellipsis),
                )).toList(growable: false),
                onChanged: (value) { if (value != null) _load(value); },
              ),
              const SizedBox(height: 20),
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (_config != null) ...[
                DropdownButtonFormField<ProductTraceabilityMode>(
                  initialValue: _config!.mode,
                  decoration: const InputDecoration(labelText: 'Modo'),
                  items: const [
                    DropdownMenuItem(
                      value: ProductTraceabilityMode.none,
                      child: Text('Sin trazabilidad'),
                    ),
                    DropdownMenuItem(
                      value: ProductTraceabilityMode.lot,
                      child: Text('Por lote'),
                    ),
                    DropdownMenuItem(
                      value: ProductTraceabilityMode.serial,
                      child: Text('Por número de serie'),
                    ),
                  ],
                  onChanged: (mode) {
                    if (mode == null) return;
                    setState(() => _config = ProductTraceabilityConfig(
                      productId: _config!.productId,
                      mode: mode,
                      expiryRequired: mode == ProductTraceabilityMode.lot
                          ? _config!.expiryRequired
                          : false,
                      revision: _config!.revision,
                    ));
                  },
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Exigir vencimiento'),
                  value: _config!.expiryRequired,
                  onChanged: _config!.mode == ProductTraceabilityMode.lot
                      ? (value) => setState(() => _config = ProductTraceabilityConfig(
                            productId: _config!.productId,
                            mode: _config!.mode,
                            expiryRequired: value,
                            revision: _config!.revision,
                          ))
                      : null,
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: const Text('Guardar'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
