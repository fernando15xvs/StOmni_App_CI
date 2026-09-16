typedef StockAlertNavigationHandler = void Function(int? productId);

class NotificationNavigationController {
  bool _pendingStockAlert = false;
  int? _pendingProductId;
  StockAlertNavigationHandler? _stockAlertHandler;

  bool requestFromNotification({Map<String, dynamic>? data, String? title}) {
    if (!isStockAlertNotification(data: data, title: title)) {
      return false;
    }

    _pendingStockAlert = true;
    _pendingProductId = productIdFromData(data);
    _dispatchStockAlertIfReady();
    return true;
  }

  void registerStockAlertHandler(StockAlertNavigationHandler handler) {
    _stockAlertHandler = handler;
    _dispatchStockAlertIfReady();
  }

  void unregisterStockAlertHandler(StockAlertNavigationHandler handler) {
    if (identical(_stockAlertHandler, handler)) {
      _stockAlertHandler = null;
    }
  }

  bool get hasPendingStockAlert => _pendingStockAlert;

  static int? productIdFromData(Map<String, dynamic>? data) {
    final raw = data?['producto_id'];
    final parsed = raw is num
        ? raw.toInt()
        : int.tryParse(raw?.toString().trim() ?? '');
    return parsed != null && parsed > 0 ? parsed : null;
  }

  static bool isStockAlertNotification({
    Map<String, dynamic>? data,
    String? title,
  }) {
    final type = data?['stock_alert_type']?.toString().trim().toLowerCase();
    if (type == 'stock_bajo' || type == 'agotado') {
      return true;
    }

    // Compatibilidad con notificaciones antiguas emitidas antes de agregar
    // stock_alert_type al payload.
    final normalizedTitle = title?.trim().toLowerCase() ?? '';
    return normalizedTitle.contains('stock bajo') ||
        normalizedTitle.contains('producto agotado');
  }

  void _dispatchStockAlertIfReady() {
    final handler = _stockAlertHandler;
    if (!_pendingStockAlert || handler == null) return;

    final productId = _pendingProductId;
    _pendingStockAlert = false;
    _pendingProductId = null;
    handler(productId);
  }
}

final notificationNavigation = NotificationNavigationController();
