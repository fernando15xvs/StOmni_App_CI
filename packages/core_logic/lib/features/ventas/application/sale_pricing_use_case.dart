import '../../../auth/application/operation_authorizer.dart';
import '../../../auth/domain/app_permission.dart';
import '../domain/sale_pricing.dart';

abstract interface class SalePricingGateway {
  Future<SalePriceQuote> resolve({
    required int productId,
    required String presentationCode,
    required double quantity,
    DateTime? at,
  });

  Future<List<SalePriceRule>> listRules();
  Future<int> saveRule(SalePriceRuleDraft draft, {int? id});
  Future<void> deleteRule(int id);
}

class ResolveSalePriceUseCase {
  const ResolveSalePriceUseCase(this._gateway);
  final SalePricingGateway _gateway;

  Future<SalePriceQuote> call({
    required int productId,
    required String presentationCode,
    required double quantity,
    DateTime? at,
  }) {
    if (productId <= 0 ||
        presentationCode.trim().isEmpty ||
        !quantity.isFinite ||
        quantity <= 0) {
      throw ArgumentError('Producto, presentación o cantidad inválidos.');
    }
    return _gateway.resolve(
      productId: productId,
      presentationCode: presentationCode.trim().toLowerCase(),
      quantity: quantity,
      at: at,
    );
  }
}

class ManageSalePriceRulesUseCase {
  const ManageSalePriceRulesUseCase({
    required SalePricingGateway gateway,
    required OperationAuthorizer authorizer,
  }) : _gateway = gateway,
       _authorizer = authorizer;

  final SalePricingGateway _gateway;
  final OperationAuthorizer _authorizer;

  Future<List<SalePriceRule>> list() async {
    await _authorizer.require({AppPermission.productsChangePrice});
    return _gateway.listRules();
  }

  Future<int> save(SalePriceRuleDraft draft, {int? id}) async {
    _validate(draft);
    final user = await _authorizer.require({AppPermission.productsChangePrice});
    final result = await _gateway.saveRule(draft, id: id);
    if (_authorizer.currentAuthUserId != user) {
      throw StateError('La sesión cambió durante la edición de precios.');
    }
    return result;
  }

  Future<void> delete(int id) async {
    if (id <= 0) throw ArgumentError('Regla de precio inválida.');
    final user = await _authorizer.require({AppPermission.productsChangePrice});
    await _gateway.deleteRule(id);
    if (_authorizer.currentAuthUserId != user) {
      throw StateError('La sesión cambió durante la edición de precios.');
    }
  }

  void _validate(SalePriceRuleDraft draft) {
    if (draft.name.trim().isEmpty ||
        draft.productId <= 0 ||
        !draft.minQuantity.isFinite ||
        draft.minQuantity <= 0) {
      throw ArgumentError('La regla de precio está incompleta.');
    }
    final hasFixed = draft.fixedPrice != null;
    final hasDiscount = draft.discountPercent != null;
    if (hasFixed == hasDiscount) {
      throw ArgumentError('Define precio fijo o porcentaje, no ambos.');
    }
    if (hasFixed && (!draft.fixedPrice!.isFinite || draft.fixedPrice! < 0)) {
      throw ArgumentError('El precio fijo no es válido.');
    }
    if (hasDiscount &&
        (!draft.discountPercent!.isFinite ||
            draft.discountPercent! <= 0 ||
            draft.discountPercent! > 100)) {
      throw ArgumentError('El porcentaje no es válido.');
    }
    if (draft.endsAt != null &&
        draft.startsAt != null &&
        !draft.endsAt!.isAfter(draft.startsAt!)) {
      throw ArgumentError(
        'El fin de la promoción debe ser posterior al inicio.',
      );
    }
  }
}
