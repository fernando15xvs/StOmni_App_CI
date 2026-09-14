import 'dart:typed_data';
import 'package:core_logic/core_logic.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class PdfBrandingLoader {
  const PdfBrandingLoader._();

  static const int _maxLogoBytes = 5 * 1024 * 1024;

  static Future<PdfBranding> load() async {
    final profile = ConfiguracionService.fiscalProfile;
    Uint8List? logo;
    final uri = BusinessBranding.parseLogoUri(profile?.logoUrl ?? '');
    if (uri != null) {
      try {
        final response = await http.get(uri).timeout(const Duration(seconds: 3));
        final contentType = response.headers['content-type'] ?? '';
        if (response.statusCode == 200 &&
            contentType.toLowerCase().startsWith('image/') &&
            response.bodyBytes.isNotEmpty &&
            response.bodyBytes.length <= _maxLogoBytes) {
          logo = response.bodyBytes;
        }
      } catch (_) {
        // La marca local es opcional y no debe bloquear un documento válido.
      }
    }
    if (logo == null) {
      try {
        final asset = await rootBundle.load('assets/imagenes/slf_logo.png');
        logo = asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes);
      } catch (_) {
        // Un documento sigue siendo válido aunque tampoco exista el asset base.
      }
    }
    return PdfBranding(fiscalProfile: profile, logoBytes: logo);
  }
}
