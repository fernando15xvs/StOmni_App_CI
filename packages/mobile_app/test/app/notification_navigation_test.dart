import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/app/notification_navigation.dart';

void main() {
  test('reconoce alertas de stock por payload moderno', () {
    expect(
      NotificationNavigationController.isStockAlertNotification(
        data: const {'stock_alert_type': 'stock_bajo'},
      ),
      isTrue,
    );
    expect(
      NotificationNavigationController.isStockAlertNotification(
        data: const {'stock_alert_type': 'agotado'},
      ),
      isTrue,
    );
    expect(
      NotificationNavigationController.isStockAlertNotification(
        data: const {'stock_alert_type': 'otro'},
      ),
      isFalse,
    );
  });

  test('mantiene compatibilidad con títulos antiguos', () {
    expect(
      NotificationNavigationController.isStockAlertNotification(
        title: '⚠️ Alerta de Stock Bajo',
      ),
      isTrue,
    );
    expect(
      NotificationNavigationController.isStockAlertNotification(
        title: '🚨 ¡Producto Agotado!',
      ),
      isTrue,
    );
    expect(
      NotificationNavigationController.isStockAlertNotification(
        title: 'Venta registrada',
      ),
      isFalse,
    );
  });

  test('extrae producto_id numérico o texto y rechaza ids inválidos', () {
    expect(
      NotificationNavigationController.productIdFromData(const {
        'producto_id': 42,
      }),
      42,
    );
    expect(
      NotificationNavigationController.productIdFromData(const {
        'producto_id': '57',
      }),
      57,
    );
    expect(
      NotificationNavigationController.productIdFromData(const {
        'producto_id': 0,
      }),
      isNull,
    );
    expect(
      NotificationNavigationController.productIdFromData(const {
        'producto_id': 'abc',
      }),
      isNull,
    );
  });

  test('tap queda pendiente hasta que Home registra un handler', () {
    final controller = NotificationNavigationController();
    var aperturas = 0;
    int? productoRecibido;

    final accepted = controller.requestFromNotification(
      data: const {'stock_alert_type': 'stock_bajo', 'producto_id': 123},
    );

    expect(accepted, isTrue);
    expect(controller.hasPendingStockAlert, isTrue);
    expect(aperturas, 0);

    controller.registerStockAlertHandler((productId) {
      aperturas++;
      productoRecibido = productId;
    });

    expect(controller.hasPendingStockAlert, isFalse);
    expect(aperturas, 1);
    expect(productoRecibido, 123);
  });

  test('notificación antigua navega sin exigir producto_id', () {
    final controller = NotificationNavigationController();
    int? productoRecibido = -1;

    controller.registerStockAlertHandler((productId) {
      productoRecibido = productId;
    });
    controller.requestFromNotification(title: '⚠️ Alerta de Stock Bajo');

    expect(productoRecibido, isNull);
  });

  test('un Home desmontado no consume taps posteriores', () {
    final controller = NotificationNavigationController();
    var aperturas = 0;
    int? productoRecibido;
    void handler(int? productId) {
      aperturas++;
      productoRecibido = productId;
    }

    controller.registerStockAlertHandler(handler);
    controller.unregisterStockAlertHandler(handler);

    controller.requestFromNotification(
      data: const {'stock_alert_type': 'agotado', 'producto_id': '88'},
    );

    expect(aperturas, 0);
    expect(controller.hasPendingStockAlert, isTrue);

    controller.registerStockAlertHandler(handler);
    expect(aperturas, 1);
    expect(productoRecibido, 88);
    expect(controller.hasPendingStockAlert, isFalse);
  });

  test('integración enfoca producto usando el inventario local-first', () {
    final bootstrap = File('lib/app/bootstrap.dart').readAsStringSync();
    final splash = File('lib/splash/splash_screen.dart').readAsStringSync();
    final postLogin = File(
      'lib/home/post_login_home_page.dart',
    ).readAsStringSync();
    final router = File('lib/app/app_router.dart').readAsStringSync();
    final navigation = File(
      'lib/app/notification_navigation.dart',
    ).readAsStringSync();

    expect(bootstrap, contains('OneSignal.Notifications.addClickListener'));
    expect(bootstrap, contains('requestFromNotification'));
    expect(navigation, contains('AlmacenPage(soloStockBajo: true)'));
    expect(navigation, contains('_focusLocalProduct(productId)'));
    expect(navigation, contains('almacenNotifierProvider'));
    expect(navigation, contains('almacenBusquedaProvider'));
    expect(navigation, contains("label: 'VER TODAS'"));
    expect(navigation, isNot(contains("Supabase.instance")));
    expect(navigation, isNot(contains(".from('productos')")));
    expect(splash, contains('StockAlertNotificationHost'));
    expect(postLogin, contains('enabled: _preparado'));
    expect(router, contains('StockAlertNotificationHost'));
  });
}
