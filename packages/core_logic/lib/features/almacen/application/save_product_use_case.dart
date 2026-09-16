import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../../errors/user_facing_exception.dart';
import '../../../auth/application/operation_authorizer.dart';
import '../../../auth/domain/app_permission.dart';
import '../../../utils/stock_utils.dart';

class ProductImageUpload {
  const ProductImageUpload({required this.url});

  final String url;
}

abstract interface class ProductInventoryWriteGateway {
  Future<int> crearProductoConStock(
    String requestId,
    Map<String, dynamic> productData,
    List<Map<String, dynamic>> initialStock,
  );

  Future<void> guardarProductoNuevoOEditado(
    Map<String, dynamic> productData, {
    required int id,
    bool actualizarApertura = false,
  });
}

abstract interface class ProductAdminGateway {
  Future<bool> existeCodigoEnOtroProducto({
    required String codigo,
    int? productoIdActual,
  });

  Future<bool> existeNombreEquivalente({
    required String nombre,
    required String tipoVenta,
    required int? proveedorId,
    int? productoIdActual,
  });

  Future<String?> obtenerImagenActual(int productoId);

  Future<ProductImageUpload> subirImagen(Uint8List bytes);

  Future<void> limpiarImagenAnteriorSiReemplazada({
    required int productoId,
    required String? imagenAnterior,
    required String? imagenNueva,
  });

  Future<void> limpiarImagenSiNoReferenciada(String? imageUrl);
}

class SaveProductCommand {
  const SaveProductCommand({
    required this.requestId,
    required this.productId,
    required this.code,
    required this.name,
    required this.unitPrice,
    required this.packageBasePrice,
    required this.purchasePrice,
    required this.unitsPerPackage,
    required this.saleUnitType,
    required this.minimumStock,
    required this.supplierId,
    required this.allowWithoutStock,
    required this.newImageBytes,
    required this.existingImageUrl,
    required this.warehouseIds,
    required this.boxesByWarehouse,
    required this.baseUnitsByWarehouse,
    this.updateOpeningMovements = false,
  });

  final String requestId;
  final int? productId;
  final String code;
  final String name;
  final double unitPrice;
  final double packageBasePrice;
  final double purchasePrice;
  final int unitsPerPackage;
  final SaleUnitType saleUnitType;
  final num minimumStock;
  final int? supplierId;
  final bool allowWithoutStock;
  final Uint8List? newImageBytes;
  final String? existingImageUrl;
  final List<int> warehouseIds;
  final Map<int, int> boxesByWarehouse;
  final Map<int, int> baseUnitsByWarehouse;
  final bool updateOpeningMovements;

  bool get isNew => productId == null;
}

class SaveProductResult {
  const SaveProductResult({required this.productId, required this.created});

  final int productId;
  final bool created;
}

class SaveProductUseCase {
  SaveProductUseCase({
    required ProductInventoryWriteGateway inventory,
    required ProductAdminGateway productAdmin,
    required Uuid uuid,
    required OperationAuthorizer authorizer,
  }) : _inventory = inventory,
       _productAdmin = productAdmin,
       _uuid = uuid,
       _authorizer = authorizer;

  final ProductInventoryWriteGateway _inventory;
  final ProductAdminGateway _productAdmin;
  final Uuid _uuid;
  final OperationAuthorizer _authorizer;

  String createRequestId() => _uuid.v4();

