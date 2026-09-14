import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/notification_navigation.dart';
import 'controllers/home_warmup_coordinator.dart';
import 'home_page.dart';
import 'widgets/post_login_loading_overlay.dart';

/// Pantalla puente usada únicamente después de un login exitoso.
///
/// Monta [HomePage] desde el primer frame para que la pestaña inicial cargue en
/// segundo plano mientras un overlay elegante cubre la interfaz. La misma
/// rutina de warm-up también puede ejecutarse desde Splash cuando ya existe
/// una sesión válida, sin mostrar este segundo overlay.
class PostLoginHomePage extends ConsumerStatefulWidget {
  final int pestanaInicial;

  const PostLoginHomePage({super.key, this.pestanaInicial = 0});

  @override
  ConsumerState<PostLoginHomePage> createState() => _PostLoginHomePageState();
}

class _PostLoginHomePageState extends ConsumerState<PostLoginHomePage> {
  bool _preparado = false;

  @override
  void initState() {
    super.initState();

    // Riverpod no permite modificar providers mientras el widget está dentro
    // de initState/build. El overlay cubre el primer frame, así que esperamos
    // a que ese frame termine para limpiar snapshots de la sesión anterior y
    // arrancar la precarga compartida.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final coordinator = ref.read(homeWarmupCoordinatorProvider);
      coordinator.clearSessionCaches();
      unawaited(_prepararAplicacion(coordinator));
    });
  }

  Future<void> _prepararAplicacion(HomeWarmupCoordinator coordinator) async {
    final warmup = coordinator.warmUp();

    // 1.2 s evita un flash fugaz y permite apreciar la transición.
    // 6 s es el máximo de espera visual: si la red está lenta, la app entra y
    // deja que cada módulo siga resolviendo sus datos en segundo plano.
    await Future.wait<void>([
      Future<void>.delayed(const Duration(milliseconds: 1200)),
      Future.any<void>([
        warmup,
        Future<void>.delayed(const Duration(seconds: 6)),
      ]),
    ]);

    if (!mounted) return;
    setState(() => _preparado = true);
  }

  @override
  Widget build(BuildContext context) {
    return StockAlertNotificationHost(
      // Un tap recibido durante el login queda pendiente hasta que finalice
      // "Preparando StOmni" y Home esté listo para mostrarse.
      enabled: _preparado,
      child: Stack(
        fit: StackFit.expand,
        children: [
          HomePage(pestanaInicial: widget.pestanaInicial),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 420),
            switchOutCurve: Curves.easeInOutCubic,
            child: _preparado
                ? const SizedBox.shrink(key: ValueKey('post_login_ready'))
                : const PostLoginLoadingOverlay(
                    key: ValueKey('post_login_loading'),
                  ),
          ),
        ],
      ),
    );
  }
}
