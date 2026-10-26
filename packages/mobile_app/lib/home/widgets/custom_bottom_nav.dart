import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/appearance_controller.dart';
import '../controllers/home_controller.dart';

class CustomBottomNav extends ConsumerWidget {
  const CustomBottomNav({
    super.key,
    required this.dragNotifier,
    this.inventoryEnabled = true,
  });

  final ValueNotifier<double?> dragNotifier;
  final bool inventoryEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = [
      const _NavItem(0, Icons.home_outlined, 'Inicio'),
      const _NavItem(1, Icons.account_balance_wallet_outlined, 'Balance'),
      if (inventoryEnabled)
        const _NavItem(2, Icons.inventory_2_outlined, 'Inventario'),
      const _NavItem(3, Icons.grid_view_rounded, 'Centro'),
      if (inventoryEnabled)
        const _NavItem(4, Icons.swap_horiz_rounded, 'Movimientos'),
    ];
    final theme = Theme.of(context);
    final current = ref.watch(homeTabProvider);
    final appearance = ref.watch(appearanceProvider);
    final accent = theme.colorScheme.primary;
    final outline = theme.colorScheme.outline.withValues(alpha: 0.65);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Container(
          height: 70,
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: outline),
          ),
          child: Row(
            children: [
              for (final item in items)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: current == item.index,
                    label: item.label,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () {
                        if (current == item.index) return;
                        HapticFeedback.selectionClick();
                        ref.read(homeTabProvider.notifier).state = item.index;
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 6,
                          horizontal: 2,
                        ),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            color: current == item.index
                                ? (appearance.colorNavigation
                                      ? (appearance.reduceTransparency
                                          ? Color.lerp(theme.cardColor, accent, 0.16)!
                                          : accent.withValues(alpha: 0.13))
                                      : (appearance.reduceTransparency
                                          ? Color.lerp(theme.cardColor, theme.colorScheme.onSurface, 0.08)!
                                          : theme.colorScheme.onSurface.withValues(alpha: 0.08)))
                                : Colors.transparent,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                item.icon,
                                size: 23,
                                color: current == item.index
                                    ? (appearance.colorNavigation
                                          ? accent
                                          : theme.colorScheme.onSurface)
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: current == item.index
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: current == item.index
                                      ? (appearance.colorNavigation
                                            ? accent
                                            : theme.colorScheme.onSurface)
                                      : theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  const _NavItem(this.index, this.icon, this.label);
  final int index;
  final IconData icon;
  final String label;
}
