import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';
import '../core/theme/app_colors.dart';
import '../splash/splash_screen.dart';
import 'app_lifecycle.dart';
import 'app_router.dart';

class StOmniApp extends ConsumerWidget {
  const StOmniApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeStr = ref.watch(preferencesProvider).themeMode;
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
        theme: ThemeData(
          primaryColor: AppColors.primary,
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFFF8FAFC),
          cardColor: Colors.white,
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppColors.primary,
            surface: Colors.white,
          ),
          appBarTheme: const AppBarTheme(backgroundColor: AppColors.primary),
        ),
        darkTheme: ThemeData.dark().copyWith(
          primaryColor: AppColors.primary,
          scaffoldBackgroundColor: const Color(0xFF000000), // OLED Black
          cardColor: const Color(0xFF050505), // Deep Black
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppColors.primary,
            brightness: Brightness.dark,
            primary: const Color(0xFF005346),
            surface: const Color(0xFF050505), // Deep Black
          ),
          appBarTheme: const AppBarTheme(backgroundColor: AppColors.primary),
        ),
        routes: buildAppRoutes(),
        home: const SplashScreen(),
      ),
    );
  }
}
