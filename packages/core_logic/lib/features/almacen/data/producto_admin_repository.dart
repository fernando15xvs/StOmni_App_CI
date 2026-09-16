import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:core_logic/core_logic.dart';

final productoAdminRepositoryProvider = Provider<ProductoAdminRepository>((
  ref,
) {
  return ProductoAdminRepository(ref.read(supabaseProvider));
});

class UploadedProductImage {
  const UploadedProductImage({required this.path, required this.url});

  final String path;
  final String url;
}

class ProductoAdminRepository {
  ProductoAdminRepository(this._client);

  static const _imageBucket = 'imagenes_productos';

  final SupabaseClient _client;

  Future<String> _requireAdmin() async {
    final user = _client.auth.currentUser;
    if (user == null) {
      throw const UserFacingException(
        'Tu sesión ya no está disponible. Inicia sesión nuevamente.',
      );
    }

    try {
      final raw = await _client.rpc('get_my_tenant_context_v1');
      if (raw is! Map) {
        throw const UserFacingException(
          'No se pudo validar la empresa activa de tu sesión.',
        );
      }
      final context = Map<String, dynamic>.from(raw);
      final organizationId =
          context['organization_id']?.toString().trim() ?? '';
      final role = context['base_role']?.toString();
      if (organizationId.isEmpty || !AppRoles.isAdmin(role)) {
        throw const UserFacingException(
          'Solo un administrador activo puede crear o editar productos.',
        );
      }
      return organizationId;
    } on UserFacingException {
      rethrow;
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  Future<bool> existeCodigoEnOtroProducto({
    required String codigo,
    int? productoIdActual,
  }) async {
    await _requireAdmin();
    final rows = await _client
        .from('productos')
        .select('id')
        .ilike('codigo', codigo)
        .limit(2);

    for (final row in rows) {
      final id = (row['id'] as num).toInt();
      if (productoIdActual == null || id != productoIdActual) return true;
    }
    return false;
  }

  Future<bool> existeNombreEquivalente({
    required String nombre,
    required String tipoVenta,
    required int? proveedorId,
    int? productoIdActual,
  }) async {
    await _requireAdmin();
    var query = _client
        .from('productos')
        .select('id')
        .ilike('nombre', nombre)
        .eq('tipo_venta', tipoVenta)
        .eq('activo', true);

    if (proveedorId != null) {
      query = query.eq('proveedor_id', proveedorId);
    } else {
      query = query.isFilter('proveedor_id', null);
    }

    final rows = await query.limit(2);
    for (final row in rows) {
      final id = (row['id'] as num).toInt();
      if (productoIdActual == null || id != productoIdActual) return true;
    }
    return false;
  }

  Future<String?> obtenerImagenActual(int productoId) async {
    await _requireAdmin();
    final row = await _client
        .from('productos')
        .select('imagen_path')
        .eq('id', productoId)
        .maybeSingle();
    final value = row?['imagen_path']?.toString().trim() ?? '';
    return value.isEmpty ? null : value;
  }

  Future<UploadedProductImage> subirImagen(Uint8List bytes) async {
    final organizationId = await _requireAdmin();
    if (bytes.isEmpty) {
      throw const UserFacingException('La imagen seleccionada está vacía.');
    }

    try {
      final fileName =
          '$organizationId/products/${DateTime.now().microsecondsSinceEpoch}_producto.jpg';
      final bucket = _client.storage.from(_imageBucket);
      await bucket.uploadBinary(
        fileName,
        bytes,
        fileOptions: const FileOptions(
          contentType: 'image/jpeg',
          cacheControl: '3600',
          upsert: false,
        ),
      );
      return UploadedProductImage(
        path: fileName,
        url: bucket.getPublicUrl(fileName),
      );
    } catch (e) {
      throw UserFacingException(ErrorMapper.map(e));
    }
  }

  /// Limpia una imagen recién subida únicamente cuando PostgreSQL confirma que
  /// ningún producto la referencia. Si la comprobación falla (por ejemplo por
  /// pérdida de conexión), no borra nada: es preferible dejar un huérfano
  /// temporal a eliminar un archivo que pudo quedar confirmado en la BD.
  Future<void> limpiarImagenSiNoReferenciada(String? imageUrl) async {
    final url = imageUrl?.trim() ?? '';
    if (url.isEmpty) return;

    try {
      final organizationId = await _requireAdmin();
      await _removeIfUnreferenced(url, organizationId);
    } catch (e) {
      debugPrint('Limpieza diferida de imagen de producto: $e');
    }
  }

  /// Después de un guardado confirmado, elimina la imagen anterior solo si la
  /// fila del producto ya refleja exactamente el nuevo valor. Esto protege el
  /// caso de respuestas inciertas y evita borrar la imagen todavía vigente.
  Future<void> limpiarImagenAnteriorSiReemplazada({
    required int productoId,
    required String? imagenAnterior,
    required String? imagenNueva,
  }) async {
    final anterior = imagenAnterior?.trim() ?? '';
    final nueva = imagenNueva?.trim() ?? '';
    if (anterior.isEmpty || anterior == nueva) return;

    try {
      final organizationId = await _requireAdmin();
      final row = await _client
          .from('productos')
          .select('imagen_path')
          .eq('id', productoId)
          .maybeSingle();
      if (row == null) return;

      final actual = row['imagen_path']?.toString().trim() ?? '';
      if (actual != nueva) return;

      await _removeIfUnreferenced(anterior, organizationId);
    } catch (e) {
      debugPrint('No se pudo limpiar la imagen anterior del producto: $e');
    }
  }

  Future<void> _removeIfUnreferenced(
    String publicUrl,
    String organizationId,
  ) async {
    final reference = await _client
        .from('productos')
        .select('id')
        .eq('imagen_path', publicUrl)
        .limit(1)
        .maybeSingle();
    if (reference != null) return;

    final path = _storagePathFromPublicUrl(publicUrl);
    if (path == null || path.isEmpty) return;
    if (!path.startsWith('$organizationId/')) return;

    await _client.storage.from(_imageBucket).remove([path]);
  }

  String? _storagePathFromPublicUrl(String publicUrl) {
    final uri = Uri.tryParse(publicUrl);
    if (uri == null) return null;

    const marker = '/storage/v1/object/public/$_imageBucket/';
    final index = uri.path.indexOf(marker);
    if (index < 0) return null;

    final encodedPath = uri.path.substring(index + marker.length);
    if (encodedPath.isEmpty) return null;
    final path = Uri.decodeComponent(encodedPath);
    if (path.contains('..')) return null;
    return path;
  }
}
