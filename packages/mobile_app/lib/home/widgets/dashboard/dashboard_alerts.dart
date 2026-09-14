import 'package:flutter/material.dart';

import 'package:core_logic/core_logic.dart';
import '../../../features/almacen/pages/almacen_page.dart';
import '../../../features/deudas/pages/deudas_page.dart';

class DashboardAlerts extends StatelessWidget {
  final bool cargando;
  final bool resumenDisponible;
  final double deudasPorPagar;
  final int lowStockCount;
  final int outOfStockCount;
  final double deudasPorCobrar;
  final void Function(Widget) onNavigate;

  const DashboardAlerts({
    super.key,
    required this.cargando,
    required this.resumenDisponible,
    required this.deudasPorPagar,
    required this.lowStockCount,
    required this.outOfStockCount,
    required this.deudasPorCobrar,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    if (cargando || !resumenDisponible) return const SizedBox.shrink();

    final List<Widget> alertas = [];
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (deudasPorPagar > 0) {
      alertas.add(
        _AlertaItem(
          icon: Icons.payments_outlined,
          iconColor: isDark ? Colors.red.shade400 : Colors.red.shade700,
          colorFondo: isDark
              ? Colors.red.withValues(alpha: 0.15)
              : Colors.red.shade50,
          borderColor: isDark
              ? Colors.red.withValues(alpha: 0.3)
              : Colors.red.shade200,
          mensaje:
              "Debes pagar ${AppFormatters.currency(deudasPorPagar, decimalDigits: 0)} a proveedores.",
          accionText: "Pagar proveedores",
          textoColor: Colors.red.shade900,
          onTap: () => onNavigate(const DeudasPage(initialTabIndex: 1)),
        ),
      );
    }

    if (lowStockCount > 0 || outOfStockCount > 0) {
      String mensajeStock = "";
      if (lowStockCount > 0 && outOfStockCount > 0) {
        mensajeStock =
            "$lowStockCount productos con stock bajo y $outOfStockCount productos sin stock.";
      } else if (lowStockCount > 0) {
        mensajeStock = "$lowStockCount productos con stock bajo.";
      } else {
        mensajeStock = "$outOfStockCount productos sin stock.";
      }

      alertas.add(
        _AlertaItem(
          icon: Icons.warning_amber_rounded,
          iconColor: isDark ? Colors.orange.shade400 : Colors.orange.shade800,
          colorFondo: isDark
              ? Colors.orange.withValues(alpha: 0.15)
              : Colors.orange.shade50,
          borderColor: isDark
              ? Colors.orange.withValues(alpha: 0.3)
              : Colors.orange.shade200,
          mensaje: mensajeStock,
          accionText: "Ver inventario",
          textoColor: Colors.orange.shade900,
          onTap: () => onNavigate(const AlmacenPage(soloStockBajo: true)),
        ),
      );
    }

    if (deudasPorCobrar > 0) {
      alertas.add(
        _AlertaItem(
          icon: Icons.monetization_on_outlined,
          iconColor: isDark ? Colors.indigo.shade400 : Colors.indigo.shade700,
          colorFondo: isDark
              ? Colors.indigo.withValues(alpha: 0.15)
              : Colors.indigo.shade50,
          borderColor: isDark
              ? Colors.indigo.withValues(alpha: 0.3)
              : Colors.indigo.shade200,
          mensaje:
              "Tienes ${AppFormatters.currency(deudasPorCobrar, decimalDigits: 0)} pendientes de cobro.",
          accionText: "Cobrar ahora",
          textoColor: Colors.indigo.shade900,
          onTap: () => onNavigate(const DeudasPage()),
        ),
      );
    }

    if (alertas.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: alertas
          .map(
            (alerta) => Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: alerta,
            ),
          )
          .toList(),
    );
  }
}

class _AlertaItem extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color colorFondo;
  final Color borderColor;
  final String mensaje;
  final String accionText;
  final Color textoColor;
  final VoidCallback onTap;

  const _AlertaItem({
    required this.icon,
    required this.iconColor,
    required this.colorFondo,
    required this.borderColor,
    required this.mensaje,
    required this.accionText,
    required this.textoColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorTextoOscuro =
        Theme.of(context).textTheme.bodyLarge?.color ?? const Color(0xFF1E293B);

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(20),
        border: isDark ? null : Border.all(color: Colors.grey.shade100),
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: iconColor.withValues(alpha: 0.08),
                  blurRadius: 15,
                  offset: const Offset(0, 6),
                ),
              ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          highlightColor: colorFondo.withValues(alpha: 0.3),
          splashColor: colorFondo.withValues(alpha: 0.5),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: colorFondo,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: iconColor, size: 26),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mensaje,
                        style: TextStyle(
                          color: colorTextoOscuro,
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Text(
                            accionText,
                            style: TextStyle(
                              color: iconColor,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.arrow_forward_rounded,
                            color: iconColor,
                            size: 14,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
