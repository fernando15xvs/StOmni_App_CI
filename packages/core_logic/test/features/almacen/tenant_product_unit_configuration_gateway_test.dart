import 'package:core_logic/features/almacen/data/tenant_product_unit_configuration_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> serverUnitProfile(int id) => {
    'product_id': id,
    'revision': 2,
    'profile': {
      'schema_version': 2,
      'base_code': 'unidad',
      'presentations': [
        {
          'code': 'unidad',
          'singular': 'unidad',
          'plural': 'unidades',
          'factor': 1.0,
          'fractional': false,
          'precision': 0,
        },
      ],
    },
  };

  test('accepts only the requested product profile', () {
    final profiles =
        TenantProductUnitConfigurationGateway.decodeRequestedProfiles(
          [serverUnitProfile(31)],
          requestedProductIds: {31},
        );
    expect(profiles.keys.toSet(), {31});
    expect(profiles[31]!.revision, 2);
    expect(profiles[31]!.profile.baseUnit.code, 'unidad');
  });

  test('missing profile is allowed without inheriting another product', () {
    final profiles =
        TenantProductUnitConfigurationGateway.decodeRequestedProfiles(
          <Object>[],
          requestedProductIds: {31},
        );
    expect(profiles, isEmpty);
  });

  test('rejects a different product id returned by the server', () {
    expect(
      () => TenantProductUnitConfigurationGateway.decodeRequestedProfiles(
        [serverUnitProfile(32)],
        requestedProductIds: {31},
      ),
      throwsStateError,
    );
  });

  test('a duplicate product response fails closed', () {
    expect(
      () => TenantProductUnitConfigurationGateway.decodeRequestedProfiles(
        [serverUnitProfile(31), serverUnitProfile(31)],
        requestedProductIds: {31},
      ),
      throwsStateError,
    );
  });

  test('mixed valid and foreign product rows cannot be partly merged', () {
    expect(
      () => TenantProductUnitConfigurationGateway.decodeRequestedProfiles(
        [serverUnitProfile(31), serverUnitProfile(32)],
        requestedProductIds: {31},
      ),
      throwsStateError,
    );
  });

  test('fractional or string product ids are rejected', () {
    for (final id in <Object?>[31.5, '31', null]) {
      final invalid = serverUnitProfile(31)..['product_id'] = id;
      expect(
        () => TenantProductUnitConfigurationGateway.decodeRequestedProfiles(
          [invalid],
          requestedProductIds: {31},
        ),
        throwsFormatException,
      );
    }
  });

  test('invalid row type or response type is rejected', () {
    for (final response in <Object?>[
      null,
      <String, dynamic>{},
      <Object>['corrupt'],
    ]) {
      expect(
        () => TenantProductUnitConfigurationGateway.decodeRequestedProfiles(
          response,
          requestedProductIds: {31},
        ),
        throwsFormatException,
      );
    }
  });

  test('invalid product request set is rejected', () {
    expect(
      () => TenantProductUnitConfigurationGateway.decodeRequestedProfiles(
        <Object>[],
        requestedProductIds: {0, 31},
      ),
      throwsFormatException,
    );
  });

  test('invalid unit profile version cannot bypass the mapper', () {
    final row = serverUnitProfile(31);
    (row['profile'] as Map<String, dynamic>)['schema_version'] = 999;
    expect(
      () => TenantProductUnitConfigurationGateway.decodeRequestedProfiles(
        [row],
        requestedProductIds: {31},
      ),
      throwsFormatException,
    );
  });

  test('corrupt revision cannot bypass the mapper', () {
    final row = serverUnitProfile(31)..['revision'] = -3;
    expect(
      () => TenantProductUnitConfigurationGateway.decodeRequestedProfiles(
        [row],
        requestedProductIds: {31},
      ),
      throwsFormatException,
    );
  });
}
