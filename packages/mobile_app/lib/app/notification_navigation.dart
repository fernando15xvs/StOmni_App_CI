import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/services/notification_controller.dart';
export 'package:core_logic/services/notification_controller.dart';

import '../features/almacen/pages/almacen_page.dart';
import '../features/almacen/presentation/controllers/almacen_controller.dart';
import '../platform/notifications/notification_permission_service.dart';

/// Host que habilita la navegación de una notificación solamente cuando la
/// pantalla principal ya está disponible y la sesión fue autorizada.
class StockAlertNotificationHost extends ConsumerStatefulWidget {
  final Widget child;
  final bool enabled;

  const StockAlertNotificationHost({
    super.key,
    required this.child,
    this.enabled = true,
  });

  @override
  ConsumerState<StockAlertNotificationHost> createState() =>
      _StockAlertNotificationHostState();
}

class _StockAlertNotificationHostState
    extends ConsumerState<StockAlertNotificationHost> {
  late final StockAlertNavigationHandler _handler;
  bool _openingStockAlert = false;

  @override
  void initState() {
    super.initState();
    _handler = _handleStockAlertRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncRegistration());
  }

  @override
  void didUpdateWidget(covariant StockAlertNotificationHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncRegistration());
    }
  }

  @override
  void dispose() {
    notificationNavigation.unregisterStockAlertHandler(_handler);
    super.dispose();
  }

  void _syncRegistration() {
    if (!mounted) return;

    if (widget.enabled && !_openingStockAlert) {
      notificationNavigation.registerStockAlertHandler(_handler);
      unawaited(NotificationPermissionService.maybeExplainAndRequest(context));
    } else {
      notificationNavigation.unregisterStockAlertHandler(_handler);
    }
  }

  void _handleStockAlertRequest(int? productId) {
    if (!mounted || !widget.enabled || _openingStockAlert) return;

    _openingStockAlert = true;
    notificationNavigation.unregisterStockAlertHandler(_handler);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _openingStockAlert = false;
        return;
      }
      unawaited(_openStockAlertPage(productId));
    });
  }

  Future<void> _openStockAlertPage(int? productId) async {
    final previousSearch = ref.read(almacenBusquedaProvider);
    ref.read(almacenBusquedaProvider.notifier).state = '';

    try {
      final routeFuture = Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const AlmacenPage(soloStockBajo: true),
          settings: const RouteSettings(name: '/stock-alerts'),
        ),
      );

      if (productId != null) {
        // AlmacenPage limpia el buscador en su primer frame. Esperamos a que
        // termine ese montaje y luego aplicamos el foco usando el mismo
        // snapshot local-first que ya alimenta a Inventario.
        await Future<void>.delayed(const Duration(milliseconds: 180));
        if (mounted) {
          _focusLocalProduct(productId);
        }
      }

      await routeFuture;
    } finally {
      if (mounted) {
        ref.read(almacenBusquedaProvider.notifier).state = previousSearch;
        _openingStockAlert = false;
        _syncRegistration();
      }
    }
  }

  void _focusLocalProduct(int productId) {
    final state = ref.read(almacenNotifierProvider).value;
    if (state == null) return;

    Map<String, dynamic>? product;
    for (final candidate in state.productosCompletos) {
      final id =
          (candidate['id'] as num?)?.toInt() ??
          int.tryParse(candidate['id']?.toString() ?? '');
      if (id == productId) {
        product = candidate;
        break;
      }
    }
    if (product == null) return;

    final stock = (product['_totalStock'] as num?)?.toInt() ?? 0;
    final minimum = (product['stock_minimo'] as num?)?.toInt() ?? 0;
    final name = (product['nombre'] ?? 'Producto').toString().trim();

    if (stock > minimum) {
      _showResolvedProductMessage(name);
      return;
    }

    final code = (product['codigo'] ?? '').toString().trim();
    final barcode = (product['codigo_barras'] ?? '').toString().trim();
    final focusQuery = code.isNotEmpty
        ? code
        : (barcode.isNotEmpty ? barcode : name);

    if (focusQuery.isNotEmpty) {
      ref.read(almacenBusquedaProvider.notifier).state = focusQuery;
    }
    _showFocusedProductMessage(name);
  }

  void _showFocusedProductMessage(String productName) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Mostrando "$productName" de la notificación.'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'VER TODAS',
            onPressed: () {
              ref.read(almacenBusquedaProvider.notifier).state = '';
            },
          ),
        ),
      );
  }

  void _showResolvedProductMessage(String productName) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            'El stock de "$productName" ya fue actualizado y ya no está en alerta.',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
