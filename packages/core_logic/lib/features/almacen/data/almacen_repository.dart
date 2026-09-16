import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../constants/app_roles.dart';
import '../../../providers/supabase_provider.dart';
import '../../../services/inventario_service.dart';
import '../../shared/models/producto_busqueda.dart';
import '../domain/producto.dart';
import 'almacen_sync_contract.dart';
import 'local_db_service.dart';
import 'supabase_product_unit_configuration_gateway.dart';

// Compatibilidad temporal: algunos callers antiguos todavía importan este
// archivo para obtener supabaseProvider. Los nuevos imports deben apuntar a
// core/providers/supabase_provider.dart.
export '../../../providers/supabase_provider.dart' show supabaseProvider;

final almacenRepositoryProvider = Provider<AlmacenRepository>((ref) {
  return AlmacenRepository(
    ref.read(supabaseProvider),
    ref.read(localDbServiceProvider),
  );
});

class AlmacenRepository {
  final SupabaseClient _client;
  final LocalDbService _localDb;

  Future<void>? _syncEnCurso;
  bool _esperandoSyncSilenciosa = false;

  AlmacenRepository(this._client, this._localDb);

  Future<Map<String, dynamic>> _tenantContext() async {
    if (_client.auth.currentUser == null) {
      throw Exception('Usuario no autenticado.');
    }
    final raw = await _client.rpc('get_my_tenant_context_v1');
    if (raw is! Map) {
      throw StateError('No se pudo validar el contexto de la empresa.');
    }
    return Map<String, dynamic>.from(raw);
  }

  Future<void> _requireAdmin() async {
    final context = await _tenantContext();
    if (!AppRoles.isAdmin(context['base_role']?.toString())) {
      throw Exception(
        'Solo el administrador puede crear, editar o desactivar productos.',
      );
    }
  }

  /// Sincroniza los datos de Supabase hacia la base de datos local SQLite.
  ///
  /// La sincronización usa un contrato explícito remoto -> caché y cursor por
  /// `id`. Así una columna nueva en Supabase no rompe SQLite y un catálogo de
  /// más de 1000 productos no depende de offsets inestables.
  Future<void> sincronizarConSupabase({bool propagarError = false}) async {
    final future = _syncEnCurso ??= _sincronizarConSupabaseInterno();
    try {
      await future;
    } catch (e) {
      debugPrint('Error sincronizando con Supabase: $e');
      if (propagarError) rethrow;
    } finally {
      if (identical(_syncEnCurso, future)) _syncEnCurso = null;
    }
  }

  Future<void> _sincronizarConSupabaseInterno() async {
    debugPrint('🔄 Iniciando sincronización con Supabase...');

    final almacenesData = await _client
        .from('almacenes')
        .select(AlmacenSyncContract.almacenSelect)
        .eq('activo', true)
        .order('id');
    await _localDb.insertaralmacenes(
      List<Map<String, dynamic>>.from(
        almacenesData,
      ).map(AlmacenSyncContract.almacenParaCache).toList(growable: false),
    );

    final proveedoresData = await _client
        .from('proveedores')
        .select(AlmacenSyncContract.proveedorSelect)
        .order('id');
    await _localDb.insertarProveedores(
      List<Map<String, dynamic>>.from(
        proveedoresData,
      ).map(AlmacenSyncContract.proveedorParaCache).toList(growable: false),
    );

    final todosLosProductos = <Map<String, dynamic>>[];
    int? ultimoId;

    while (true) {
      final rawBatch = ultimoId == null
          ? await _client
                .from('productos')
                .select(AlmacenSyncContract.productoSelect)
                .eq('activo', true)
                .order('id')
                .limit(AlmacenSyncContract.productPageSize)
          : await _client
                .from('productos')
                .select(AlmacenSyncContract.productoSelect)
                .eq('activo', true)
                .gt('id', ultimoId)
                .order('id')
                .limit(AlmacenSyncContract.productPageSize);

      final batch = List<Map<String, dynamic>>.from(rawBatch);
      if (batch.isEmpty) break;

      todosLosProductos.addAll(
        (await SupabaseProductUnitConfigurationGateway(
          _client,
        ).attach(batch)).map(AlmacenSyncContract.productoParaCache),
      );
      ultimoId = AlmacenSyncContract.nextProductCursor(batch);

      if (!AlmacenSyncContract.hasMoreProducts(batch)) break;
    }

    await _localDb.insertarProductosBatch(todosLosProductos);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      'ultima_sincronizacion_productos',
      DateTime.now().millisecondsSinceEpoch,
    );

