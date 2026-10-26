import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';
import '../core/theme/appearance_controller.dart';
import '../core/theme/stomni_mobile_theme.dart';
import '../splash/splash_screen.dart';
import 'app_lifecycle.dart';
import 'app_router.dart';

class StOmniApp extends ConsumerWidget {
  const StOmniApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeStr = ref.watch(preferencesProvider).themeMode;
    final appearance = ref.watch(appearanceProvider);
    ThemeMode themeMode = ThemeMode.system;
    if (themeStr == 'light') themeMode = ThemeMode.light;
    if (themeStr == 'dark') themeMode = ThemeMode.dark;

    return AppLifecycleObserver(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'StOmni',
        debugShowCheckedModeBanner: false,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('es', 'ES')],
        themeMode: themeMode,
        theme: StOmniMobileTheme.create(
          accent: AccentPalette.colorAt(appearance.accentIndex),
          brightness: Brightness.light,
          highContrast: appearance.highContrast,
        ),
        darkTheme: StOmniMobileTheme.create(
          accent: AccentPalette.colorAt(appearance.accentIndex),
          brightness: Brightness.dark,
          highContrast: appearance.highContrast,
        ),
        routes: buildAppRoutes(),
        home: const SplashScreen(),
      ),
    );
  }
}
