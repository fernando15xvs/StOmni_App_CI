import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../utils/app_time.dart';
import '../application/sale_pricing_use_case.dart';
import '../domain/sale_pricing.dart';

class SupabaseSalePricingGateway implements SalePricingGateway {
  const SupabaseSalePricingGateway(this._client);
  final SupabaseClient _client;

  @override
  Future<SalePriceQuote> resolve({
    required int productId,
    required String presentationCode,
    required double quantity,
    DateTime? at,
  }) async {
    final raw = await _client.rpc(
      'resolve_sale_price_v1',
      params: {
        'p_product_id': productId,
        'p_presentation_code': presentationCode,
        'p_quantity': quantity,
        'p_at': AppTime.toIsoLima(at ?? AppTime.now()),
      },
    );
    if (raw is! Map)
      throw const FormatException('Respuesta de precio inválida.');
    final row = Map<String, dynamic>.from(raw);
    num requiredNumber(String key) {
      final value = row[key];
      if (value is! num || !value.toDouble().isFinite) {
        throw FormatException('Precio inválido: $key');
      }
      return value;
    }

    final rawProduct = requiredNumber('product_id');
    final rawRuleId = row['rule_id'];
    return SalePriceQuote(
      productId: rawProduct.toInt(),
      presentationCode: row['presentation_code']?.toString() ?? '',
      quantity: requiredNumber('quantity').toDouble(),
      catalogPrice: requiredNumber('catalog_price').toDouble(),
      price: requiredNumber('price').toDouble(),
      ruleId: rawRuleId is num ? rawRuleId.toInt() : null,
      ruleName: row['rule_name']?.toString(),
    );
  }

  @override
  Future<List<SalePriceRule>> listRules() async {
    final raw = await _client.rpc('list_sale_price_rules_v1');
    if (raw is! List) throw const FormatException('Lista de precios inválida.');
    return raw
        .map((item) {
          if (item is! Map)
            throw const FormatException('Regla de precio inválida.');
          final row = Map<String, dynamic>.from(item);
          double number(String key) {
            final value = row[key];
            if (value is! num || !value.toDouble().isFinite) {
              throw FormatException('Regla de precio inválida: $key');
            }
            return value.toDouble();
          }

          DateTime? date(String key) {
            final text = row[key]?.toString();
            return text == null || text.isEmpty ? null : DateTime.parse(text);
          }

          final fixed = row['fixed_price'];
          final discount = row['discount_percent'];
          return SalePriceRule(
            id: (row['id'] as num).toInt(),
            name: row['name']?.toString() ?? '',
            productId: (row['product_id'] as num).toInt(),
            productName: row['product_name']?.toString() ?? '',
            presentationCode: row['presentation_code']?.toString(),
            minQuantity: number('min_quantity'),
            fixedPrice: fixed is num ? fixed.toDouble() : null,
            discountPercent: discount is num ? discount.toDouble() : null,
            priority: (row['priority'] as num?)?.toInt() ?? 0,
            startsAt: date('starts_at'),
            endsAt: date('ends_at'),
            active: row['active'] == true,
          );
        })
        .toList(growable: false);
  }

  @override
  Future<int> saveRule(SalePriceRuleDraft draft, {int? id}) async {
    final raw = await _client.rpc(
      'save_sale_price_rule_v1',
      params: {
        'p_id': id,
        'p_name': draft.name.trim(),
        'p_product_id': draft.productId,
        'p_presentation_code': draft.presentationCode?.trim().toLowerCase(),
        'p_min_quantity': draft.minQuantity,
        'p_fixed_price': draft.fixedPrice,
        'p_discount_percent': draft.discountPercent,
        'p_priority': draft.priority,
        'p_starts_at': draft.startsAt == null
            ? null
            : AppTime.toIsoLima(draft.startsAt!),
        'p_ends_at': draft.endsAt == null
            ? null
            : AppTime.toIsoLima(draft.endsAt!),
        'p_active': draft.active,
      },
    );
    if (raw is! Map || raw['id'] is! num) {
      throw const FormatException(
        'No se recibió el identificador de la regla.',
      );
    }
    return (raw['id'] as num).toInt();
  }

  @override
  Future<void> deleteRule(int id) =>
      _client.rpc('delete_sale_price_rule_v1', params: {'p_id': id});
}
