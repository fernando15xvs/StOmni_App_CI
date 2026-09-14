import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS declara permisos usados por image_picker', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(plist, contains('<key>NSCameraUsageDescription</key>'));
    expect(plist, contains('<key>NSPhotoLibraryUsageDescription</key>'));
    expect(plist, contains('StOmni usa la cámara'));
    expect(plist, contains('StOmni usa la fototeca'));
  });

  test('iOS muestra StOmni como nombre de la aplicación', () {
    final plist = File('ios/Runner/Info.plist')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');

    expect(
      plist,
      contains('<key>CFBundleDisplayName</key>\n\t<string>StOmni</string>'),
    );
    expect(
      plist,
      contains('<key>CFBundleName</key>\n\t<string>StOmni</string>'),
    );
  });
}
