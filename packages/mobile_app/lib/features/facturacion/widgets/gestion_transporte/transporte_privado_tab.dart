import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';
import 'transporte_privado_dialogs.dart';
import 'transporte_ui_helpers.dart';

class TransportePrivadoTab extends ConsumerStatefulWidget {
  const TransportePrivadoTab({super.key});

  @override
  ConsumerState<TransportePrivadoTab> createState() =>
      _TransportePrivadoTabState();
}

class _TransportePrivadoTabState extends ConsumerState<TransportePrivadoTab> {
  List<Map<String, dynamic>> _conductores = const [];
  List<Map<String, dynamic>> _vehiculos = const [];
  bool _loading = true;
  String? _errorCarga;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _error(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _errorCarga = null;
      });
    }
    try {
      final catalog = await ref
          .read(greTransporteCatalogRepositoryProvider)
          .cargarPrivado();
      if (!mounted) return;
      setState(() {
        _conductores = catalog.conductores;
        _vehiculos = catalog.vehiculos;
        _errorCarga = null;
      });
    } catch (e, st) {
      debugPrint('TransportePrivadoTab: fallo al cargar catálogo: $e');
      debugPrintStack(stackTrace: st);
      if (mounted) {
        setState(() => _errorCarga = ErrorMapper.map(e));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editarConductor([Map<String, dynamic>? item]) async {
    if (await mostrarConductorDialog(context, ref, item) == true) {
      await _load();
    }
  }

  Future<void> _editarVehiculo([Map<String, dynamic>? item]) async {
    if (await mostrarVehiculoDialog(context, ref, item) == true) {
      await _load();
    }
  }

  Future<void> _desactivarConductor(int id) async {
    if (await confirmarDesactivar(context, 'conductor') != true) return;
    try {
      await ref.read(guiasRemisionRepositoryProvider).desactivarConductor(id);
      await _load();
    } catch (e, st) {
      debugPrint('TransportePrivadoTab: fallo al desactivar conductor: $e');
      debugPrintStack(stackTrace: st);
      _error(ErrorMapper.map(e));
    }
  }

  Future<void> _desactivarVehiculo(int id) async {
    if (await confirmarDesactivar(context, 'vehículo') != true) return;
    try {
      await ref.read(guiasRemisionRepositoryProvider).desactivarVehiculo(id);
      await _load();
    } catch (e, st) {
      debugPrint('TransportePrivadoTab: fallo al desactivar vehículo: $e');
      debugPrintStack(stackTrace: st);
      _error(ErrorMapper.map(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_errorCarga != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 52),
              const SizedBox(height: 16),
              Text(_errorCarga!, textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          TransporteSectionHeader(
            title: 'Conductores',
            icon: Icons.person,
            onAdd: _editarConductor,
          ),
          if (_conductores.isEmpty)
            const TransporteEmptyState(text: 'No hay conductores.')
          else
            ..._conductores.map(
              (item) => TransporteCatalogCard(
                title: '${item['nombres'] ?? ''} ${item['apellidos'] ?? ''}'
                    .trim(),
                subtitle:
                    'DNI: ${item['numero_documento'] ?? ''}\nLicencia: ${item['numero_licencia'] ?? '-'}',
                onEdit: () => _editarConductor(item),
                onDelete: () =>
                    _desactivarConductor((item['id'] as num).toInt()),
              ),
            ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          TransporteSectionHeader(
            title: 'Vehículos',
            icon: Icons.local_shipping,
            onAdd: _editarVehiculo,
          ),
          if (_vehiculos.isEmpty)
            const TransporteEmptyState(text: 'No hay vehículos.')
          else
            ..._vehiculos.map(
              (item) => TransporteCatalogCard(
                title: item['placa']?.toString() ?? '',
                subtitle:
                    'Marca: ${item['marca'] ?? '-'}\nModelo: ${item['modelo'] ?? '-'}\nConstancia: ${item['constancia_inscripcion'] ?? '-'}',
                onEdit: () => _editarVehiculo(item),
                onDelete: () =>
                    _desactivarVehiculo((item['id'] as num).toInt()),
              ),
            ),
        ],
      ),
    );
  }
}
