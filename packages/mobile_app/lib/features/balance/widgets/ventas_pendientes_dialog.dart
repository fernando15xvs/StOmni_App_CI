import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:core_logic/core_logic.dart';
import '../utils/balance_service.dart';

class VentasPendientesDialog extends ConsumerStatefulWidget {
  final VoidCallback onSyncComplete;

  const VentasPendientesDialog({super.key, required this.onSyncComplete});

  @override
  ConsumerState<VentasPendientesDialog> createState() =>
      _VentasPendientesDialogState();
}

class _VentasPendientesDialogState
    extends ConsumerState<VentasPendientesDialog> {
  List<Map<String, dynamic>> _ventas = [];
  bool _cargando = true;
  bool _sincronizando = false;

  @override
  void initState() {
    super.initState();
    _cargarVentas();
  }

  Future<void> _cargarVentas() async {
    if (mounted) setState(() => _cargando = true);
    final ventas = await OfflineService.obtenerVentasOffline();
    if (!mounted) return;
    setState(() {
      _ventas = ventas;
      _cargando = false;
    });
  }

  Future<void> _eliminarVenta(String requestId) async {
    if (requestId.trim().isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar Venta Pendiente'),
        content: const Text(
          '¿Estás seguro de que quieres eliminar esta venta permanentemente? '
          'No se sincronizará con el servidor.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Eliminar',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await OfflineService.eliminarVentaOfflinePorRequestId(requestId);
      await _cargarVentas();
    }
  }

  Future<void> _sincronizarTodas() async {
    if (_sincronizando) return;
    setState(() => _sincronizando = true);

    try {
      await BalanceService.sincronizarVentasOffline(
        context,
        ref,
        widget.onSyncComplete,
      );
      if (!mounted) return;

      // Si alguna venta falló, mantenemos el diálogo abierto para que el
      // usuario pueda ver intentos y último error. Solo cerramos cuando la
      // cola quedó realmente vacía.
      final restantes = await OfflineService.obtenerVentasOffline();
      if (!mounted) return;
      if (restantes.isEmpty) {
        Navigator.of(context).pop();
        return;
      }

      setState(() {
        _ventas = restantes;
        _cargando = false;
      });
    } finally {
      if (mounted) setState(() => _sincronizando = false);
    }
  }

  String _formatearFecha(dynamic raw) {
    final value = raw?.toString() ?? '';
    if (value.isEmpty) return '';
    final date = DateTime.tryParse(value);
    if (date == null) return '';
    return DateFormat('dd MMM, HH:mm', 'es').format(date);
  }

  ({String label, Color color, IconData icon}) _estadoVisual(
    Map<String, dynamic> venta,
  ) {
    final estado = venta['_queue_estado']?.toString() ?? 'pendiente';
    return switch (estado) {
      'fallida' => (
        label: 'Fallida',
        color: Colors.red,
        icon: Icons.error_outline_rounded,
      ),
      'procesando' => (
        label: 'Procesando',
        color: Colors.blue,
        icon: Icons.sync_rounded,
      ),
      _ => (
        label: 'Pendiente',
        color: Colors.orange,
        icon: Icons.schedule_rounded,
      ),
    };
  }

  Widget _buildVentaCard(Map<String, dynamic> venta) {
    final cliente = Map<String, dynamic>.from(
      venta['cliente'] as Map? ?? const <String, dynamic>{},
    );
    final clienteNombre = cliente['nombre']?.toString().trim();
    final detalles = List<dynamic>.from(venta['detalles'] as List? ?? const []);
    final total = venta['total_a_pagar'] ?? 0;
    final requestId = venta['request_id']?.toString() ?? '';
    final intentos = (venta['_queue_intentos'] as num?)?.toInt() ?? 0;
    final ultimoError = venta['_queue_ultimo_error']?.toString().trim();
    final ultimoErrorVisible = ultimoError?.isNotEmpty == true
        ? ErrorMapper.map(ultimoError)
        : null;
    final ultimoIntento = _formatearFecha(venta['_queue_ultimo_intento']);
    final fecha = _formatearFecha(venta['fecha']);
    final estado = _estadoVisual(venta);

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: estado.color.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: estado.color.withValues(alpha: 0.12),
                  child: Icon(estado.icon, color: estado.color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        clienteNombre?.isNotEmpty == true
                            ? clienteNombre!
                            : 'Cliente Final',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        [
                          if (fecha.isNotEmpty) fecha,
                          '${detalles.length} productos',
                        ].join(' • '),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  AppFormatters.currency(total),
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: estado.color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    estado.label,
                    style: TextStyle(
                      color: estado.color,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
                Text(
                  'Intentos: $intentos',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (ultimoIntento.isNotEmpty)
                  Text(
                    'Último: $ultimoIntento',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            if (ultimoErrorVisible != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Último intento: $ultimoErrorVisible',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.red.shade200
                        : Colors.red.shade800,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    requestId.isEmpty ? 'ID no disponible' : 'ID: $requestId',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey,
                      fontSize: 10,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  tooltip: 'Eliminar esta venta',
                  onPressed: _sincronizando || requestId.isEmpty
                      ? null
                      : () => _eliminarVenta(requestId),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: 600,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Row(
                    children: [
                      Icon(Icons.wifi_off_rounded, color: Colors.orange),
                      SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'Ventas Pendientes',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _sincronizando
                      ? null
                      : () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Los Tickets Internos creados sin conexión quedan protegidos '
              'hasta que el servidor confirme su sincronización.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: _cargando
                  ? const Center(child: CircularProgressIndicator())
                  : _ventas.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.cloud_done_rounded,
                            size: 50,
                            color: Colors.green.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'No hay ventas pendientes.',
                            style: TextStyle(fontSize: 16, color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: _ventas.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) =>
                          _buildVentaCard(_ventas[index]),
                    ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _sincronizando
                      ? null
                      : () => Navigator.pop(context),
                  child: const Text('Cerrar'),
                ),
                const SizedBox(width: 10),
                if (_ventas.isNotEmpty)
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 12,
                      ),
                    ),
                    icon: _sincronizando
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.sync_rounded, color: Colors.white),
                    label: Text(
                      _sincronizando ? 'Sincronizando...' : 'Sincronizar Todas',
                      style: const TextStyle(color: Colors.white),
                    ),
                    onPressed: _sincronizando ? null : _sincronizarTodas,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
