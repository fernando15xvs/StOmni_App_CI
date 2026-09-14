import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String bootstrap;

  setUpAll(() {
    bootstrap = File('lib/app/bootstrap.dart').readAsStringSync();
  });

  test('runApp ocurre antes de inicializar dependencias remotas', () {
    final runAppIndex = bootstrap.indexOf('runApp(const _BootstrapShell())');
    final criticalIndex = bootstrap.indexOf(
      'Future<void> _initializeCriticalDependencies()',
    );

    expect(runAppIndex, greaterThanOrEqualTo(0));
    expect(criticalIndex, greaterThan(runAppIndex));
    expect(bootstrap, contains('PlatformDispatcher.instance.platformBrightness'));
    expect(bootstrap, contains('return ColoredBox('));
  });

  test('bootstrap crítico valida configuración y admite retry', () {
    expect(bootstrap, contains("supabaseUrl.trim().isEmpty"));
    expect(bootstrap, contains("supabaseAnonKey.trim().isEmpty"));
    expect(bootstrap, contains('UserFacingException'));
    expect(bootstrap, contains("label: const Text('Reintentar')"));
    expect(bootstrap, contains('onPressed: _initialize'));
    expect(bootstrap, contains('_supabaseInitialized'));
  });

  test('configuración pública del cliente usa solo dart-define', () {
    expect(bootstrap, contains("String.fromEnvironment('SUPABASE_URL')"));
    expect(
      bootstrap,
      contains("String.fromEnvironment('SUPABASE_ANON_KEY')"),
    );
    expect(bootstrap, isNot(contains('flutter_dotenv')));
    expect(bootstrap, isNot(contains('dotenv.')));
    expect(bootstrap, contains('mediante --dart-define'));
  });

  test('OneSignal queda como servicio opcional y no bloquea arranque', () {
    expect(bootstrap, contains('Future<void> _initializeOptionalServices()'));
    expect(bootstrap, contains('OneSignal.initialize'));
    expect(
      bootstrap,
      contains(r"debugPrint('OneSignal no pudo inicializarse: $e')"),
    );
    expect(bootstrap, contains('if (_oneSignalConfigured) return'));
  });

  test('errores de bootstrap se traducen antes de mostrarse', () {
    expect(bootstrap, contains('_error = ErrorMapper.map(e)'));
    expect(bootstrap, isNot(contains(r"Text('Error: $e')")));
  });
}
