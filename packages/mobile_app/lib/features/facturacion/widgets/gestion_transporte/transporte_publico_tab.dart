import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';
import 'transporte_publico_dialogs.dart';
import 'transporte_ui_helpers.dart';

class TransportePublicoTab extends ConsumerStatefulWidget {
  const TransportePublicoTab({super.key});

  @override
  ConsumerState<TransportePublicoTab> createState() =>
      _TransportePublicoTabState();
}

class _TransportePublicoTabState extends ConsumerState<TransportePublicoTab> {
  GreTransportePublicoCatalog _catalog = const GreTransportePublicoCatalog(
    transportistas: [],
    agencias: [],
  );
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
          .cargarPublico();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _errorCarga = null;
      });
    } catch (e, st) {
      debugPrint('TransportePublicoTab: fallo al cargar catálogo: $e');
      debugPrintStack(stackTrace: st);
      if (mounted) {
        setState(() => _errorCarga = ErrorMapper.map(e));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editarTransportista([Map<String, dynamic>? item]) async {
    if (await mostrarTransportistaDialog(context, ref, item) == true) {
      await _load();
    }
  }

  Future<void> _editarAgencia(
    Map<String, dynamic> transportista, [
    Map<String, dynamic>? item,
  ]) async {
    if (await mostrarAgenciaDialog(context, ref, transportista, item) == true) {
      await _load();
    }
  }

  Future<void> _desactivarTransportista(int id) async {
    if (await confirmarDesactivar(context, 'transportista') != true) return;
    try {
      await ref
          .read(guiasRemisionRepositoryProvider)
          .desactivarTransportista(id);
      await _load();
    } catch (e, st) {
      debugPrint('TransportePublicoTab: fallo al desactivar transportista: $e');
      debugPrintStack(stackTrace: st);
      _error(ErrorMapper.map(e));
    }
  }

  Future<void> _desactivarAgencia(int id) async {
    if (await confirmarDesactivar(context, 'agencia') != true) return;
    try {
      await ref.read(guiasRemisionRepositoryProvider).desactivarAgencia(id);
      await _load();
    } catch (e, st) {
      debugPrint('TransportePublicoTab: fallo al desactivar agencia: $e');
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

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _editarTransportista,
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('TRANSPORTISTA'),
      ),
      body: _catalog.transportistas.isEmpty
          ? RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 180),
                  Center(child: Text('No hay transportistas registrados.')),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16).copyWith(bottom: 90),
                itemCount: _catalog.transportistas.length,
                itemBuilder: (context, index) {
                  final transportista = _catalog.transportistas[index];
                  final id = (transportista['id'] as num).toInt();
                  final agencias = _catalog.agenciasDe(id);
                  return _TransportistaCard(
                    transportista: transportista,
                    agencias: agencias,
                    onNuevaAgencia: () => _editarAgencia(transportista),
                    onEditar: () => _editarTransportista(transportista),
                    onEliminar: () => _desactivarTransportista(id),
                    onEditarAgencia: (agencia) =>
                        _editarAgencia(transportista, agencia),
                    onEliminarAgencia: (agencia) =>
                        _desactivarAgencia((agencia['id'] as num).toInt()),
                  );
                },
              ),
            ),
    );
  }
}

class _TransportistaCard extends StatelessWidget {
  const _TransportistaCard({
    required this.transportista,
    required this.agencias,
    required this.onNuevaAgencia,
    required this.onEditar,
    required this.onEliminar,
    required this.onEditarAgencia,
    required this.onEliminarAgencia,
  });

  final Map<String, dynamic> transportista;
  final List<Map<String, dynamic>> agencias;
  final VoidCallback onNuevaAgencia;
  final VoidCallback onEditar;
  final VoidCallback onEliminar;
  final ValueChanged<Map<String, dynamic>> onEditarAgencia;
  final ValueChanged<Map<String, dynamic>> onEliminarAgencia;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Card(
      elevation: 0,
      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
        ),
      ),
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        leading: const Icon(Icons.local_shipping_outlined),
        title: Text(
          transportista['razon_social']?.toString() ?? '',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          'RUC: ${transportista['ruc'] ?? ''} · ${agencias.length} agencia(s)',
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            switch (value) {
              case 'agencia':
                onNuevaAgencia();
              case 'editar':
                onEditar();
              case 'eliminar':
                onEliminar();
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'agencia', child: Text('Nueva agencia')),
            PopupMenuItem(value: 'editar', child: Text('Editar transportista')),
            PopupMenuItem(
              value: 'eliminar',
              child: Text('Eliminar transportista'),
            ),
          ],
        ),
        children: [
          if (agencias.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: OutlinedButton.icon(
                onPressed: onNuevaAgencia,
                icon: const Icon(Icons.add_business),
                label: const Text('REGISTRAR PRIMERA AGENCIA'),
              ),
            )
          else
            ...agencias.map(
              (agencia) => ListTile(
                contentPadding: const EdgeInsets.only(left: 28, right: 8),
                leading: const Icon(Icons.store_mall_directory),
                title: Text(
                  agencia['nombre']?.toString() ?? 'Agencia',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  '${agencia['direccion'] ?? ''}\n'
                  '${agencia['distrito'] ?? ''} · Ubigeo ${agencia['ubigeo'] ?? ''}\n'
                  '${agencia['permite_origen'] == true ? 'Origen' : ''}'
                  '${agencia['permite_origen'] == true && agencia['permite_destino'] == true ? ' / ' : ''}'
                  '${agencia['permite_destino'] == true ? 'Destino' : ''}',
                ),
                isThreeLine: true,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Editar agencia',
                      onPressed: () => onEditarAgencia(agencia),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: 'Eliminar agencia',
                      onPressed: () => onEliminarAgencia(agencia),
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                    ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onNuevaAgencia,
                icon: const Icon(Icons.add),
                label: const Text('NUEVA AGENCIA'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
