import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../shared/widgets/shimmer_detalle.dart';
import '../../../core/theme/app_colors.dart';

class VerPagoEmpleadoPage extends ConsumerStatefulWidget {
  final int pagoEmpleadoId;

  const VerPagoEmpleadoPage({super.key, required this.pagoEmpleadoId});

  @override
  ConsumerState<VerPagoEmpleadoPage> createState() =>
      _VerPagoEmpleadoPageState();
}

class _VerPagoEmpleadoPageState extends ConsumerState<VerPagoEmpleadoPage> {
  Map<String, dynamic>? _pago;
  bool _cargando = true;
  String? _errorCarga;

  final Color colorCabecera = AppColors.deudas;
  final Color colorEgreso = const Color(0xFFD32F2F);

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
      final data = await ref
          .read(empleadosRepositoryProvider)
          .obtenerDetallePago(widget.pagoEmpleadoId);

      if (!mounted) return;
      setState(() {
        _pago = data;
        _cargando = false;
        _errorCarga = null;
      });
    } catch (e) {
      debugPrint('No se pudo cargar el detalle del pago de empleado: $e');
      if (!mounted) return;
      setState(() {
        _pago = null;
        _cargando = false;
        _errorCarga = ErrorMapper.map(e);
      });
    }
  }

  Future<void> _eliminarPago() async {
    final confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("¿Anular este pago?"),
        content: const Text(
          "El dinero regresará a la caja y se eliminará el registro histórico.",
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
              "ELIMINAR",
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await ref
            .read(empleadosRepositoryProvider)
            .eliminarPagoEmpleado(widget.pagoEmpleadoId);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Pago eliminado correctamente")),
          );
          Navigator.pop(context);
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
            'Detalle de Pago',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          backgroundColor: colorCabecera,
          iconTheme: const IconThemeData(color: Colors.white),
          elevation: 0,
        ),
        body: const ShimmerDetalle(),
      );
    }
    if (_pago == null) {
      return Scaffold(
        backgroundColor: isDark
            ? Theme.of(context).scaffoldBackgroundColor
            : Colors.grey[100],
        appBar: AppBar(
          title: const Text(
            'Detalle de Pago',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          backgroundColor: colorCabecera,
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
                      'No pudimos cargar el detalle del pago. Inténtalo nuevamente.',
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

    final monto = (_pago!['monto'] as num).toDouble();
    final concepto = _pago!['concepto'] ?? 'Sin concepto';
    final metodo = _pago!['metodo'] ?? 'Efectivo';

    final empleadoNombre = _pago!['empleados']['nombre'];
    final empleadoCargo = _pago!['empleados']['cargo'] ?? 'Personal';

    return Scaffold(
      backgroundColor: isDark
          ? Theme.of(context).scaffoldBackgroundColor
          : Colors.grey[100],
      appBar: AppBar(
        title: const Text(
          'Detalle de Pago',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: colorCabecera,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
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
                      color: colorEgreso.withValues(alpha: 0.08),
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
                              "RECIBO #${_pago!['id']}",
                              style: TextStyle(
                                color: isDark
                                    ? Colors.grey[400]
                                    : Colors.grey[700],
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              AppFormatters.limaDateTimeText(
                                _pago!['fecha'],
                              ).replaceAll(' • ', ', '),
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: isDark
                                ? const Color(0xFF2A2A2A)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: colorEgreso.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Text(
                            "EGRESO",
                            style: TextStyle(
                              color: colorEgreso,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(25),
                    child: Column(
                      children: [
                        const Text(
                          "Monto Pagado",
                          style: TextStyle(color: Colors.grey, fontSize: 14),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          AppFormatters.currency(monto),
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                            color: colorEgreso,
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Divider(),
                        ),
                        _buildInfoRow(
                          Icons.person,
                          "Empleado",
                          empleadoNombre,
                          isDark,
                        ),
                        const SizedBox(height: 15),
                        _buildInfoRow(
                          Icons.work_outline,
                          "Cargo",
                          empleadoCargo,
                          isDark,
                        ),
                        const SizedBox(height: 15),
                        _buildInfoRow(
                          Icons.description,
                          "Concepto",
                          concepto,
                          isDark,
                        ),
                        const SizedBox(height: 15),
                        _buildInfoRow(
                          Icons.payment,
                          "Método de Pago",
                          metodo,
                          isDark,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: _eliminarPago,
                icon: const Icon(Icons.delete_forever, color: Colors.red),
                label: const Text(
                  "Anular / Eliminar Pago",
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  backgroundColor: Colors.red.withValues(alpha: 0.05),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String val, bool isDark) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 22, color: Colors.grey[400]),
        const SizedBox(width: 15),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 12, color: Colors.grey[500]),
              ),
              const SizedBox(height: 2),
              Text(
                val,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
