import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String splash;
  late String versionWidget;
  late String pubspec;

  setUpAll(() {
    splash = File('lib/splash/splash_screen.dart').readAsStringSync();
    versionWidget = File(
      'lib/splash/widgets/app_version_text.dart',
    ).readAsStringSync();
    pubspec = File('pubspec.yaml').readAsStringSync();
  });

  test('splash no contiene una versión hardcodeada', () {
    expect(splash, isNot(contains('Versión 2.0.0')));
    expect(splash, contains('AppVersionText('));
  });

  test('versión visible proviene de metadata real de plataforma', () {
    expect(versionWidget, contains('PackageInfo.fromPlatform()'));
    expect(versionWidget, contains('info.version'));
    expect(versionWidget, contains('info.buildNumber'));
    expect(versionWidget, contains("'Versión \$version\$buildSuffix'"));
  });

  test('package_info_plus usa versión compatible con AGP actual', () {
    expect(pubspec, contains('package_info_plus: ^8.3.1'));
  });
}
