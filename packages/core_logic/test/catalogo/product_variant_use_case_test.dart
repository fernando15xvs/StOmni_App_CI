import 'package:core_logic/auth/application/operation_authorizer.dart';
import 'package:core_logic/auth/domain/app_permission.dart';
import 'package:core_logic/business/application/business_profile_gateway.dart';
import 'package:core_logic/business/domain/business_profile.dart';
import 'package:core_logic/features/catalogo/application/product_variant_use_case.dart';
import 'package:core_logic/features/catalogo/domain/product_variant_group.dart';
import 'package:flutter_test/flutter_test.dart';

class _Gateway implements ProductVariantGateway {
  int saves = 0;

  @override
  Future<List<ProductVariantGroup>> list() async => const [];

  @override
  Future<ProductVariantGroup> save(
    ProductVariantGroupDraft draft, {
    int? id,
  }) async {
    saves++;
    return ProductVariantGroup(
      id: id ?? 1,
      name: draft.name,
      attributeNames: draft.attributeNames,
      members: draft.members.map(
        (member) => ProductVariantMember(
          productId: member.productId,
          productName: 'P${member.productId}',
          productCode: '',
          attributes: member.attributes,
        ),
      ),
    );
  }

  @override
  Future<void> delete(int id) async {}
}

class _Business implements BusinessProfileGateway {
  _Business({this.enabled = true});
  final bool enabled;

  @override
  Future<BusinessProfile> load({bool allowOffline = false}) async =>
      BusinessProfile(
        businessId: '1',
        displayName: 'StOmni',
        capabilities: BusinessCapabilities(variants: enabled),
        revision: 1,
        supportsCapabilitySettings: true,
      );

  @override
  Future<BusinessProfile> updateCapabilities({
    required String businessId,
    required int expectedRevision,
    required BusinessCapabilities capabilities,
  }) async => throw UnimplementedError();
}

class _Authorizer implements OperationAuthorizer {
  @override
  String? currentAuthUserId = 'u1';
  Set<AppPermission> required = const {};

  @override
  Future<String> require(
    Set<AppPermission> permissions, {
    bool allowOffline = false,
  }) async {
    required = permissions;
    return currentAuthUserId!;
  }
}

void main() {
  test('normaliza atributos y exige products.update', () async {
    final gateway = _Gateway();
    final authorizer = _Authorizer();
    final useCase = ProductVariantUseCase(
      gateway: gateway,
      businessProfile: _Business(),
      authorizer: authorizer,
    );
    final result = await useCase.save(
      ProductVariantGroupDraft(
        name: 'Camiseta',
        attributeNames: const [' Color ', 'Talla'],
        members: [
          ProductVariantMemberDraft(
            productId: 1,
            attributes: const {'color': 'Azul', 'talla': 'M'},
          ),
          ProductVariantMemberDraft(
            productId: 2,
            attributes: const {'color': 'Azul', 'talla': 'L'},
          ),
        ],
      ),
    );

    expect(result.attributeNames, ['color', 'talla']);
    expect(authorizer.required, {AppPermission.productsUpdate});
    expect(gateway.saves, 1);
  });

  test('rechaza combinaciones de atributos duplicadas', () async {
    final useCase = ProductVariantUseCase(
      gateway: _Gateway(),
      businessProfile: _Business(),
      authorizer: _Authorizer(),
    );
    await expectLater(
      useCase.save(
        ProductVariantGroupDraft(
          name: 'Camiseta',
          attributeNames: const ['color', 'talla'],
          members: [
            ProductVariantMemberDraft(
              productId: 1,
              attributes: const {'color': 'Azul', 'talla': 'M'},
            ),
            ProductVariantMemberDraft(
              productId: 2,
              attributes: const {'color': 'azul', 'talla': 'm'},
            ),
          ],
        ),
      ),
      throwsArgumentError,
    );
  });

  test('capacidad apagada bloquea acceso', () async {
    final useCase = ProductVariantUseCase(
      gateway: _Gateway(),
      businessProfile: _Business(enabled: false),
      authorizer: _Authorizer(),
    );
    await expectLater(useCase.list(), throwsA(isA<Exception>()));
  });
}
