export 'catalog_item_type.dart';

class ProductVariantMember {
  ProductVariantMember({
    required this.productId,
    required this.productName,
    required this.productCode,
    required Map<String, String> attributes,
  }) : attributes = Map<String, String>.unmodifiable(attributes);

  final int productId;
  final String productName;
  final String productCode;
  final Map<String, String> attributes;
}

class ProductVariantGroup {
  ProductVariantGroup({
    required this.id,
    required this.name,
    required Iterable<String> attributeNames,
    required Iterable<ProductVariantMember> members,
  }) : attributeNames = List<String>.unmodifiable(attributeNames),
       members = List<ProductVariantMember>.unmodifiable(members);

  final int id;
  final String name;
  final List<String> attributeNames;
  final List<ProductVariantMember> members;
}

class ProductVariantMemberDraft {
  ProductVariantMemberDraft({
    required this.productId,
    required Map<String, String> attributes,
  }) : attributes = Map<String, String>.unmodifiable(attributes);

  final int productId;
  final Map<String, String> attributes;
}

class ProductVariantGroupDraft {
  ProductVariantGroupDraft({
    required this.name,
    required Iterable<String> attributeNames,
    required Iterable<ProductVariantMemberDraft> members,
  }) : attributeNames = List<String>.unmodifiable(attributeNames),
       members = List<ProductVariantMemberDraft>.unmodifiable(members);

  final String name;
  final List<String> attributeNames;
  final List<ProductVariantMemberDraft> members;
}