  Future<SaveProductResult> execute(SaveProductCommand command) async {
    final requestId = command.requestId.trim();
    if (requestId.isEmpty) {
      throw const UserFacingException(
        'No se pudo identificar la operación. Inténtalo nuevamente.',
      );
    }

    final code = command.code.trim().toUpperCase();
    final name = command.name.trim();
    _validate(command, normalizedCode: code, normalizedName: name);

    final authorizedUser = await _authorizer.require({
      command.isNew
          ? AppPermission.productsCreate
          : AppPermission.productsUpdate,
      AppPermission.productsChangePrice,
      if (command.updateOpeningMovements) AppPermission.inventoryAdjust,
    });
    void checkSession() {
      if (_authorizer.currentAuthUserId != authorizedUser) {
        throw const UserFacingException(
          'La sesión cambió durante el guardado del producto.',
        );
      }
    }

    final saleTypeDb = StockUtils.toDatabaseValue(command.saleUnitType);

    final duplicatedCode = await _productAdmin.existeCodigoEnOtroProducto(
      codigo: code,
      productoIdActual: command.productId,
    );
    if (duplicatedCode) {
      throw UserFacingException('Ya existe un producto con el código $code.');
    }

    final duplicatedName = await _productAdmin.existeNombreEquivalente(
      nombre: name,
      tipoVenta: saleTypeDb,
      proveedorId: command.supplierId,
      productoIdActual: command.productId,
    );
    if (duplicatedName) {
      throw const UserFacingException(
        'Ya existe un producto con el mismo nombre, proveedor y tipo de venta.',
      );
    }

    ProductImageUpload? uploadedImage;
    String? previousImage;

    try {
      checkSession();
      final currentId = command.productId;
      if (currentId != null) {
        previousImage = await _productAdmin.obtenerImagenActual(currentId);
      }

      var finalImageUrl = command.existingImageUrl?.trim() ?? '';
      final imageBytes = command.newImageBytes;
      if (imageBytes != null) {
        checkSession();
        uploadedImage = await _productAdmin.subirImagen(imageBytes);
        finalImageUrl = uploadedImage.url;
      }

      final productData = <String, dynamic>{
        'codigo': code,
        'nombre': name,
        'precio_unidad': command.unitPrice,
        'precio_caja': command.packageBasePrice,
        'precio_compra': command.purchasePrice,
        'imagen_path': finalImageUrl,
        'unidad_medida': StockUtils.unidadBasePlural(command.saleUnitType),
        'cantidad_por_caja': command.unitsPerPackage,
        'proveedor_id': command.supplierId,
        'permitir_sin_stock': command.allowWithoutStock,
        'tipo_venta': saleTypeDb,
        'stock_minimo': command.minimumStock,
      };

      late final int savedProductId;
      checkSession();
      if (command.isNew) {
        final initialStock = _buildInitialStock(command);
        savedProductId = await _inventory.crearProductoConStock(
          requestId,
          productData,
          initialStock,
        );
      } else {
        await _inventory.guardarProductoNuevoOEditado(
          productData,
          id: currentId!,
          actualizarApertura: command.updateOpeningMovements,
        );
        savedProductId = currentId;
      }

      await _productAdmin.limpiarImagenAnteriorSiReemplazada(
        productoId: savedProductId,
        imagenAnterior: previousImage,
        imagenNueva: finalImageUrl,
      );

      return SaveProductResult(
        productId: savedProductId,
        created: command.isNew,
      );
    } catch (_) {
      final uploaded = uploadedImage;
      if (uploaded != null) {
        await _productAdmin.limpiarImagenSiNoReferenciada(uploaded.url);
      }
      rethrow;
    }
  }

  void _validate(
    SaveProductCommand command, {
    required String normalizedCode,
    required String normalizedName,
  }) {
    if (normalizedCode.isEmpty) {
      throw const UserFacingException('El código del producto es obligatorio.');
    }
    if (normalizedCode.length > 50) {
      throw const UserFacingException(
        'El código no puede superar 50 caracteres.',
      );
    }
    if (!RegExp(r'^[A-Z0-9._/-]+$').hasMatch(normalizedCode)) {
      throw const UserFacingException(
        'El código solo puede contener letras, números, punto, guion, barra o guion bajo.',
      );
    }
    if (normalizedName.isEmpty) {
      throw const UserFacingException(
        'El nombre del producto no puede estar vacío.',
      );
    }
    if (!command.unitPrice.isFinite ||
        !command.packageBasePrice.isFinite ||
        !command.purchasePrice.isFinite ||
        !command.minimumStock.isFinite ||
        command.unitPrice < 0 ||
        command.packageBasePrice < 0 ||
        command.purchasePrice < 0 ||
        command.minimumStock < 0) {
      throw const UserFacingException(
        'Los precios, costos y stock mínimo deben ser números válidos no negativos.',
      );
    }
    if (command.unitsPerPackage < 1) {
      throw const UserFacingException(
        'Para ventas por empaque, la cantidad por empaque debe ser al menos 1.',
      );
    }
    if (command.boxesByWarehouse.values.any((value) => value < 0) ||
        command.baseUnitsByWarehouse.values.any((value) => value < 0)) {
      throw const UserFacingException(
        'El stock inicial no puede ser negativo.',
      );
    }
  }

  List<Map<String, dynamic>> _buildInitialStock(SaveProductCommand command) {
    final stock = <Map<String, dynamic>>[];
    final fullPackagePrice = StockUtils.calcularPrecioEmpaqueCompleto(
      precioBaseEmpaque: command.packageBasePrice,
      pcs: command.unitsPerPackage,
    );

    for (final warehouseId in command.warehouseIds.toSet()) {
      final boxes = command.boxesByWarehouse[warehouseId] ?? 0;
      final baseUnits = command.baseUnitsByWarehouse[warehouseId] ?? 0;
      if (boxes <= 0 && baseUnits <= 0) continue;

      final totalBase = StockUtils.calcularTotalPiezas(
        cajas: boxes,
        unidades: baseUnits,
        tipoVenta: command.saleUnitType,
        pcs: command.unitsPerPackage,
      );
      final inventoryBasePrice = command.saleUnitType == SaleUnitType.paquete
          ? fullPackagePrice
          : command.unitPrice;

      stock.add({
        'almacen_id': warehouseId,
        'delta': totalBase,
        'tipo_movimiento': 'ENTRADA',
        'motivo': 'Apertura de Inventario / Stock Inicial',
        'ingreso_costo': command.purchasePrice,
        'ingreso_p_unit': inventoryBasePrice,
        'ingreso_p_caja': command.packageBasePrice,
        'ingreso_p_c_comp': fullPackagePrice,
        'unidad_label': StockUtils.unidadBaseSingular(command.saleUnitType),
      });
    }

    return stock;
  }
}
