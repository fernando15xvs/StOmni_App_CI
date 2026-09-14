import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../shared/widgets/shimmer_detalle.dart';

class VerGastoPage extends ConsumerStatefulWidget {
  final int gastoId;
  const VerGastoPage({super.key, required this.gastoId});

  @override
  ConsumerState<VerGastoPage> createState() => _VerGastoPageState();
}

class _VerGastoPageState extends ConsumerState<VerGastoPage> {
  Map<String, dynamic>? _gasto;
  List<Map<String, dynamic>> _pagos = [];
  bool _cargando = true;
  String? _errorCarga;

  // Colores
  final Color colorVerde = AppColors.deudas;
  final Color colorGasto = Colors.red;

  @override
  void initState() {
    super.initState();
    _cargarDatos();
  }

  Future<void> _cargarDatos() async {
    if (mounted) {
      setState(() {
        _cargando = true;
        _errorCarga = null;
      });
    }

    try {
      final repo = ref.read(gastosRepositoryProvider);
      final data = await repo.obtenerGastoCompleto(widget.gastoId);

      if (!mounted) return;
      setState(() {
        _gasto = data['gasto'];
        _pagos = List<Map<String, dynamic>>.from(data['pagos']);
        _cargando = false;
        _errorCarga = null;
      });
    } catch (e) {
      debugPrint('No se pudo cargar el detalle del gasto: $e');
      if (!mounted) return;
      setState(() {
        _gasto = null;
        _pagos = [];
        _cargando = false;
        _errorCarga = ErrorMapper.map(e);
      });
    }
  }

