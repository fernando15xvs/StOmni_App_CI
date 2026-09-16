import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';

import '../auth/pages/cambiar_password_page.dart';
import '../auth/pages/login_page.dart';
import '../home/controllers/home_warmup_coordinator.dart';
import '../onboarding/saas_entry_gate.dart';
import 'widgets/app_version_text.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  double _opacity = 0.0;
  double _yOffset = 30.0;

  final Color colorMarca = const Color(0xFF1B3A6F);
  final Color colorAcento = const Color(0xFF0F9D58);

  @override
  void initState() {
    super.initState();

    Future.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {
        _opacity = 1.0;
        _yOffset = 0.0;
      });
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_navegarSiguientePantalla());
    });
  }

  Future<void> _navegarSiguientePantalla() async {
    final minimoSplash = Future<void>.delayed(const Duration(seconds: 3));
    final result = await ref
        .read(authControllerProvider.notifier)
        .restoreSession();

    if (result.isAuthorized) {
      final coordinator = ref.read(homeWarmupCoordinatorProvider);
      coordinator.clearSessionCaches();
      await Future.any<void>([
        coordinator.warmUp(),
        Future<void>.delayed(const Duration(seconds: 5)),
      ]);
    }

    await minimoSplash;

    if (!mounted) return;

    if (result.isOffline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Estás trabajando sin conexión. Algunas funciones estarán '
            'limitadas y los Tickets Internos quedarán pendientes de sincronizar.',
          ),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 5),
        ),
      );
    }

    final entryRoute = const SaasEntryRoutingPolicy().resolve(
      sessionStatus: result.status,
    );
    final nextPage = switch (entryRoute) {
      SaasEntryRoute.passwordChangeRequired => const CambiarPasswordPage(
        forzado: true,
      ),
      SaasEntryRoute.signedOut => const LoginPage(),
      _ => MobileSaasEntryGate(initialTab: PreferencesService.startScreen),
    };

    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => nextPage,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 800),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark
          ? Theme.of(context).scaffoldBackgroundColor
          : Colors.white,
      body: Stack(
        children: [
          Center(
            child: AnimatedContainer(
              duration: const Duration(seconds: 1, milliseconds: 500),
              curve: Curves.easeOutCubic,
              transform: Matrix4.translationValues(0, _yOffset, 0),
              child: AnimatedOpacity(
                duration: const Duration(seconds: 1),
                opacity: _opacity,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/imagenes/slf_logo.png', width: 350),
                    const SizedBox(height: 20),
                    Text(
                      'StOmni',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        color: isDark ? Colors.white : colorMarca,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'Gestión & Control',
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark ? Colors.grey[400] : Colors.grey[600],
                        letterSpacing: 2.0,
                      ),
                    ),
                    const SizedBox(height: 50),
                    SizedBox(
                      width: 25,
                      height: 25,
                      child: CircularProgressIndicator(
                        color: colorAcento,
                        strokeWidth: 2.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 30,
            left: 0,
            right: 0,
            child: AnimatedOpacity(
              duration: const Duration(seconds: 2),
              opacity: _opacity,
              child: Column(
                children: [
                  AppVersionText(
                    style: TextStyle(color: Colors.grey[400], fontSize: 12),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    'SLF 2026',
                    style: TextStyle(
                      color: Colors.grey[400],
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
