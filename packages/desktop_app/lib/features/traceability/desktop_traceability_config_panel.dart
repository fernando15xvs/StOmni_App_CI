import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../inventory/desktop_inventory_controller.dart';

class DesktopTraceabilityConfigPanel extends ConsumerStatefulWidget {
  const DesktopTraceabilityConfigPanel({super.key});

  @override
  ConsumerState<DesktopTraceabilityConfigPanel> createState() =>
      _DesktopTraceabilityConfigPanelState();
}

class _DesktopTraceabilityConfigPanelState
    extends ConsumerState<DesktopTraceabilityConfigPanel> {
  int? _productId;
  ProductTraceabilityConfig? _config;
  BusinessProfile? _profile;
  bool _loadingConfig = false;
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
      _loadingConfig = true;
      _config = null;
    });
    try {
      final config = await ref
          .read(inventoryTraceabilityUseCaseProvider)
          .loadConfig(productId);
      if (mounted && _productId == productId) {
        setState(() => _config = config);
      }
    } catch (error) {
      if (mounted) _message(ErrorMapper.map(error));
    } finally {
      if (mounted && _productId == productId) {
        setState(() => _loadingConfig = false);
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
        _message('Trazabilidad del producto guardada.');
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
    final catalog = ref.watch(desktopInventorySnapshotProvider);
    return Padding(
      padding: const EdgeInsets.all(28),
      child: catalog.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text(ErrorMapper.map(error))),
        data: (snapshot) {
          final products = snapshot.products.where((row) => row.active).toList();
          final caps = _profile?.capabilities;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Trazabilidad de productos',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Preconfigura productos y activa el cutover global sólo cuando quieras operar lotes, vencimientos o series.',
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: caps == null
                      ? const LinearProgressIndicator()
                      : Wrap(
                          spacing: 24,
                          runSpacing: 8,
                          children: [
                            SizedBox(
                              width: 250,
                              child: SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Lotes'),
                                value: caps.lotTracking,
                                onChanged: _savingCapabilities
                                    ? null
                                    : (value) => _saveCapabilities(
                                          lot: value,
                                          expiry: value ? caps.expiryTracking : false,
                                          serial: caps.serialNumberTracking,
                                        ),
                              ),
                            ),
                            SizedBox(
                              width: 250,
                              child: SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Vencimientos'),
                                subtitle: const Text('Requiere lotes'),
                                value: caps.expiryTracking,
                                onChanged: _savingCapabilities || !caps.lotTracking
                                    ? null
                                    : (value) => _saveCapabilities(
                                          lot: caps.lotTracking,
                                          expiry: value,
                                          serial: caps.serialNumberTracking,
                                        ),
                              ),
                            ),
                            SizedBox(
                              width: 250,
                              child: SwitchListTile(
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
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<int>(
                initialValue: _productId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Producto'),
                items: products
                    .map(
                      (row) => DropdownMenuItem(
                        value: row.product.id,
                        child: Text(
                          row.product.nombre,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value != null) _load(value);
                },
              ),
              const SizedBox(height: 20),
              if (_loadingConfig)
                const Center(child: CircularProgressIndicator())
              else if (_config != null) ...[
                SegmentedButton<ProductTraceabilityMode>(
                  segments: const [
                    ButtonSegment(
                      value: ProductTraceabilityMode.none,
                      label: Text('Sin trazabilidad'),
                    ),
                    ButtonSegment(
                      value: ProductTraceabilityMode.lot,
                      label: Text('Lote'),
                    ),
                    ButtonSegment(
                      value: ProductTraceabilityMode.serial,
                      label: Text('Serie'),
                    ),
                  ],
                  selected: {_config!.mode},
                  onSelectionChanged: (values) {
                    final mode = values.first;
                    setState(() {
                      _config = ProductTraceabilityConfig(
                        productId: _config!.productId,
                        mode: mode,
                        expiryRequired: mode == ProductTraceabilityMode.lot
                            ? _config!.expiryRequired
                            : false,
                        revision: _config!.revision,
                      );
                    });
                  },
                ),
                const SizedBox(height: 14),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Exigir fecha de vencimiento'),
                  subtitle: const Text('Disponible sólo para seguimiento por lote.'),
                  value: _config!.expiryRequired,
                  onChanged: _config!.mode == ProductTraceabilityMode.lot
                      ? (value) => setState(() {
                            _config = ProductTraceabilityConfig(
                              productId: _config!.productId,
                              mode: _config!.mode,
                              expiryRequired: value,
                              revision: _config!.revision,
                            );
                          })
                      : null,
                ),
                const Spacer(),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: const Text('Guardar configuración'),
                  ),
                ),
              ] else
                const Expanded(
                  child: Center(
                    child: Text('Selecciona un producto para configurarlo.'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
