import '../domain/sale_cart.dart';
import 'price_sale_line_use_case.dart';
import 'sale_pricing_use_case.dart';

class AuthoritativePriceSaleLineUseCase {
  const AuthoritativePriceSaleLineUseCase(this._pricing);
  final ResolveSalePriceUseCase _pricing;

  Future<SaleCartLine> execute(SaleCartLine line, {DateTime? at}) async {
    final quote = await _pricing(
      productId: line.productId,
      presentationCode: line.commercialUnit,
      quantity: line.quantity,
      at: at,
    );
    return const PriceSaleLineUseCase().execute(
      line,
      commercialUnitPrice: quote.price,
    );
  }
}
