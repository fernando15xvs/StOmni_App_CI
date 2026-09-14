import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/product_variant_use_case.dart';
import '../domain/product_variant_group.dart';

class SupabaseProductVariantGateway implements ProductVariantGateway {
  const SupabaseProductVariantGateway(this.client);

  final SupabaseClient client;

  @override
  Future<List<ProductVariantGroup>> list() async {
    final raw = await client.rpc('list_product_variant_groups_v1');
    if (raw is! List) {
      throw const FormatException('El listado de variantes es inválido.');
    }
    return raw.map(_decode).toList(growable: false);
  }

  @override
  Future<ProductVariantGroup> save(
    ProductVariantGroupDraft draft, {
    int? id,
  }) async {
    final raw = await client.rpc('save_product_variant_group_v1', params: {
      'p_group_id': id,
      'p_name': draft.name,
      'p_attribute_names': draft.attributeNames,
      'p_members': draft.members
          .map((member) => <String, dynamic>{
                'product_id': member.productId,
                'attributes': member.attributes,
              })
          .toList(growable: false),
    });
    return _decode(raw);
  }

  @override
  Future<void> delete(int id) async {
    await client.rpc('delete_product_variant_group_v1', params: {
      'p_group_id': id,
    });
  }

  ProductVariantGroup _decode(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('Grupo de variantes inválido.');
    }
    final map = Map<String, dynamic>.from(raw);
    final id = _int(map['id']);
    final name = map['name']?.toString().trim() ?? '';
    final rawAttributes = map['attribute_names'];
    final rawMembers = map['members'];
    if (id == null || id <= 0 || name.isEmpty ||
        rawAttributes is! List || rawMembers is! List) {
      throw const FormatException('Contrato de variantes incompleto.');
    }
    final attributes = rawAttributes
        .map((value) => value.toString().trim().toLowerCase())
        .toList(growable: false);
    return ProductVariantGroup(
      id: id,
      name: name,
      attributeNames: attributes,
      members: rawMembers.map((rawMember) {
        if (rawMember is! Map) {
          throw const FormatException('Miembro de variante inválido.');
        }
        final member = Map<String, dynamic>.from(rawMember);
        final productId = _int(member['product_id']);
        final productName = member['product_name']?.toString().trim() ?? '';
        final attrs = member['attributes'];
        if (productId == null || productId <= 0 || productName.isEmpty || attrs is! Map) {
          throw const FormatException('Miembro de variante incompleto.');
        }
        return ProductVariantMember(
          productId: productId,
          productName: productName,
          productCode: member['product_code']?.toString().trim() ?? '',
          attributes: {
            for (final entry in attrs.entries)
              entry.key.toString().trim().toLowerCase(): entry.value.toString().trim(),
          },
        );
      }),
    );
  }

  int? _int(Object? value) => value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '');
}
