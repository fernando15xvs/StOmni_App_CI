import 'package:core_logic/core_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('la clave fiscal representa negocio y local sin conceptos de infraestructura', () {
    const key = BusinessFiscalProfileKey(
      businessId: '  negocio-42  ',
      locationCode: '  tienda-centro ',
    );

    final normalized = key.normalized();
    expect(normalized.businessId, 'negocio-42');
    expect(normalized.locationCode, 'tienda-centro');
    expect(normalized.isValid, isTrue);
  });

  test('la edición de identidad conserva parámetros fiscales administrados por backend', () {
    const original = BusinessFiscalProfile(
      businessId: '1',
      locationCode: '0000',
      taxIdentifier: '20123456789',
      legalName: 'EMPRESA ORIGINAL SAC',
      tradeName: 'Original',
      address: FiscalAddress(
        street: 'Av. Uno 123',
        locationCode: '0000',
        geoCode: '150101',
        countryCode: 'PE',
      ),
      currencyCode: 'PEN',
      standardTaxRatePercent: 18,
      pricesIncludeTax: true,
      electronicDocumentsEnabled: true,
    );

    final updated = original.copyWith(
      legalName: 'EMPRESA NUEVA SAC',
      address: original.address.copyWith(street: 'Av. Dos 456'),
    );

    expect(updated.key.businessId, '1');
    expect(updated.legalName, 'EMPRESA NUEVA SAC');
    expect(updated.address.street, 'Av. Dos 456');
    expect(updated.standardTaxRatePercent, 18);
    expect(updated.pricesIncludeTax, isTrue);
    expect(updated.electronicDocumentsEnabled, isTrue);
    expect(updated.currencyCode, 'PEN');
  });

  test('el mapper legacy limita la escritura a campos editables', () {
    const profile = BusinessFiscalProfile(
      businessId: '1',
      locationCode: '0000',
      taxIdentifier: '20123456789',
      legalName: 'NEGOCIO SAC',
      tradeName: 'Negocio',
      address: FiscalAddress(
        street: 'Av. Principal 100',
        locationCode: '0000',
        geoCode: '150101',
        region: 'LIMA',
        province: 'LIMA',
        district: 'LIMA',
        countryCode: 'PE',
      ),
      currencyCode: 'PEN',
      standardTaxRatePercent: 18,
      pricesIncludeTax: true,
      electronicDocumentsEnabled: true,
      phone: '999999999',
      logoUrl: 'https://example.com/logo.png',
    );

    final raw = BusinessFiscalProfileMapper.toLegacyEditableFields(profile);

    expect(raw['razon_social'], 'NEGOCIO SAC');
    expect(raw['cod_local'], '0000');
    expect(raw, isNot(contains('igv_porcentaje')));
    expect(raw, isNot(contains('precios_incluyen_igv')));
    expect(raw, isNot(contains('facturacion_electronica_habilitada')));
  });
}
