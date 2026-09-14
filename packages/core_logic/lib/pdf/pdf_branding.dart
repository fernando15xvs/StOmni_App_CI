import 'dart:typed_data';
import '../features/facturacion/domain/business_fiscal_profile.dart';

/// Datos de marca ya cargados por el cliente, sin lectura de assets o servicios.
class PdfBranding {
  PdfBranding({this.fiscalProfile, Uint8List? logoBytes})
      : _logoBytes = logoBytes == null ? null : Uint8List.fromList(logoBytes);
  final BusinessFiscalProfile? fiscalProfile;
  final Uint8List? _logoBytes;
  Uint8List? get logoBytes => _logoBytes == null ? null : Uint8List.fromList(_logoBytes);
}
