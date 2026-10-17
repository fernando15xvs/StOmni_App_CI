import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/workspace_paths.dart';

void main() {
  late String gradle;
  late String gitignore;

  setUpAll(() {
    gradle = File('android/app/build.gradle.kts').readAsStringSync();
    gitignore = repositoryFile('.gitignore').readAsStringSync();
  });

  test('Release nunca usa signingConfig debug', () {
    expect(gradle, isNot(contains('signingConfigs.getByName("debug")')));
    expect(gradle, contains('signingConfigs.getByName("release")'));
    expect(gradle, contains('Android Release requiere android/key.properties'));
  });

  test('credenciales y keystores permanecen fuera de Git', () {
    expect(gitignore, contains('android/key.properties'));
    expect(gitignore, contains('**/*.keystore'));
    expect(gitignore, contains('**/*.jks'));
  });

  test('applicationId QA queda separado del producto StOmni M', () {
    expect(gradle, contains('applicationId = "com.stomni.saas.qa"'));
    expect(gradle, isNot(contains('applicationId = "com.example.ferreteria_app"')));
  });
}

