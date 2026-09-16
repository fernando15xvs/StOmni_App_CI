import 'package:core_logic/auth/application/operation_authorizer.dart';
import 'package:core_logic/auth/domain/app_permission.dart';
import 'package:core_logic/features/ventas/application/sale_pricing_use_case.dart';
import 'package:core_logic/features/ventas/domain/sale_pricing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolver normaliza presentación y conserva regla aplicada', () async {
    final gateway = _PricingGateway();
    final quote = await ResolveSalePriceUseCase(gateway)(
      productId: 7,
      presentationCode: ' CAJA ',
      quantity: 3,
    );
    expect(gateway.lastPresentation, 'caja');
    expect(quote.price, 90);
    expect(quote.ruleId, 4);
  });

  test('administración rechaza reglas ambiguas antes del gateway', () async {
    final gateway = _PricingGateway();
    final useCase = ManageSalePriceRulesUseCase(
      gateway: gateway,
      authorizer: _AllowAllAuthorizer(),
    );
    await expectLater(
      useCase.save(
        const SalePriceRuleDraft(
          name: 'Invalida',
          productId: 1,
          minQuantity: 1,
          priority: 0,
          active: true,
          fixedPrice: 10,
          discountPercent: 5,
        ),
      ),
      throwsArgumentError,
    );
    expect(gateway.saved, isFalse);
  });
}

class _PricingGateway implements SalePricingGateway {
  String? lastPresentation;
  bool saved = false;

  @override
  Future<SalePriceQuote> resolve({
    required int productId,
    required String presentationCode,
    required double quantity,
    DateTime? at,
  }) async {
    lastPresentation = presentationCode;
    return SalePriceQuote(
      productId: productId,
      presentationCode: presentationCode,
      quantity: quantity,
      catalogPrice: 100,
      price: 90,
      ruleId: 4,
      ruleName: 'Mayorista',
    );
  }

  @override
  Future<List<SalePriceRule>> listRules() async => const [];

  @override
  Future<int> saveRule(SalePriceRuleDraft draft, {int? id}) async {
    saved = true;
    return id ?? 1;
  }

  @override
  Future<void> deleteRule(int id) async {}
}

class _AllowAllAuthorizer implements OperationAuthorizer {
  @override
  String? get currentAuthUserId => 'u1';

  @override
  Future<String> require(
    Set<AppPermission> permissions, {
    bool allowOffline = false,
  }) async => 'u1';
}
