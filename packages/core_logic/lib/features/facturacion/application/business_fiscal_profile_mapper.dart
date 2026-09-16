import '../domain/business_fiscal_profile.dart';

/// Traduce la configuración histórica de negocio al contrato fiscal tipado.
///
/// Los nombres de columnas actuales quedan confinados a este adaptador.
class BusinessFiscalProfileMapper {
  const BusinessFiscalProfileMapper._();

  static BusinessFiscalProfile? fromLegacy(Map<String, dynamic>? raw) {
    if (raw == null) return null;

    final legalName = _text(raw['razon_social']);
    final tradeName = _text(raw['nombre_comercial']);
    final locationCode = _text(raw['cod_local'], fallback: '0000');

    return BusinessFiscalProfile(
      businessId: _text(raw['id']),
      locationCode: locationCode,
      taxIdentifier: _text(raw['ruc']),
      legalName: legalName,
      tradeName: tradeName.isEmpty ? legalName : tradeName,
      address: FiscalAddress(
        street: _text(raw['direccion']),
        locationCode: locationCode,
        geoCode: _text(raw['ubigeo']),
        region: _text(raw['departamento']),
        province: _text(raw['provincia']),
        district: _text(raw['distrito']),
        countryCode: _text(
          raw['pais_codigo'] ?? raw['country_code'],
          fallback: 'PE',
        ),
      ),
      currencyCode: _text(
        raw['moneda_codigo'] ?? raw['currency_code'],
        fallback: 'PEN',
      ),
      standardTaxRatePercent: _doubleOrNull(
        raw['igv_porcentaje'] ?? raw['tax_rate_percent'],
      ),
      pricesIncludeTax: _boolOrNull(
        raw['precios_incluyen_igv'] ?? raw['prices_include_tax'],
      ),
      electronicDocumentsEnabled:
          _boolOrNull(
            raw['facturacion_electronica_habilitada'] ??
                raw['electronic_documents_enabled'],
          ) ??
          false,
      phone: _text(raw['telefono']),
      logoUrl: _text(raw['logo_url']),
    );
  }

  /// Campos que la pantalla actual ya tiene permitido modificar.
  static Map<String, dynamic> toLegacyEditableFields(
    BusinessFiscalProfile profile,
  ) {
    return <String, dynamic>{
      'razon_social': profile.legalName.trim(),
      'nombre_comercial': profile.tradeName.trim().isEmpty
          ? profile.legalName.trim()
          : profile.tradeName.trim(),
      'ruc': profile.taxIdentifier.trim(),
      'direccion': profile.address.street.trim(),
      'ubigeo': profile.address.geoCode.trim(),
      'departamento': profile.address.region.trim(),
      'provincia': profile.address.province.trim(),
      'distrito': profile.address.district.trim(),
      'cod_local': profile.locationCode.trim().isEmpty
          ? '0000'
          : profile.locationCode.trim(),
      'telefono': profile.phone.trim(),
      'logo_url': profile.logoUrl.trim(),
    };
  }

  static String _text(Object? value, {String fallback = ''}) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  static double? _doubleOrNull(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString().trim() ?? '');
  }

  static bool? _boolOrNull(Object? value) {
    if (value is bool) return value;
    final normalized = value?.toString().trim().toLowerCase();
    if (normalized == 'true' || normalized == '1') return true;
    if (normalized == 'false' || normalized == '0') return false;
    return null;
  }
}
