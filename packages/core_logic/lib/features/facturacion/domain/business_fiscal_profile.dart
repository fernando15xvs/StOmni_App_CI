/// Clave neutral para identificar la configuración fiscal activa de un negocio
/// y, cuando aplique, su local o establecimiento.
///
/// `businessId` identifica el perfil lógico. `locationCode` permite distinguir
/// establecimientos sin obligar al dominio a conocer IDs o tablas concretas.
class BusinessFiscalProfileKey {
  const BusinessFiscalProfileKey({
    required this.businessId,
    this.locationCode = '',
  });

  final String businessId;
  final String locationCode;

  bool get isValid => businessId.trim().isNotEmpty;

  BusinessFiscalProfileKey normalized() => BusinessFiscalProfileKey(
    businessId: businessId.trim(),
    locationCode: locationCode.trim(),
  );
}

/// Dirección fiscal independiente de una interfaz o proveedor tributario.
class FiscalAddress {
  const FiscalAddress({
    required this.street,
    this.locationCode = '',
    this.geoCode = '',
    this.region = '',
    this.province = '',
    this.district = '',
    this.countryCode = '',
  });

  final String street;
  final String locationCode;
  final String geoCode;
  final String region;
  final String province;
  final String district;
  final String countryCode;

  bool get hasStructuredLocation =>
      geoCode.isNotEmpty ||
      region.isNotEmpty ||
      province.isNotEmpty ||
      district.isNotEmpty;

  FiscalAddress copyWith({
    String? street,
    String? locationCode,
    String? geoCode,
    String? region,
    String? province,
    String? district,
    String? countryCode,
  }) {
    return FiscalAddress(
      street: street ?? this.street,
      locationCode: locationCode ?? this.locationCode,
      geoCode: geoCode ?? this.geoCode,
      region: region ?? this.region,
      province: province ?? this.province,
      district: district ?? this.district,
      countryCode: countryCode ?? this.countryCode,
    );
  }
}

/// Identidad y parámetros fiscales visibles de un negocio/local.
///
/// El dominio usa nombres neutrales (`taxIdentifier`, `standardTaxRatePercent`)
/// para no acoplar otras plataformas o países a nombres de un proveedor fiscal.
class BusinessFiscalProfile {
  const BusinessFiscalProfile({
    required this.businessId,
    required this.locationCode,
    required this.taxIdentifier,
    required this.legalName,
    required this.tradeName,
    required this.address,
    this.currencyCode = '',
    this.standardTaxRatePercent,
    this.pricesIncludeTax,
    this.electronicDocumentsEnabled = false,
    this.phone = '',
    this.logoUrl = '',
  });

  final String businessId;
  final String locationCode;
  final String taxIdentifier;
  final String legalName;
  final String tradeName;
  final FiscalAddress address;
  final String currencyCode;
  final double? standardTaxRatePercent;
  final bool? pricesIncludeTax;
  final bool electronicDocumentsEnabled;
  final String phone;
  final String logoUrl;

  BusinessFiscalProfileKey get key => BusinessFiscalProfileKey(
    businessId: businessId,
    locationCode: locationCode,
  );

  bool get hasFiscalIdentity =>
      taxIdentifier.trim().isNotEmpty && legalName.trim().isNotEmpty;

  double? get standardTaxFraction {
    final percent = standardTaxRatePercent;
    if (percent == null) return null;
    return percent / 100;
  }

  double? taxFromNet(double netAmount) {
    final fraction = standardTaxFraction;
    if (fraction == null) return null;
    return netAmount * fraction;
  }

  double? taxFromGross(double grossAmount) {
    final fraction = standardTaxFraction;
    if (fraction == null) return null;
    return grossAmount - (grossAmount / (1 + fraction));
  }

  BusinessFiscalProfile copyWith({
    String? businessId,
    String? locationCode,
    String? taxIdentifier,
    String? legalName,
    String? tradeName,
    FiscalAddress? address,
    String? currencyCode,
    double? standardTaxRatePercent,
    bool? pricesIncludeTax,
    bool? electronicDocumentsEnabled,
    String? phone,
    String? logoUrl,
  }) {
    return BusinessFiscalProfile(
      businessId: businessId ?? this.businessId,
      locationCode: locationCode ?? this.locationCode,
      taxIdentifier: taxIdentifier ?? this.taxIdentifier,
      legalName: legalName ?? this.legalName,
      tradeName: tradeName ?? this.tradeName,
      address: address ?? this.address,
      currencyCode: currencyCode ?? this.currencyCode,
      standardTaxRatePercent:
          standardTaxRatePercent ?? this.standardTaxRatePercent,
      pricesIncludeTax: pricesIncludeTax ?? this.pricesIncludeTax,
      electronicDocumentsEnabled:
          electronicDocumentsEnabled ?? this.electronicDocumentsEnabled,
      phone: phone ?? this.phone,
      logoUrl: logoUrl ?? this.logoUrl,
    );
  }
}
