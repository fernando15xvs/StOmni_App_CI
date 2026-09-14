import 'package:core_logic/core_logic.dart';
import 'package:core_logic/business/data/business_profile_mapper.dart';
import 'package:core_logic/business/domain/cached_business_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/test_operation_policy.dart';

void main() {
  test('caché rechaza expiración y reloj futuro', () {
    final now = DateTime.utc(2026, 9, 4, 10);
    final profile = TestBusinessProfiles().profile;
    expect(CachedBusinessProfile(profile: profile, cachedAt: now).isCurrentAt(now), isTrue);
    expect(CachedBusinessProfile(profile: profile,
      cachedAt: now.subtract(const Duration(hours: 24))).isCurrentAt(now), isFalse);
    expect(CachedBusinessProfile(profile: profile,
      cachedAt: now.add(const Duration(minutes: 6))).isCurrentAt(now), isFalse);
  });

  test('perfil conserva capacidades y revisión con codec estricto', () {
    final profiles = TestBusinessProfiles();
    final encoded = BusinessProfileMapper.encode(profiles.profile);
    final decoded = BusinessProfileMapper.decode(encoded);
    expect(decoded.businessId, '1');
    expect(decoded.capabilities.creditSales, isTrue);
    expect(decoded.capabilities.variants, isFalse);
    (encoded['capabilities'] as Map)['credit_sales'] = 'true';
    expect(() => BusinessProfileMapper.decode(encoded), throwsFormatException);
  });

  test('administrador guarda, revisión obsoleta no sobrescribe', () async {
    final profiles = TestBusinessProfiles();
    final original = profiles.profile;
    final update = UpdateBusinessCapabilitiesUseCase(gateway: profiles,
      authorizer: TestOperationAuthorizer());
    final saved = await update.execute(original,
      original.capabilities.withSales(creditSales: false));
    expect(saved.revision, 1);
    expect(saved.capabilities.creditSales, isFalse);
    await expectLater(update.execute(original, original.capabilities), throwsStateError);
    expect(profiles.writes, 1);
  });

  test('trazabilidad soportada exige lotes para vencimientos', () {
    expect(const BusinessCapabilities(lotTracking: true).supportedByCurrentBackend, isTrue);
    expect(const BusinessCapabilities(serialNumberTracking: true).supportedByCurrentBackend, isTrue);
    expect(const BusinessCapabilities(
      lotTracking: true,
      expiryTracking: true,
    ).supportedByCurrentBackend, isTrue);
    expect(const BusinessCapabilities(expiryTracking: true).supportedByCurrentBackend, isFalse);
  });

  test('servicios no inventariables ya son una capacidad soportada', () {
    expect(const BusinessCapabilities(services: true).supportedByCurrentBackend, isTrue);
  });

  test('operador no puede modificar capacidades', () async {
    final profiles = TestBusinessProfiles();
    final update = UpdateBusinessCapabilitiesUseCase(
      gateway: profiles,
      authorizer: TestOperationAuthorizer(role: 'operador'),
    );
    await expectLater(
      update.execute(profiles.profile, const BusinessCapabilities(services: true)),
      throwsA(isA<UserFacingException>()),
    );
    expect(profiles.writes, 0);
  });

  test('servidor anterior no simula persistencia de capacidades', () async {
    final profiles = TestBusinessProfiles();
    profiles.profile = const BusinessProfile(businessId: '1', displayName: 'Legacy',
      capabilities: BusinessCapabilities(), revision: 0, supportsCapabilitySettings: false);
    await expectLater(UpdateBusinessCapabilitiesUseCase(gateway: profiles,
      authorizer: TestOperationAuthorizer()).execute(profiles.profile, const BusinessCapabilities()),
      throwsA(isA<UserFacingException>()));
    expect(profiles.writes, 0);
  });

  test('política de ventas exige capacidades sin conocer país ni comprobantes', () async {
    final profiles = TestBusinessProfiles();
    profiles.profile = const BusinessProfile(businessId: '1', displayName: 'Pruebas',
      capabilities: BusinessCapabilities(creditSales: false, electronicInvoicing: false),
      revision: 1, supportsCapabilitySettings: true);
    final policy = ConfiguredBusinessSalePolicy(profiles);
    await policy.validate(isCredit: false, requiresElectronicEmission: false);
    await expectLater(policy.validate(isCredit: true, requiresElectronicEmission: false,
      allowOffline: true), throwsA(isA<UserFacingException>()));
    expect(profiles.lastAllowOffline, isTrue);
    await expectLater(policy.validate(isCredit: false, requiresElectronicEmission: true),
      throwsA(isA<UserFacingException>()));
  });
}
