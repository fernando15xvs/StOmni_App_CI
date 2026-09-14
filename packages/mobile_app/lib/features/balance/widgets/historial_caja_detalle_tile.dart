import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:core_logic/core_logic.dart';
import 'package:mobile_app/platform/documents/mobile_document_output.dart';
import 'package:mobile_app/platform/documents/pdf_branding_loader.dart';
import 'balance_widgets.dart';

class HistorialCajaDetalleTile extends ConsumerStatefulWidget {
  const HistorialCajaDetalleTile({super.key, required this.s});

  final Map<String, dynamic> s;

  @override
  ConsumerState<HistorialCajaDetalleTile> createState() =>
      _HistorialCajaDetalleTileState();
}

class _HistorialCajaDetalleTileState
    extends ConsumerState<HistorialCajaDetalleTile> {
  bool _expandido = false;
  bool _cargandoMovs = false;
  bool _imprimiendo = false;
  List<Map<String, dynamic>> _movimientos = const [];

  Future<void> _cargarMovimientos() async {
    if (_movimientos.isNotEmpty) return;
    setState(() => _cargandoMovs = true);
    try {
      final fechaApertura = toLima(widget.s['fecha_apertura']);
      final fechaCierre = toLima(widget.s['fecha_cierre']);
      final data = await ref
          .read(balanceRepositoryProvider)
          .getMovimientosByFechas(fechaApertura, fechaCierre);
      if (mounted) setState(() => _movimientos = data);
    } finally {
      if (mounted) setState(() => _cargandoMovs = false);
    }
  }

  Future<void> _imprimir() async {
    if (_imprimiendo) return;
    setState(() => _imprimiendo = true);
    try {
      final service = ref.read(cajaCierrePdfServiceProvider);
      final branding = await PdfBrandingLoader.load();
      final document = await service.generar(
        widget.s, branding: branding, ticketSize: PreferencesService.ticketSize,
      );
      if (!mounted) return;
      await documentOutputFor(context).deliver(document, action: DocumentOutputAction.print);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ErrorMapper.map(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _imprimiendo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final apertura = toLima(s['fecha_apertura']);
    final cierre = toLima(s['fecha_cierre']);
    final esperado = (s['monto_cierre_esperado'] as num).toDouble();
    final real = (s['monto_cierre_real'] as num).toDouble();
    final diferencia = real - esperado;
    final badgeColor = diferencia == 0
        ? Theme.of(context).colorScheme.primary
        : (diferencia > 0 ? Colors.blue : Colors.red);
    final badgeText = diferencia == 0
        ? 'CUADRE'
        : (diferencia > 0 ? 'SOBRANTE' : 'FALTANTE');
    final badgeIcon = diferencia == 0
        ? Icons.check_circle
        : (diferencia > 0 ? Icons.arrow_upward : Icons.arrow_downward);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: isDark
            ? const []
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        shape: const Border(),
        onExpansionChanged: (expanded) {
          setState(() => _expandido = expanded);
          if (expanded) _cargarMovimientos();
        },
        leading: CircleAvatar(
          backgroundColor: badgeColor.withValues(alpha: 0.1),
          child: Icon(badgeIcon, color: badgeColor),
        ),
        title: Text(
          DateFormat('dd/MM/yyyy').format(apertura),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : Colors.black87,
          ),
        ),
        subtitle: Text(
          '${DateFormat('hh:mm a').format(apertura)} - ${DateFormat('hh:mm a').format(cierre)}',
          style: TextStyle(color: isDark ? Colors.grey[400] : Colors.grey[600]),
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: badgeColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            badgeText,
            style: TextStyle(
              color: badgeColor,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            color: isDark ? const Color(0xFF121212) : Colors.grey[50],
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildRow(
                  'Monto Inicial:',
                  (s['monto_apertura'] as num).toDouble(),
                  isDark,
                ),
                const Divider(),
                _buildRow('Total Esperado:', esperado, isDark),
                _buildRow('Total Contado:', real, isDark),
                const SizedBox(height: 10),
                _buildRow(
                  'Diferencia:',
                  diferencia.abs(),
                  isDark,
                  color: badgeColor,
                  prefix: diferencia == 0 ? '' : (diferencia > 0 ? '+' : '-'),
                ),
                if (s['observaciones'] != null &&
                    s['observaciones'].toString().isNotEmpty) ...[
                  const SizedBox(height: 15),
                  Text(
                    'Observaciones:',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.grey[400] : Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                      border: Border.all(
                        color: isDark ? Colors.grey[800]! : Colors.grey[300]!,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      s['observaciones'].toString(),
                      style: TextStyle(
                        fontStyle: FontStyle.italic,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                  ),
                ],
                if (_expandido) ...[
                  const SizedBox(height: 20),
                  const Text(
                    'Detalle de Movimientos en Efectivo',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                  const SizedBox(height: 10),
                  if (_cargandoMovs)
                    const Center(child: CircularProgressIndicator())
                  else if (_movimientos.isEmpty)
                    const Text(
                      'No se registraron movimientos en este turno.',
                      style: TextStyle(
                        color: Colors.grey,
                        fontStyle: FontStyle.italic,
                      ),
                    )
                  else ...[
                    _resumenMovimientos(context),
                    const SizedBox(height: 10),
                    ..._movimientos.map(
                      (movimiento) => ItemMovimientoCaja(
                        movimiento: movimiento,
                        compact: true,
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _imprimiendo ? null : _imprimir,
                    icon: _imprimiendo
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.receipt_long),
                    label: Text(_imprimiendo ? 'Preparando...' : 'Imprimir Ticket'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      side: BorderSide(
                        color: isDark
                            ? Colors.greenAccent
                            : Theme.of(context).colorScheme.primary,
                      ),
                      foregroundColor: isDark
                          ? Colors.greenAccent
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _resumenMovimientos(BuildContext context) {
    double ingresos = 0;
    double egresos = 0;
    for (final movimiento in _movimientos) {
      final monto = (movimiento['monto'] as num).toDouble();
      if (movimiento['tipo'] == 'ingreso') {
        ingresos += monto;
      } else {
        egresos += monto;
      }
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Ingresos: ${AppFormatters.currency(ingresos)}',
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
        Text(
          'Egresos: ${AppFormatters.currency(egresos)}',
          style: const TextStyle(
            color: Colors.redAccent,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ],
    );
  }

  Widget _buildRow(
    String label,
    double amount,
    bool isDark, {
    Color? color,
    String prefix = '',
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          Text(
            '$prefix ${AppFormatters.currency(amount)}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: color ?? (isDark ? Colors.white : Colors.black87),
            ),
          ),
        ],
      ),
    );
  }
}
