import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ModulosNegocioPage extends ConsumerStatefulWidget {
  const ModulosNegocioPage({super.key});

  @override
  ConsumerState<ModulosNegocioPage> createState() => _ModulosNegocioPageState();
}

class _ModulosNegocioPageState extends ConsumerState<ModulosNegocioPage> {
  BusinessProfile? _profile;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    try {
      final profile = await ref.read(businessProfileGatewayProvider).load();
      if (mounted) setState(() => _profile = profile);
    } catch (error) {
      if (mounted) _message(ErrorMapper.map(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  BusinessCapabilities _copy(
    BusinessCapabilities c, {
    bool? inventoryEnabled,
    bool? multipleBranches,
    bool? multipleWarehouses,
    bool? creditSales,
    bool? electronicInvoicing,
    bool? purchaseManagement,
    bool? lotTracking,
    bool? expiryTracking,
    bool? variants,
    bool? services,
    bool? serialNumberTracking,
  }) {
    final inventory = inventoryEnabled ?? c.inventoryEnabled;
    return BusinessCapabilities(
      inventoryEnabled: inventory,
      multipleBranches: multipleBranches ?? c.multipleBranches,
      multipleWarehouses:
          inventory ? (multipleWarehouses ?? c.multipleWarehouses) : false,
      creditSales: creditSales ?? c.creditSales,
      electronicInvoicing: electronicInvoicing ?? c.electronicInvoicing,
      supplierManagement: c.supplierManagement,
      purchaseManagement:
          inventory ? (purchaseManagement ?? c.purchaseManagement) : false,
      lotTracking: inventory ? (lotTracking ?? c.lotTracking) : false,
      expiryTracking: inventory ? (expiryTracking ?? c.expiryTracking) : false,
      variants: variants ?? c.variants,
      services: services ?? c.services,
      serialNumberTracking:
          inventory ? (serialNumberTracking ?? c.serialNumberTracking) : false,
    );
  }

  Future<void> _save(BusinessCapabilities next) async {
    final current = _profile;
    if (current == null || _saving) return;
    if (next.expiryTracking && !next.lotTracking) {
      _message('Los vencimientos requieren seguimiento por lote.');
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(updateBusinessCapabilitiesUseCaseProvider)
          .execute(current, next);
      if (mounted) {
        setState(() => _profile = saved);
        _message('Módulos actualizados.');
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
      appBar: AppBar(title: const Text('Módulos del negocio')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _profile == null
              ? const Center(
                  child: Text('No se pudo cargar la configuración de módulos.'),
                )
              : _content(_profile!.capabilities),
    );
  }

  Widget _content(BusinessCapabilities c) {
    Widget toggle({
      required String title,
      String? subtitle,
      required bool value,
      required ValueChanged<bool>? onChanged,
    }) {
      return SwitchListTile(
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        value: value,
        onChanged: _saving ? null : onChanged,
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'StOmni mostrará sólo los módulos habilitados. Las restricciones reales también se aplican en el servidor.',
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              toggle(
                title: 'Inventario',
                value: c.inventoryEnabled,
                onChanged: (value) => _save(_copy(c, inventoryEnabled: value)),
              ),
              toggle(
                title: 'Múltiples sucursales',
                value: c.multipleBranches,
                onChanged: (value) => _save(_copy(c, multipleBranches: value)),
              ),
              toggle(
                title: 'Múltiples almacenes',
                value: c.multipleWarehouses,
                onChanged: c.inventoryEnabled
                    ? (value) => _save(_copy(c, multipleWarehouses: value))
                    : null,
              ),
              toggle(
                title: 'Compras',
                value: c.purchaseManagement,
                onChanged: c.inventoryEnabled
                    ? (value) => _save(_copy(c, purchaseManagement: value))
                    : null,
              ),
              toggle(
                title: 'Servicios',
                value: c.services,
                onChanged: (value) => _save(_copy(c, services: value)),
              ),
              toggle(
                title: 'Variantes',
                value: c.variants,
                onChanged: (value) => _save(_copy(c, variants: value)),
              ),
              toggle(
                title: 'Ventas a crédito',
                value: c.creditSales,
                onChanged: (value) => _save(_copy(c, creditSales: value)),
              ),
              toggle(
                title: 'Facturación electrónica',
                value: c.electronicInvoicing,
                onChanged: (value) =>
                    _save(_copy(c, electronicInvoicing: value)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              toggle(
                title: 'Lotes',
                value: c.lotTracking,
                onChanged: c.inventoryEnabled
                    ? (value) => _save(
                          _copy(
                            c,
                            lotTracking: value,
                            expiryTracking: value ? c.expiryTracking : false,
                          ),
                        )
                    : null,
              ),
              toggle(
                title: 'Vencimientos',
                value: c.expiryTracking,
                onChanged: c.inventoryEnabled && c.lotTracking
                    ? (value) => _save(_copy(c, expiryTracking: value))
                    : null,
              ),
              toggle(
                title: 'Números de serie',
                value: c.serialNumberTracking,
                onChanged: c.inventoryEnabled
                    ? (value) => _save(_copy(c, serialNumberTracking: value))
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}