    debugPrint('✅ Sincronización completada exitosamente.');
  }

  /// Sincroniza un producto individual de inmediato.
  ///
  /// Si el producto fue desactivado remotamente, se elimina del caché local
  /// en vez de reinsertarlo como inactivo por un evento Realtime tardío.
  Future<void> sincronizarProductoLocal(
    int productoId, {
    bool propagarError = false,
  }) async {
    try {
      final fullSync = _syncEnCurso;
      if (fullSync != null) {
        try {
          await fullSync;
        } catch (_) {
          // El producto todavía puede recuperarse aunque fallara la carga global.
        }
      }
      final data = await _client
          .from('productos')
          .select(AlmacenSyncContract.productoSelect)
          .eq('id', productoId)
          .eq('activo', true)
          .maybeSingle();

      if (data == null) {
        await _localDb.eliminarProductoPorId(productoId);
        return;
      }

      await _localDb.upsertProductoUnico(
        AlmacenSyncContract.productoParaCache(
          (await SupabaseProductUnitConfigurationGateway(
            _client,
          ).attach([data])).single,
        ),
      );
    } catch (e) {
      debugPrint('Error en sync local de producto $productoId: $e');
      if (propagarError) rethrow;
    }
  }

  Future<List<Producto>> getProductosOnline({
    required int start,
    required int end,
    required String orderColumn,
    required bool ascending,
  }) async {
    final cache = await _localDb.getProductosOnline(
      start: start,
      end: end,
      orderColumn: orderColumn,
      ascending: ascending,
    );

    if (cache.isEmpty && start == 0) {
      await sincronizarConSupabase();
      return _localDb.getProductosOnline(
        start: start,
        end: end,
        orderColumn: orderColumn,
        ascending: ascending,
      );
    }
    return cache;
  }

  Future<List<Producto>> buscarProductos(String query) async {
    return _localDb.buscarProductos(query);
  }

  Future<List<ProductoBusqueda>> buscarProductosRapido(
    String query, {
    bool incluirInactivos = false,
  }) async {
    var resultados = await _localDb.buscarProductosRapido(
      query,
      incluirInactivos: incluirInactivos,
    );

    if (query.trim().isEmpty) {
      final hayCache = await _localDb.tieneProductosEnCache(
        incluirInactivos: incluirInactivos,
      );
      if (!hayCache) {
        await sincronizarConSupabase();
        resultados = await _localDb.buscarProductosRapido(
          query,
          incluirInactivos: incluirInactivos,
        );
      } else {
        await _programarSincronizacionSilenciosaSiCorresponde();
      }
    }
    return resultados;
  }

  Future<void> _programarSincronizacionSilenciosaSiCorresponde() async {
    final prefs = await SharedPreferences.getInstance();
    final lastSyncMs = prefs.getInt('ultima_sincronizacion_productos') ?? 0;
    final ahoraMs = DateTime.now().millisecondsSinceEpoch;

    if (ahoraMs - lastSyncMs < 600000 ||
        _esperandoSyncSilenciosa ||
        _syncEnCurso != null) {
      return;
    }

    _esperandoSyncSilenciosa = true;
    Future.delayed(const Duration(seconds: 3), () async {
      try {
        await sincronizarConSupabase();
      } finally {
        _esperandoSyncSilenciosa = false;
      }
    });
  }

  Future<void> desactivarProducto(int id) async {
    await _requireAdmin();
    await _client.from('productos').update({'activo': false}).eq('id', id);
    await _localDb.eliminarProductoPorId(id);
    sincronizarConSupabase();
  }

  Future<String> eliminarProducto(int id) async {
    await desactivarProducto(id);
    return 'deactivated';
  }

  Future<Map<String, dynamic>> evaluarEliminacionProducto(int id) async {
    await _requireAdmin();
    final raw = await _client.rpc(
      'evaluar_eliminacion_producto_v1',
      params: {'p_producto_id': id},
    );

    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    throw StateError(
      'evaluar_eliminacion_producto_v1 devolvió una respuesta inválida.',
    );
  }

  Future<Map<String, dynamic>> eliminarProductoDefinitivamente(int id) async {
    await _requireAdmin();
    final raw = await _client.rpc(
      'eliminar_producto_seguro_v1',
      params: {'p_producto_id': id},
    );

    final resultado = raw is Map<String, dynamic>
        ? raw
        : raw is Map
        ? Map<String, dynamic>.from(raw)
        : throw StateError(
            'eliminar_producto_seguro_v1 devolvió una respuesta inválida.',
          );

    await _localDb.eliminarProductoPorId(id);
    sincronizarConSupabase();
    return resultado;
  }

  Future<void> reactivarProducto(int id) async {
    await _requireAdmin();
    await _client.from('productos').update({'activo': true}).eq('id', id);
    sincronizarConSupabase();
  }

  Future<List<Map<String, dynamic>>> obtenerProductosInactivos() async {
    final data = await _client
        .from('productos')
        .select(AlmacenSyncContract.productoSelect)
        .eq('activo', false)
        .order('nombre');
    return List<Map<String, dynamic>>.from(data);
  }

  /// Compatibilidad de una API antigua de cantidad absoluta. Ya no escribe
  /// directamente la tabla de saldos: calcula el delta visible y delega al RPC
  /// autoritativo de inventario, que bloquea relaciones cross-tenant.
  Future<void> actualizarInventario({
    required int productoId,
    required int almacenId,
    required int cantidad,
  }) async {
    final row = await _client
        .from('inventario_almacen')
        .select('cantidad')
        .eq('producto_id', productoId)
        .eq('almacen_id', almacenId)
        .maybeSingle();
    final actual = (row?['cantidad'] as num?)?.toInt() ?? 0;
    final delta = cantidad - actual;
    if (delta != 0) {
      await InventarioService.ajustarStock(
        productoId: productoId,
        almacenId: almacenId,
        delta: delta.toDouble(),
        motivo: 'Actualización manual de inventario',
      );
    }
    await sincronizarProductoLocal(productoId);
    sincronizarConSupabase();
  }

  Future<List<Map<String, dynamic>>> getalmacenes() async {
    final almacenes = await _localDb.getalmacenes();
    if (almacenes.isEmpty) {
      await sincronizarConSupabase();
      return _localDb.getalmacenes();
    }
    return almacenes;
  }

  Future<Map<int, String>> getMarcas() async {
    final marcas = await _localDb.getMarcas();
    if (marcas.isEmpty) {
      await sincronizarConSupabase();
      return _localDb.getMarcas();
    }
    return marcas;
  }

  Future<List<dynamic>> obtenerAlmacenesDirecto() async {
    return _client
        .from('almacenes')
        .select(AlmacenSyncContract.almacenSelect)
        .eq('activo', true)
        .order('nombre');
  }

  Future<List<dynamic>> obtenerProveedoresDirecto() async {
    return await _client
        .from('proveedores')
        .select(AlmacenSyncContract.proveedorSelect)
        .order('nombre');
  }

  Future<void> guardarAlmacen(
    String nombre,
    bool sucursal, {
    int? id,
    String? direccion,
    String? ubigeo,
    String? departamento,
    String? provincia,
    String? distrito,
    String? codLocal,
    String? referencia,
  }) async {
    await _requireAdmin();
    final values = <String, dynamic>{
      'nombre': nombre.trim(),
      'direccion': _nullIfEmpty(direccion),
      'ubigeo': _nullIfEmpty(ubigeo),
      'departamento': _nullIfEmpty(departamento)?.toUpperCase(),
      'provincia': _nullIfEmpty(provincia)?.toUpperCase(),
      'distrito': _nullIfEmpty(distrito)?.toUpperCase(),
      'cod_local': _nullIfEmpty(codLocal) ?? '0000',
      'referencia': _nullIfEmpty(referencia),
      'activo': true,
    };

    if (id == null) {
      await _client.from('almacenes').insert(values);
    } else {
      await _client.from('almacenes').update(values).eq('id', id);
    }
    await sincronizarConSupabase();
  }

  String? _nullIfEmpty(String? value) {
    final text = value?.trim() ?? '';
    return text.isEmpty ? null : text;
  }

  Future<void> actualizarPesoProducto({
    required int productoId,
    required double pesoKg,
    String? unidadGre,
  }) async {
    await _requireAdmin();
    await _client
        .from('productos')
        .update({
          'peso_kg': pesoKg,
          if (unidadGre != null && unidadGre.trim().isNotEmpty)
            'unidad_gre': unidadGre.trim().toUpperCase(),
        })
        .eq('id', productoId);

    await sincronizarProductoLocal(productoId);
  }

  Future<Map<String, dynamic>> registrarMovimientoStock({
    required String requestId,
    required int productoId,
    required int cantidad,
    required int origenId,
    required int? destinoId,
    required bool esMerma,
    required String motivo,
  }) async {
    final Map<String, dynamic> resultado;

    if (esMerma) {
      resultado = await InventarioService.registrarMerma(
        requestId: requestId,
        productoId: productoId,
        almacenId: origenId,
        cantidad: cantidad.toDouble(),
        motivo: motivo,
      );
    } else {
      if (destinoId == null) {
        throw ArgumentError(
          'El almacén de destino es obligatorio para un traslado.',
        );
      }

      resultado = await InventarioService.trasladarStock(
        requestId: requestId,
        productoId: productoId,
        origenId: origenId,
        destinoId: destinoId,
        cantidad: cantidad.toDouble(),
        motivo: motivo,
      );
    }

    await sincronizarProductoLocal(productoId);
    sincronizarConSupabase();
    return resultado;
  }

  Future<String> subirImagenProducto(dynamic imagenFile) async {
    final context = await _tenantContext();
    final organizationId = context['organization_id']?.toString().trim() ?? '';
    if (organizationId.isEmpty) {
      throw StateError('No se pudo resolver la empresa activa.');
    }
    final fileName =
        '$organizationId/products/producto_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await _client.storage
        .from('imagenes_productos')
        .upload(fileName, imagenFile);
    return _client.storage.from('imagenes_productos').getPublicUrl(fileName);
  }

  Future<int> guardarProductoNuevoOEditado(
    Map<String, dynamic> data, {
    int? id,
    bool actualizarApertura = false,
  }) async {
    await _requireAdmin();
    int idGenerado;

    if (id == null) {
      final response = await _client
          .from('productos')
          .insert(data)
          .select()
          .single();
      idGenerado = (response['id'] as num).toInt();
    } else {
      final raw = await _client.rpc(
        'actualizar_producto_seguro_v1',
        params: {
          'p_producto_id': id,
          'p_datos': data,
          'p_actualizar_apertura': actualizarApertura,
        },
      );

      if (raw is! Map) {
        throw StateError(
          'actualizar_producto_seguro_v1 devolvió una respuesta inválida.',
        );
      }
      idGenerado = id;
    }

    await sincronizarProductoLocal(idGenerado);
    return idGenerado;
  }

  Future<int> crearProductoConStock(
    String requestId,
    Map<String, dynamic> datosProducto,
    List<Map<String, dynamic>> stocksIniciales,
  ) async {
    await _requireAdmin();
    final response = await _client.rpc(
      'crear_producto_con_stock',
      params: {
        'p_request_id': requestId,
        'p_datos_producto': datosProducto,
        'p_stocks': stocksIniciales,
      },
    );

    if (response == null || response['success'] != true) {
      throw Exception('Fallo al crear producto transaccionalmente: $response');
    }

    final idGenerado = (response['producto_id'] as num).toInt();
    await sincronizarProductoLocal(idGenerado);
    return idGenerado;
  }
}
