import 'package:flutter/material.dart';

import '../home/home_page.dart';
import 'notification_navigation.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Map<String, WidgetBuilder> buildAppRoutes() {
  return {
    '/home': (context) {
      final arguments = ModalRoute.of(context)?.settings.arguments;
      final initialTab = arguments is Map<String, dynamic>
          ? arguments['pestanaInicial'] as int? ?? 0
          : 0;
      return StockAlertNotificationHost(
        child: HomePage(pestanaInicial: initialTab),
      );
    },
  };
}
