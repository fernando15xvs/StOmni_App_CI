import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/home_controller.dart';

class CustomBottomNav extends ConsumerWidget {
  const CustomBottomNav({
    super.key,
    required this.dragNotifier,
    this.inventoryEnabled = true,
  });

  final ValueNotifier<double?> dragNotifier;
  final bool inventoryEnabled;

  List<_HomeNavItem> get _items => [
    const _HomeNavItem(0, Icons.home_filled, 'Inicio'),
    const _HomeNavItem(1, Icons.account_balance_wallet_rounded, 'Balance'),
    if (inventoryEnabled) ...const [
      _HomeNavItem(2, Icons.inventory_2_rounded, 'Almacén'),
      _HomeNavItem(3, Icons.swap_horiz_rounded, 'Movimientos'),
    ],
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = _items;
    final currentIndex = ref.watch(homeTabProvider);
    final selectedPosition = items.indexWhere(
      (item) => item.index == currentIndex,
    );
    final safeSelectedPosition = selectedPosition < 0 ? 0 : selectedPosition;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorPrincipal = isDark
        ? Colors.greenAccent
        : Theme.of(context).colorScheme.primary;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(left: 12, right: 12, bottom: 16),
        child: GestureDetector(
          onPanUpdate: (details) {
            final width = MediaQuery.of(context).size.width - 24;
            final dx = details.localPosition.dx.clamp(0.0, width);
            final position = (dx / (width / items.length)).floor().clamp(
              0,
              items.length - 1,
            );
            final target = items[position].index;
            dragNotifier.value = items.length == 1
                ? 0
                : -1.0 + ((position / (items.length - 1)) * 2.0);
            if (target != currentIndex) {
              HapticFeedback.selectionClick();
              ref.read(homeTabProvider.notifier).state = target;
            }
          },
          onPanEnd: (_) => dragNotifier.value = null,
          onPanCancel: () => dragNotifier.value = null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                height: 65,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.12)
                        : Colors.white.withValues(alpha: 0.8),
                    width: 1.5,
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: isDark
                        ? [
                            Colors.white.withValues(alpha: 0.15),
                            Colors.white.withValues(alpha: 0.05),
                          ]
                        : [
                            Colors.white.withValues(alpha: 0.20),
                            Colors.white.withValues(alpha: 0.05),
                          ],
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ValueListenableBuilder<double?>(
                        valueListenable: dragNotifier,
                        builder: (context, dragX, child) {
                          final targetAlignment = items.length == 1
                              ? 0.0
                              : -1.0 +
                                    (safeSelectedPosition *
                                        (2.0 / (items.length - 1)));
                          return AnimatedAlign(
                            duration: dragX == null
                                ? const Duration(milliseconds: 280)
                                : Duration.zero,
                            curve: Curves.easeOutCubic,
                            alignment: Alignment(dragX ?? targetAlignment, 0),
                            child: child,
                          );
                        },
                        child: FractionallySizedBox(
                          widthFactor: 1 / items.length,
                          heightFactor: 1,
                          child: Center(
                            child: Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: colorPrincipal.withValues(alpha: 0.12),
                                border: Border.all(
                                  color: colorPrincipal.withValues(alpha: 0.18),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        for (final item in items)
                          Expanded(
                            child: _buildNavItem(
                              item,
                              currentIndex,
                              colorPrincipal,
                              ref,
                              context,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(
    _HomeNavItem item,
    int currentIndex,
    Color colorPrincipal,
    WidgetRef ref,
    BuildContext context,
  ) {
    final isSelected = currentIndex == item.index;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inactive = isDark ? Colors.white54 : Colors.grey.shade500;
    final color = isSelected ? colorPrincipal : inactive;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (!isSelected) {
          HapticFeedback.lightImpact();
          ref.read(homeTabProvider.notifier).state = item.index;
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedScale(
              scale: isSelected ? 1.18 : 1,
              duration: const Duration(milliseconds: 250),
              child: Icon(item.icon, color: color, size: 24),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              height: isSelected ? 3 : 0,
            ),
            AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: isSelected ? 1 : 0,
              child: Text(
                item.label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeNavItem {
  const _HomeNavItem(this.index, this.icon, this.label);

  final int index;
  final IconData icon;
  final String label;
}
