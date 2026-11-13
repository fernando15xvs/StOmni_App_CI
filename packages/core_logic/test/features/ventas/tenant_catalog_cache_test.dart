import 'dart:convert';

import 'package:core_logic/onboarding/application/tenant_request_scope.dart';
import 'package:core_logic/services/tenant_catalog_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const userA = '00000000-0000-0000-0000-000000000011';
  const userB = '00000000-0000-0000-0000-000000000012';
  const orgA = '00000000-0000-0000-0000-000000000021';
  const orgB = '00000000-0000-0000-0000-000000000022';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  TenantCatalogCache cache(
    String user,
    String organization, {
    String? Function()? signedIn,
    String? Function()? selected,
  }) => TenantCatalogCache(
    scope: TenantRequestScope(authUserId: user, organizationId: organization),
    currentAuthUserId: signedIn ?? () => user,
    currentSelectedOrganizationId: selected ?? () => organization,
  );

  List<Map<String, dynamic>> products(String organization) => [
    {'id': 'sku-1', 'organization_id': organization, 'title': 'Martillo'},
  ];

  test('one company cannot read cached products of another', () async {
    final a = cache(userA, orgA);
    final b = cache(userA, orgB);
    await a.save(products(orgA));
    expect((await a.load()).single['organization_id'], orgA);
    expect(await b.load(), isEmpty);
    await b.save(products(orgB));
    expect((await a.load()).single['organization_id'], orgA);
    expect((await b.load()).single['organization_id'], orgB);
  });

  test(
    'different Auth identities cannot share one organization catalog',
    () async {
      final a = cache(userA, orgA);
      final b = cache(userB, orgA);
      await a.save(products(orgA));
      expect(await b.load(), isEmpty);
    },
  );

  test('foreign products cannot be written under selected company', () async {
    final a = cache(userA, orgA);
    await expectLater(a.save(products(orgB)), throwsStateError);
    await expectLater(
      a.save([
        {'id': 'sku-missing-organization'},
      ]),
      throwsStateError,
    );
    expect(await a.load(), isEmpty);
  });

  test('old global product cache is not implicitly imported', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('catalogo_cache', jsonEncode(products(orgA)));
    final a = cache(userA, orgA);
    expect(await a.load(), isEmpty);
    expect(prefs.getString('catalogo_cache'), isNotNull);
  });

  test(
    'revocation or account switch blocks all selected catalog access',
    () async {
      String? selected = orgA;
      String? user = userA;
      final a = cache(
        userA,
        orgA,
        signedIn: () => user,
        selected: () => selected,
      );
      await a.save(products(orgA));
      selected = orgB;
      await expectLater(a.load(), throwsStateError);
      await expectLater(a.clearSelectedTenant(), throwsStateError);
      selected = orgA;
      user = userB;
      await expectLater(a.load(), throwsStateError);
      user = userA;
      expect((await a.load()).single['id'], 'sku-1');
    },
  );

  test('removing A cache leaves B cache unchanged', () async {
    final a = cache(userA, orgA);
    final b = cache(userA, orgB);
    await a.save(products(orgA));
    await b.save(products(orgB));
    await a.clearSelectedTenant();
    expect(await a.load(), isEmpty);
    expect((await b.load()).single['organization_id'], orgB);
  });

  test('tampered stored tenant envelope fails closed', () async {
    final a = cache(userA, orgA);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      TenantCatalogCache.storageKeyFor(userA, orgA),
      jsonEncode({
        'schema_version': 2,
        'auth_user_id': userA,
        'organization_id': orgB,
        'items': products(orgA),
      }),
    );
    await expectLater(a.load(), throwsFormatException);
  });

  test('tampered product organization cannot be decoded', () async {
    final a = cache(userA, orgA);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      TenantCatalogCache.storageKeyFor(userA, orgA),
      jsonEncode({
        'schema_version': 2,
        'auth_user_id': userA,
        'organization_id': orgA,
        'items': products(orgB),
      }),
    );
    await expectLater(a.load(), throwsStateError);
  });

  test('reject path-like or invalid tenant identifiers in storage keys', () {
    expect(
      () => TenantCatalogCache.storageKeyFor('../cross', orgA),
      throwsFormatException,
    );
    expect(
      () => TenantCatalogCache.storageKeyFor(userA, '../../../elsewhere'),
      throwsFormatException,
    );
  });
}
