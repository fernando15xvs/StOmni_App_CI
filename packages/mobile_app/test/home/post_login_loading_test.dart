import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  test('login usa pantalla puente y warm-up compartido', () {
    final login = File('lib/auth/pages/login_page.dart').readAsStringSync();
    final entryGate = File(
      'lib/onboarding/saas_entry_gate.dart',
    ).readAsStringSync();
    final bridge = File(
      'lib/home/post_login_home_page.dart',
    ).readAsStringSync();
    final coordinator = File(
      'lib/home/controllers/home_warmup_coordinator.dart',
    ).readAsStringSync();
    final overlay = File(
      'lib/home/widgets/post_login_loading_overlay.dart',
    ).readAsStringSync();

    expect(login, contains('MobileSaasEntryGate('));
    expect(login, contains('showPostLoginWarmup: true'));
    expect(
      entryGate,
      contains('PostLoginHomePage(pestanaInicial: initialTab)'),
    );
    expect(bridge, contains('HomePage(pestanaInicial: widget.pestanaInicial)'));
    expect(bridge, contains('homeWarmupCoordinatorProvider'));
    expect(bridge, contains('Duration(seconds: 6)'));
    expect(bridge, contains('coordinator.clearSessionCaches();'));
    expect(bridge, contains('unawaited(_prepararAplicacion(coordinator));'));

    // La lógica pesada vive en un coordinador común, no duplicada en widgets.
    expect(coordinator, contains('almacenNotifierProvider.future'));
    expect(coordinator, contains("TendenciaRequest('ingreso', 7)"));
    expect(coordinator, contains("TendenciaRequest('egreso', 7)"));
    expect(coordinator, contains('almacenesCacheProvider.notifier'));
    expect(coordinator, contains('balanceCacheProvider.notifier'));
    expect(
      coordinator,
      contains("'fecha_inicio': hoyInicio.toIso8601String()"),
    );

    expect(overlay, contains('Icons.storefront_outlined'));
    expect(overlay, contains('theme.colorScheme.primary'));
    expect(overlay, contains('Shimmer.fromColors('));
    expect(overlay, contains('disableAnimations'));
    expect(overlay, contains('Semantics('));
    expect(overlay, contains('Preparando StOmni'));
  });

  test('post-login no modifica providers durante initState o build', () {
    final bridge = File(
      'lib/home/post_login_home_page.dart',
    ).readAsStringSync();

    final initStart = bridge.indexOf('void initState()');
    final initEnd = bridge.indexOf('Future<void> _prepararAplicacion');
    expect(initStart, isNonNegative);
    expect(initEnd, greaterThan(initStart));

    final initBlock = bridge.substring(initStart, initEnd);
    expect(initBlock, contains('addPostFrameCallback'));

    final callbackIndex = initBlock.indexOf('addPostFrameCallback');
    final clearIndex = initBlock.indexOf('coordinator.clearSessionCaches();');
    final warmupIndex = initBlock.indexOf(
      'unawaited(_prepararAplicacion(coordinator));',
    );
    expect(clearIndex, greaterThan(callbackIndex));
    expect(warmupIndex, greaterThan(clearIndex));

    // Las escrituras concretas a StateProvider quedan fuera del widget.
    expect(bridge, isNot(contains('CacheProvider.notifier).state =')));
  });

  test('splash precarga home sin mostrar un segundo loader', () {
    final splash = File('lib/splash/splash_screen.dart').readAsStringSync();
    final entryGate = File(
      'lib/onboarding/saas_entry_gate.dart',
    ).readAsStringSync();
    final validation = coreFile(
      'lib/auth/data/supabase_session_validation_gateway.dart',
    ).readAsStringSync();

    expect(splash, contains('WidgetsBinding.instance.addPostFrameCallback'));
    expect(splash, contains('homeWarmupCoordinatorProvider'));
    expect(splash, contains('coordinator.clearSessionCaches();'));
    expect(splash, contains('coordinator.warmUp()'));
    expect(splash, contains('Duration(seconds: 5)'));
    expect(
      splash,
      contains(
        'MobileSaasEntryGate(initialTab: PreferencesService.startScreen)',
      ),
    );
    expect(splash, isNot(contains('PostLoginHomePage(')));
    expect(entryGate, contains('HomePage(pestanaInicial: initialTab)'));

    // Splash solo orquesta; las consultas pesadas permanecen centralizadas.
    expect(splash, isNot(contains('balanceRepositoryProvider')));
    expect(splash, isNot(contains('almacenesCacheProvider')));
    expect(splash, isNot(contains('graficoTendenciaProvider')));
    expect(validation, contains('ErrorMapper.isConnectionError'));
    expect(validation, contains('AuthSessionCache.loadForUser'));
  });

  test('warm-up compartido cubre inventario balance y mover stock', () {
    final coordinator = File(
      'lib/home/controllers/home_warmup_coordinator.dart',
    ).readAsStringSync();

    expect(coordinator, contains('almacenNotifierProvider.future'));
    expect(coordinator, contains('obtenerAlmacenesDirecto()'));
    expect(coordinator, contains('getDashboardSummary(hoyInicio, hoyFin)'));
    expect(
      coordinator,
      contains("getMovimientos('ingreso', hoyInicio, hoyFin)"),
    );
    expect(
      coordinator,
      contains("getMovimientos('egreso', hoyInicio, hoyFin)"),
    );
    expect(coordinator, contains('getVentasParaDescuento(hoyInicio, hoyFin)'));
  });
}
