import 'package:core_logic/core_logic.dart';
import 'package:flutter/material.dart';
import 'package:mobile_app/core/theme/app_colors.dart';

// =====================================================================
// 1. TARJETA DE RESUMEN (Ingresos, Egresos y Balance)
// =====================================================================
class BalanceResumenCard extends StatelessWidget {
  final double balance;
  final double ingresos;
  final double egresos;
  final double descuentos;
  final VoidCallback onVerDetalle;

  const BalanceResumenCard({
    super.key,
    required this.balance,
    required this.ingresos,
    required this.egresos,
    required this.descuentos,
    required this.onVerDetalle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final negative = const Color(0xFFE65A60);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'BALANCE NETO',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            AppFormatters.currency(balance),
            style: theme.textTheme.headlineLarge?.copyWith(
              fontWeight: FontWeight.w900,
              color: balance < 0 ? negative : theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 18),
          const Divider(),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _InfoBox(
                  label: 'Ingresos',
                  valor: ingresos,
                  icon: Icons.arrow_circle_up_outlined,
                  color: primary,
                ),
              ),
              SizedBox(
                height: 56,
                child: VerticalDivider(color: theme.colorScheme.outline),
              ),
              Expanded(
                child: _InfoBox(
                  label: 'Egresos',
                  valor: egresos,
                  icon: Icons.arrow_circle_down_outlined,
                  color: negative,
                ),
              ),
            ],
          ),
          if (descuentos > 0) ...[
            const SizedBox(height: 10),
            Text('Descuentos: ${AppFormatters.currency(descuentos)}'),
          ],
          const SizedBox(height: 12),
          const Divider(),
          InkWell(
            onTap: onVerDetalle,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.bar_chart_outlined, color: primary),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Ver reporte',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Widget privado solo usado dentro del Resumen
class _InfoBox extends StatelessWidget {
  final String label;
  final double valor;
  final IconData icon;
  final Color color;

  const _InfoBox({
    required this.label,
    required this.valor,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.grey,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          AppFormatters.currency(valor),
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 18,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }
}

// =====================================================================
// 2. TABS ELEGANTES (Ingresos / Egresos)
// =====================================================================
class BalanceTabsHeader extends StatelessWidget {
  final TabController tabController;

  const BalanceTabsHeader({super.key, required this.tabController});

  @override
  Widget build(BuildContext context) {
    final Color primaryColor = Theme.of(context).colorScheme.primary;

    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.grey[900]!
            : Colors.grey[200],
        borderRadius: BorderRadius.circular(14),
      ),
      child: TabBar(
        controller: tabController,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        indicator: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.grey[800]!
              : Colors.white,
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        labelColor: primaryColor,
        unselectedLabelColor: Colors.grey[600],
        labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
        unselectedLabelStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
        tabs: const [
          Tab(text: "Ingresos"),
          Tab(text: "Egresos"),
        ],
      ),
    );
  }
}

// =====================================================================
// 3. LISTA DE MOVIMIENTOS
// =====================================================================
class MovimientosList extends StatefulWidget {
  final List<Map<String, dynamic>> movimientos;
  final String tipo;
  final Function(Map<String, dynamic>) onItemTap;
  final VoidCallback onRefresh;

  const MovimientosList({
    super.key,
    required this.movimientos,
    required this.tipo,
    required this.onItemTap,
    required this.onRefresh,
  });

  @override
  State<MovimientosList> createState() => _MovimientosListState();
}

class _MovimientosListState extends State<MovimientosList> {
  String _formatearMoneda(double monto) {
    return AppFormatters.currency(monto);
  }

