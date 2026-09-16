import '../../../auth/application/operation_authorizer.dart';
import '../../../auth/domain/app_permission.dart';
import '../../../business/application/business_profile_gateway.dart';
import '../../../errors/user_facing_exception.dart';
import '../domain/product_variant_group.dart';

abstract interface class ProductVariantGateway {
  Future<List<ProductVariantGroup>> list();
  Future<ProductVariantGroup> save(ProductVariantGroupDraft draft, {int? id});
  Future<void> delete(int id);
}

class ProductVariantUseCase {
  const ProductVariantUseCase({
    required ProductVariantGateway gateway,
    required BusinessProfileGateway businessProfile,
    required OperationAuthorizer authorizer,
  }) : _gateway = gateway,
       _businessProfile = businessProfile,
       _authorizer = authorizer;

  final ProductVariantGateway _gateway;
  final BusinessProfileGateway _businessProfile;
  final OperationAuthorizer _authorizer;

  Future<List<ProductVariantGroup>> list() async {
    await _requireAccess();
    return _gateway.list();
  }

  Future<ProductVariantGroup> save(
    ProductVariantGroupDraft draft, {
    int? id,
  }) async {
    final normalized = _validate(draft);
    final user = await _requireAccess();
    final result = await _gateway.save(normalized, id: id);
    _checkSession(user);
    return result;
  }

  Future<void> delete(int id) async {
    if (id <= 0) throw ArgumentError('Grupo de variantes inválido.');
    final user = await _requireAccess();
    await _gateway.delete(id);
    _checkSession(user);
  }

  Future<String> _requireAccess() async {
    final profile = await _businessProfile.load();
    if (!profile.capabilities.variants) {
      throw const UserFacingException(
        'Las variantes de producto no están habilitadas para este negocio.',
      );
    }
    return _authorizer.require({AppPermission.productsUpdate});
  }

  void _checkSession(String user) {
    if (_authorizer.currentAuthUserId != user) {
      throw const UserFacingException(
        'La sesión cambió durante la gestión de variantes.',
      );
    }
  }

  ProductVariantGroupDraft _validate(ProductVariantGroupDraft draft) {
    final name = draft.name.trim();
    if (name.isEmpty || name.length > 120) {
      throw ArgumentError('El grupo de variantes requiere un nombre válido.');
    }
    final attributes = draft.attributeNames
        .map((value) => value.trim().toLowerCase())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    if (attributes.isEmpty ||
        attributes.length > 8 ||
        attributes.toSet().length != attributes.length) {
      throw ArgumentError(
        'Define entre 1 y 8 atributos de variante sin duplicados.',
      );
    }
    if (attributes.any(
      (value) =>
          value.length > 40 || !RegExp(r'^[a-z0-9_áéíóúñ -]+$').hasMatch(value),
    )) {
      throw ArgumentError('Uno de los atributos de variante no es válido.');
    }
    if (draft.members.length < 2 || draft.members.length > 200) {
      throw ArgumentError(
        'Un grupo requiere entre 2 y 200 productos variantes.',
      );
    }
    final productIds = <int>{};
    final normalizedMembers = <ProductVariantMemberDraft>[];
    for (final member in draft.members) {
      if (member.productId <= 0 || !productIds.add(member.productId)) {
        throw ArgumentError('Un producto no puede repetirse en el grupo.');
      }
      if (member.attributes.keys
              .toSet()
              .difference(attributes.toSet())
              .isNotEmpty ||
          attributes.any(
            (key) => (member.attributes[key] ?? '').trim().isEmpty,
          )) {
        throw ArgumentError(
          'Cada variante debe definir todos los atributos del grupo.',
        );
      }
      normalizedMembers.add(
        ProductVariantMemberDraft(
          productId: member.productId,
          attributes: {
            for (final key in attributes) key: member.attributes[key]!.trim(),
          },
        ),
      );
    }
    final signatures = normalizedMembers
        .map(
          (member) => attributes
              .map((key) => member.attributes[key]!.toLowerCase())
              .join('|'),
        )
        .toSet();
    if (signatures.length != normalizedMembers.length) {
      throw ArgumentError(
        'Dos variantes no pueden tener la misma combinación de atributos.',
      );
    }
    return ProductVariantGroupDraft(
      name: name,
      attributeNames: attributes,
      members: normalizedMembers,
    );
  }
}
