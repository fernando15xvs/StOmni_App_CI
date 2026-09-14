import 'dart:typed_data';

import 'package:core_logic/core_logic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

class _ProductInventoryWriteAdapter implements ProductInventoryWriteGateway {
  const _ProductInventoryWriteAdapter(this._repository);

  final AlmacenRepository _repository;

  @override
  Future<int> crearProductoConStock(
    String requestId,
    Map<String, dynamic> productData,
    List<Map<String, dynamic>> initialStock,
  ) => _repository.crearProductoConStock(
    requestId,
    productData,
    initialStock,
  );

  @override
  Future<void> guardarProductoNuevoOEditado(
    Map<String, dynamic> productData, {
    required int id,
    bool actualizarApertura = false,
  }) => _repository.guardarProductoNuevoOEditado(
    productData,
    id: id,
    actualizarApertura: actualizarApertura,
  );
}

class _ProductAdminAdapter implements ProductAdminGateway {
  const _ProductAdminAdapter(this._repository);

  final ProductoAdminRepository _repository;

  @override
  Future<bool> existeCodigoEnOtroProducto({
    required String codigo,
    int? productoIdActual,
  }) => _repository.existeCodigoEnOtroProducto(
    codigo: codigo,
    productoIdActual: productoIdActual,
  );

  @override
  Future<bool> existeNombreEquivalente({
    required String nombre,
    required String tipoVenta,
    required int? proveedorId,
    int? productoIdActual,
  }) => _repository.existeNombreEquivalente(
    nombre: nombre,
    tipoVenta: tipoVenta,
    proveedorId: proveedorId,
    productoIdActual: productoIdActual,
  );

  @override
  Future<String?> obtenerImagenActual(int productoId) =>
      _repository.obtenerImagenActual(productoId);

  @override
  Future<ProductImageUpload> subirImagen(Uint8List bytes) async {
    final uploaded = await _repository.subirImagen(bytes);
    return ProductImageUpload(url: uploaded.url);
  }

  @override
  Future<void> limpiarImagenAnteriorSiReemplazada({
    required int productoId,
    required String? imagenAnterior,
    required String? imagenNueva,
  }) => _repository.limpiarImagenAnteriorSiReemplazada(
    productoId: productoId,
    imagenAnterior: imagenAnterior,
    imagenNueva: imagenNueva,
  );

  @override
  Future<void> limpiarImagenSiNoReferenciada(String? imageUrl) =>
      _repository.limpiarImagenSiNoReferenciada(imageUrl);
}

/// Compone las dependencias de infraestructura que necesita el caso de uso.
/// La lógica de guardado permanece independiente de Riverpod y de la UI.
final saveProductUseCaseProvider = Provider<SaveProductUseCase>((ref) {
  return SaveProductUseCase(
    inventory: _ProductInventoryWriteAdapter(ref.read(almacenRepositoryProvider)),
    productAdmin: _ProductAdminAdapter(
      ref.read(productoAdminRepositoryProvider),
    ),
    uuid: const Uuid(),
    authorizer: ref.read(operationAuthorizerProvider),
  );
});