  @override
  Widget build(BuildContext context) {
    final Color primaryColor = Theme.of(context).brightness == Brightness.dark
        ? Colors.greenAccent
        : Theme.of(context).colorScheme.primary;
    final Color textColor = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : const Color(0xFF1E293B);
    final Color redColor = Theme.of(context).brightness == Brightness.dark
        ? Colors.redAccent
        : Colors.red.shade700;

    final filtrados = widget.movimientos
        .where((m) => m['tipo'] == widget.tipo)
        .toList();
    if (filtrados.isEmpty) {
      final isIncome = widget.tipo == 'ingreso';
      return RefreshIndicator(
        onRefresh: () async => widget.onRefresh(),
        color: primaryColor,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(
                          color: Theme.of(context).cardColor,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                        child: Icon(
                          Icons.receipt_long_outlined,
                          size: 40,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'No hay movimientos en esta fecha',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isIncome
                            ? 'Aún no hay ingresos registrados para este día.'
                            : 'Aún no hay egresos registrados para este día.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => widget.onRefresh(),
      color: primaryColor,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(
          bottom: 160,
          top: 15,
          left: 16,
          right: 16,
        ),
        itemCount: filtrados.length,
        itemBuilder: (context, i) {
          final item = filtrados[i];
          final esIngreso = widget.tipo == 'ingreso';
          final descripcion = item['descripcion'] ?? 'Sin descripción';
          final monto = (item['monto'] as num).toDouble();

          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => widget.onItemTap(item),
              child: Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.transparent
                        : Colors.grey.shade100,
                  ),
                  boxShadow: [
                    if (Theme.of(context).brightness == Brightness.light)
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.02),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        color: esIngreso
                            ? primaryColor.withValues(alpha: 0.1)
                            : Colors.red.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        esIngreso
                            ? Icons.trending_up_rounded
                            : Icons.trending_down_rounded,
                        color: esIngreso ? primaryColor : Colors.red,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            descripcion,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                              color: textColor,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            AppFormatters.limaDateTime(item['fecha']),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[500],
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          "${esIngreso ? '+' : '-'} ${_formatearMoneda(monto)}",
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 15,
                            color: esIngreso ? primaryColor : redColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Text(
                              "Ver detalle",
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade400,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 15,
                              color: Colors.grey.shade400,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// =====================================================================
// 4. BOTÓN ELEGANTE PARA EL APPBAR (PC)
// =====================================================================
class EleganteActionBoton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const EleganteActionBoton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

// =====================================================================
// 5. ITEM DE MENÚ DESPLEGABLE ELEGANTE
// =====================================================================
PopupMenuItem<String> buildMenuItemElegante({
  required BuildContext context,
  required String value,
  required IconData icon,
  required Color iconColor,
  required String text,
  bool isSelected = false,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return PopupMenuItem(
    value: value,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isSelected ? iconColor : iconColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: isSelected ? Colors.white : iconColor,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            text,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
              color: isSelected
                  ? (isDark ? Colors.greenAccent : AppColors.primary)
                  : (isDark ? Colors.white : Colors.black87),
              fontSize: 14,
            ),
          ),
        ],
      ),
    ),
  );
}

// =====================================================================
// 6. ITEM DE MOVIMIENTO DE CAJA CHICA (Reutilizable)
// =====================================================================
class ItemMovimientoCaja extends StatelessWidget {
  final Map<String, dynamic> movimiento;
  final bool compact;

  const ItemMovimientoCaja({
    super.key,
    required this.movimiento,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final esIngreso = movimiento['tipo'] == 'ingreso';
    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    final colorVerde = Theme.of(context).colorScheme.primary;
    final primaryColor = esIngreso ? colorVerde : Colors.redAccent;
    final descripcion =
        movimiento['descripcion'] ??
        (esIngreso ? 'Ingreso Efectivo' : 'Egreso Efectivo');
    final montoStr =
        "${esIngreso ? '+' : '-'} ${AppFormatters.currency((movimiento['monto'] as num).toDouble())}";

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: EdgeInsets.all(compact ? 8.0 : 12.0),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: compact && !isDark
            ? Border.all(color: Colors.grey.shade200)
            : null,
        boxShadow: (isDark || compact)
            ? []
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 5,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Row(
        children: [
          if (compact)
            Icon(
              esIngreso ? Icons.arrow_downward : Icons.arrow_upward,
              color: primaryColor,
              size: 16,
            )
          else
            CircleAvatar(
              backgroundColor: primaryColor.withValues(alpha: 0.1),
              child: Icon(
                esIngreso ? Icons.arrow_downward : Icons.arrow_upward,
                color: primaryColor,
              ),
            ),
          SizedBox(width: compact ? 10 : 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  descripcion,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: compact ? 13 : 14,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: compact ? 2 : 4),
                Text(
                  compact
                      ? AppFormatters.limaTime(movimiento['fecha'])
                      : AppFormatters.limaDateTime(movimiento['fecha']),
                  style: TextStyle(
                    color: isDark ? Colors.grey[400] : Colors.grey[500],
                    fontSize: compact ? 11 : 12,
                  ),
                ),
              ],
            ),
          ),
          Text(
            montoStr,
            style: TextStyle(
              color: primaryColor,
              fontWeight: FontWeight.bold,
              fontSize: compact ? 14 : 16,
            ),
          ),
        ],
      ),
    );
  }
}
