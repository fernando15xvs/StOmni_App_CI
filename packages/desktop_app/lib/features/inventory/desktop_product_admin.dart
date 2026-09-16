import 'dart:typed_data';

import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

class _DesktopProductInventoryWriteAdapter
    implements ProductInventoryWriteGateway {
  const _DesktopProductInventoryWriteAdapter(this.repository);

  final AlmacenRepository repository;

  @override
  Future<int> crearProductoConStock(
    String requestId,
    Map<String, dynamic> productData,
    List<Map<String, dynamic>> initialStock,
  ) => repository.crearProductoConStock(requestId, productData, initialStock);

  @override
  Future<void> guardarProductoNuevoOEditado(
    Map<String, dynamic> productData, {
    required int id,
    bool actualizarApertura = false,
  }) => repository.guardarProductoNuevoOEditado(
    productData,
    id: id,
    actualizarApertura: actualizarApertura,
  );
}

class _DesktopProductAdminAdapter implements ProductAdminGateway {
  const _DesktopProductAdminAdapter(this.repository);

  final ProductoAdminRepository repository;

  @override
  Future<bool> existeCodigoEnOtroProducto({
    required String codigo,
    int? productoIdActual,
  }) => repository.existeCodigoEnOtroProducto(
    codigo: codigo,
    productoIdActual: productoIdActual,
  );

  @override
  Future<bool> existeNombreEquivalente({
    required String nombre,
    required String tipoVenta,
    required int? proveedorId,
    int? productoIdActual,
  }) => repository.existeNombreEquivalente(
    nombre: nombre,
    tipoVenta: tipoVenta,
    proveedorId: proveedorId,
    productoIdActual: productoIdActual,
  );

  @override
  Future<String?> obtenerImagenActual(int productoId) =>
      repository.obtenerImagenActual(productoId);

  @override
  Future<ProductImageUpload> subirImagen(Uint8List bytes) async {
    final result = await repository.subirImagen(bytes);
    return ProductImageUpload(url: result.url);
  }

  @override
  Future<void> limpiarImagenAnteriorSiReemplazada({
    required int productoId,
    required String? imagenAnterior,
    required String? imagenNueva,
  }) => repository.limpiarImagenAnteriorSiReemplazada(
    productoId: productoId,
    imagenAnterior: imagenAnterior,
    imagenNueva: imagenNueva,
  );

  @override
  Future<void> limpiarImagenSiNoReferenciada(String? imageUrl) =>
      repository.limpiarImagenSiNoReferenciada(imageUrl);
}

final desktopSaveProductUseCaseProvider = Provider<SaveProductUseCase>((ref) {
  return SaveProductUseCase(
    inventory: _DesktopProductInventoryWriteAdapter(
      ref.read(almacenRepositoryProvider),
    ),
    productAdmin: _DesktopProductAdminAdapter(
      ref.read(productoAdminRepositoryProvider),
    ),
    uuid: const Uuid(),
    authorizer: ref.read(operationAuthorizerProvider),
  );
});

final desktopProductFormCatalogProvider =
    FutureProvider.autoDispose<ProductFormCatalog>(
      (ref) => LoadProductFormCatalogUseCase(
        AlmacenProductFormCatalogGateway(ref.read(almacenRepositoryProvider)),
      ).execute(),
    );

final desktopProductUnitGatewayProvider =
    Provider<ProductUnitConfigurationGateway>(
      (ref) =>
          SupabaseProductUnitConfigurationGateway(ref.read(supabaseProvider)),
    );

final desktopProductUnitSettingsProvider = FutureProvider.autoDispose
    .family<ProductUnitSettings, int>((ref, productId) {
      return ref.watch(desktopProductUnitGatewayProvider).load(productId);
    });

final desktopSaveProductUnitConfigurationUseCaseProvider =
    Provider<SaveProductUnitConfigurationUseCase>((ref) {
      return SaveProductUnitConfigurationUseCase(
        gateway: ref.watch(desktopProductUnitGatewayProvider),
        authorizer: ref.watch(operationAuthorizerProvider),
      );
    });
