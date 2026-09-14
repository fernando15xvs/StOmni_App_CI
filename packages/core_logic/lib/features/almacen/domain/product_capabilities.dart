import 'commercial_presentation.dart';

/// Capacidades comerciales y operativas de un producto.
///
/// No codifica categorías de negocio concretas. Las capacidades pueden venir
/// de configuración por categoría o por producto y una interfaz únicamente
/// consulta este contrato.
class ProductCapabilities {
  ProductCapabilities({
    this.sellable = true,
    this.tracksInventory = true,
    this.allowSaleWithoutStock = false,
    this.tracksLots = false,
    this.tracksSerialNumbers = false,
    this.tracksExpiration = false,
    Iterable<String> allowedPresentationCodes = const <String>[],
  }) : allowedPresentationCodes = Set<String>.unmodifiable(
         allowedPresentationCodes
             .map(CommercialPresentation.normalizeCode)
             .where((code) => code.isNotEmpty),
       );

  final bool sellable;
  final bool tracksInventory;
  final bool allowSaleWithoutStock;
  final bool tracksLots;
  final bool tracksSerialNumbers;
  final bool tracksExpiration;

  /// Presentaciones autorizadas para vender el producto.
  ///
  /// Vacío significa que cualquier presentación definida en el perfil
  /// comercial está permitida.
  final Set<String> allowedPresentationCodes;

  factory ProductCapabilities.legacy({
    required ProductUnitProfile commercialProfile,
    required bool allowSaleWithoutStock,
  }) {
    return ProductCapabilities(
      allowSaleWithoutStock: allowSaleWithoutStock,
      allowedPresentationCodes: commercialProfile.presentations.map(
        (presentation) => presentation.code,
      ),
    );
  }

  bool supportsPresentation(String code) {
    if (!sellable) return false;
    final normalized = CommercialPresentation.normalizeCode(code);
    if (normalized.isEmpty) return false;
    return allowedPresentationCodes.isEmpty ||
        allowedPresentationCodes.contains(normalized);
  }

  List<CommercialPresentation> allowedPresentations(ProductUnitProfile profile) {
    return profile.presentations
        .where((presentation) => supportsPresentation(presentation.code))
        .toList(growable: false);
  }

  bool isCompatibleWith(ProductUnitProfile profile) {
    if (allowedPresentationCodes.isEmpty) return true;
    return allowedPresentationCodes.every(profile.supports);
  }
}

/// Política configurable con precedencia producto > categoría > defaults.
///
/// Las claves de categoría se normalizan únicamente como texto; el core no
/// conoce ni enumera sectores comerciales.
class ProductCapabilityPolicy {
  ProductCapabilityPolicy({
    ProductCapabilities? defaults,
    Map<String, ProductCapabilities> categoryOverrides =
        const <String, ProductCapabilities>{},
    Map<int, ProductCapabilities> productOverrides =
        const <int, ProductCapabilities>{},
  }) : defaults = defaults ?? ProductCapabilities(),
       categoryOverrides = Map<String, ProductCapabilities>.unmodifiable({
         for (final entry in categoryOverrides.entries)
           normalizeCategory(entry.key): entry.value,
       }),
       productOverrides = Map<int, ProductCapabilities>.unmodifiable(
         productOverrides,
       );

  final ProductCapabilities defaults;
  final Map<String, ProductCapabilities> categoryOverrides;
  final Map<int, ProductCapabilities> productOverrides;

  ProductCapabilities resolve({required int productId, String? category}) {
    final product = productOverrides[productId];
    if (product != null) return product;

    final normalizedCategory = normalizeCategory(category ?? '');
    final byCategory = categoryOverrides[normalizedCategory];
    return byCategory ?? defaults;
  }

  static String normalizeCategory(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }
}