  // --- ELIMINAR UN SOLO PAGO ---
  Future<void> _eliminarAbonoIndividual(Map<String, dynamic> pago) async {
    final confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("¿Eliminar este pago?"),
        content: Text(
          "Se borrará el registro de S/ ${pago['monto']} y la deuda aumentará.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancelar"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Eliminar", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final monto = (pago['monto'] as num).toDouble();
      final saldoActual = (_gasto!['saldo'] as num).toDouble();

      await ref
          .read(gastosRepositoryProvider)
          .eliminarPago(pago['id'], widget.gastoId, monto, saldoActual);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Pago eliminado y saldo actualizado")),
        );
        _cargarDatos();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(e)),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // --- ELIMINAR GASTO COMPLETO ---
  Future<void> _eliminarGastoCompleto() async {
    final confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("¿Eliminar Gasto Completo?"),
        content: const Text(
          "Se borrará todo el registro, incluyendo historial de pagos y movimientos de caja.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancelar"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              "ELIMINAR TODO",
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await ref.read(gastosRepositoryProvider).eliminarGasto(widget.gastoId);

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Gasto eliminado correctamente")),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMapper.map(e)),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (_cargando) {
      return Scaffold(
        backgroundColor: isDark
            ? Theme.of(context).scaffoldBackgroundColor
            : Colors.grey[100],
        appBar: AppBar(
          title: const Text(
            'Detalle del Gasto',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          backgroundColor: colorVerde,
          iconTheme: const IconThemeData(color: Colors.white),
          elevation: 0,
        ),
        body: const ShimmerDetalle(),
      );
    }
    if (_gasto == null) {
      return Scaffold(
        backgroundColor: isDark
            ? Theme.of(context).scaffoldBackgroundColor
            : Colors.grey[100],
        appBar: AppBar(
          title: const Text(
            'Detalle del Gasto',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          backgroundColor: colorVerde,
          iconTheme: const IconThemeData(color: Colors.white),
          elevation: 0,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_outlined, size: 48),
                const SizedBox(height: 12),
                Text(
                  _errorCarga ??
                      'No pudimos cargar el detalle del gasto. Inténtalo nuevamente.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _cargarDatos,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reintentar'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final montoTotal = (_gasto!['monto'] as num).toDouble();
    final saldo = (_gasto!['saldo'] as num).toDouble();
    final pagado = montoTotal - saldo;
    final estado = _gasto!['estado'] ?? 'pendiente';
    final proveedor = _gasto!['proveedores'] != null
        ? _gasto!['proveedores']['nombre']
        : '---';

    return Scaffold(
      backgroundColor: isDark
          ? Theme.of(context).scaffoldBackgroundColor
          : Colors.grey[100],
      appBar: AppBar(
        title: const Text(
          'Detalle del Gasto',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: colorVerde,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // --- TARJETA PRINCIPAL ---
            Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: isDark
                    ? []
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: colorGasto.withValues(alpha: 0.05),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(20),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "GASTO #${_gasto!['id']}",
                              style: TextStyle(
                                color: isDark
                                    ? Colors.grey[400]
                                    : Colors.grey[600],
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              AppFormatters.limaDateText(_gasto!['fecha']),
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: estado == 'pagado'
                                ? Colors.green
                                : Colors.orange,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            estado.toString().toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        _buildInfoRow(
                          Icons.store,
                          "Proveedor",
                          proveedor,
                          isDark,
                        ),
                        const Divider(),
                        _buildInfoRow(
                          Icons.category,
                          "Categoría",
                          _gasto!['categoria'],
                          isDark,
                        ),
                        const Divider(),
                        _buildInfoRow(
                          Icons.description,
                          "Detalle",
                          _gasto!['descripcion'] ?? '-',
                          isDark,
                        ),
                        const SizedBox(height: 20),

                        // BARRA DE PROGRESO DE PAGO
                        Column(
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  "Pagado: ${AppFormatters.currency(pagado)}",
                                  style: const TextStyle(
                                    color: Colors.green,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  "Total: ${AppFormatters.currency(montoTotal)}",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: isDark
                                        ? Colors.white
                                        : Colors.black87,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),
                            LinearProgressIndicator(
                              value:
                                  pagado / (montoTotal == 0 ? 1 : montoTotal),
                              backgroundColor: Colors.red[100],
                              color: Colors.green,
                              minHeight: 10,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            if (saldo > 0)
                              Padding(
                                padding: const EdgeInsets.only(top: 5),
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    "Deuda: ${AppFormatters.currency(saldo)}",
                                    style: const TextStyle(
                                      color: Colors.red,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // --- LISTA DE PAGOS / GASTOS ---
            Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: isDark
                    ? []
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        ),
                      ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      "Historial de Gastos",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                  ),
                  const Divider(height: 1),

                  if (_pagos.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Center(
                        child: Text("No se han registrado pagos aún"),
                      ),
                    )
                  else
                    ..._pagos.map((p) {
                      final metodo = p['metodo'] ?? 'Desconocido';

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isDark
                              ? Colors.grey[800]
                              : Colors.grey[100],
                          child: Icon(
                            _getIconoPago(metodo),
                            color: isDark ? Colors.grey[300] : Colors.grey[700],
                            size: 20,
                          ),
                        ),
                        title: Text(
                          AppFormatters.currency((p['monto'] as num)),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        subtitle: Row(
                          children: [
                            Text(
                              metodo,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white70 : Colors.black87,
                              ),
                            ),
                            Text(
                              " • ",
                              style: TextStyle(
                                color: isDark ? Colors.grey[400] : Colors.grey,
                              ),
                            ),
                            Text(
                              AppFormatters.limaDateTime(
                                p['fecha'],
                              ).replaceAll(' • ', ' '),
                              style: TextStyle(
                                color: isDark
                                    ? Colors.grey[400]
                                    : Colors.grey[700],
                              ),
                            ),
                          ],
                        ),
                        trailing: IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.red,
                          ),
                          onPressed: () => _eliminarAbonoIndividual(p),
                        ),
                      );
                    }),
                ],
              ),
            ),

            const SizedBox(height: 30),

            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: _eliminarGastoCompleto,
                icon: const Icon(Icons.delete_forever, color: Colors.red),
                label: const Text(
                  "Eliminar Gasto Completo",
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String val, bool isDark) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.grey),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              Text(
                val,
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 15,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  IconData _getIconoPago(String metodo) {
    switch (metodo.toLowerCase()) {
      case 'efectivo':
        return Icons.money;
      case 'tarjeta':
        return Icons.credit_card;
      case 'transferencia':
        return Icons.account_balance;
      case 'yape':
        return Icons.smartphone;
      case 'plin':
        return Icons.local_atm;
      default:
        return Icons.payment;
    }
  }
}
