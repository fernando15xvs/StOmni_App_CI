import 'dart:convert';
import 'dart:developer' as developer;

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/models/producto_busqueda.dart';
import '../domain/producto.dart';
import 'producto_mapper.dart';

final localDbServiceProvider = Provider<LocalDbService>((ref) {
  return LocalDbService();
});

class LocalDbService {
  static Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDB('ferreteria_cache_v4.db');
    return _db!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 10,
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE almacenes ADD COLUMN direccion TEXT');
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE productos ADD COLUMN created_at TEXT');
    }
    if (oldVersion < 4) {
      await db.execute(
        'ALTER TABLE productos ADD COLUMN activo INTEGER DEFAULT 1',
      );
    }
    if (oldVersion < 5) {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_productos_nombre ON productos(nombre)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_productos_codigo_barras ON productos(codigo_barras)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_productos_activo ON productos(activo)',
      );
    }
    if (oldVersion < 6) {
      await db.execute('ALTER TABLE productos ADD COLUMN codigo TEXT');
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_productos_codigo ON productos(codigo)',
      );
    }
    if (oldVersion < 7) {
      await db.execute(
        'ALTER TABLE productos ADD COLUMN peso_kg REAL DEFAULT 0',
      );
      await db.execute(
        "ALTER TABLE productos ADD COLUMN unidad_gre TEXT DEFAULT 'NIU'",
      );
      await db.execute('ALTER TABLE almacenes ADD COLUMN ubigeo TEXT');
      await db.execute('ALTER TABLE almacenes ADD COLUMN departamento TEXT');
      await db.execute('ALTER TABLE almacenes ADD COLUMN provincia TEXT');
      await db.execute('ALTER TABLE almacenes ADD COLUMN distrito TEXT');
      await db.execute(
        "ALTER TABLE almacenes ADD COLUMN cod_local TEXT DEFAULT '0000'",
      );
      await db.execute('ALTER TABLE almacenes ADD COLUMN referencia TEXT');
      await db.execute('ALTER TABLE almacenes ADD COLUMN updated_at TEXT');
    }
    if (oldVersion < 8) {
      try {
        await db.execute(
          'ALTER TABLE productos ADD COLUMN stock_minimo INTEGER DEFAULT 0',
        );
      } catch (e) {
        // Ignorar si la columna ya existe en SQLite
      }
    }
    if (oldVersion < 9) {
      await db.execute(
        'ALTER TABLE productos ADD COLUMN unit_configuration TEXT',
      );
    }
    if (oldVersion < 10) {
      await db.execute(
        "ALTER TABLE productos ADD COLUMN item_type TEXT NOT NULL DEFAULT 'stock_product'",
      );
      await db.execute(
        'ALTER TABLE productos ADD COLUMN es_servicio INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        "UPDATE productos SET item_type='service', es_servicio=1 WHERE lower(trim(coalesce(unidad_medida,'')))='servicios'",
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_productos_item_type ON productos(item_type)',
      );
    }
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE productos (
        id INTEGER PRIMARY KEY,
        codigo TEXT,
        nombre TEXT,
        codigo_barras TEXT,
        descripcion TEXT,
        precio_unidad REAL,
        precio_caja REAL,
        precio_compra REAL,
        unidad_medida TEXT,
        cantidad_por_caja INTEGER,
        tipo_venta TEXT,
        categoria TEXT,
        proveedor_id INTEGER,
        permitir_sin_stock INTEGER,
        imagen_path TEXT,
        peso_kg REAL DEFAULT 0,
        unidad_gre TEXT DEFAULT 'NIU',
        inventario_almacen TEXT,
        created_at TEXT,
        activo INTEGER DEFAULT 1,
        unit_configuration TEXT,
        stock_minimo INTEGER DEFAULT 0,
        item_type TEXT NOT NULL DEFAULT 'stock_product',
        es_servicio INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE almacenes (
        id INTEGER PRIMARY KEY,
        nombre TEXT,
        direccion TEXT,
        ubigeo TEXT,
        departamento TEXT,
        provincia TEXT,
        distrito TEXT,
        cod_local TEXT DEFAULT '0000',
        referencia TEXT,
        updated_at TEXT,
        activo INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE proveedores (
        id INTEGER PRIMARY KEY,
        nombre TEXT
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_productos_nombre ON productos(nombre)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_productos_codigo ON productos(codigo)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_productos_codigo_barras ON productos(codigo_barras)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_productos_activo ON productos(activo)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_productos_item_type ON productos(item_type)',
    );
  }

  // --- PRODUCTOS ---

  Future<void> insertarProductosBatch(
    List<Map<String, dynamic>> productos,
  ) async {
    final db = await database;
    final batch = db.batch();

    // Usamos DELETE en lugar de TRUNCATE
    batch.delete('productos');

    for (var p in productos) {
      // Aseguramos que inventario_almacen sea un string JSON
      final mapToInsert = Map<String, dynamic>.from(p);
      if (mapToInsert['inventario_almacen'] != null) {
        mapToInsert['inventario_almacen'] = jsonEncode(
          mapToInsert['inventario_almacen'],
        );
      }
      if (mapToInsert['permitir_sin_stock'] != null) {
        mapToInsert['permitir_sin_stock'] =
            (mapToInsert['permitir_sin_stock'] == true) ? 1 : 0;
      }
      if (mapToInsert['es_servicio'] != null) {
        mapToInsert['es_servicio'] =
            (mapToInsert['es_servicio'] == true) ? 1 : 0;
      }
      if (mapToInsert['activo'] != null) {
        mapToInsert['activo'] = (mapToInsert['activo'] == true) ? 1 : 0;
      }

      if (mapToInsert['unit_configuration'] != null) {
        mapToInsert['unit_configuration'] = jsonEncode(
          mapToInsert['unit_configuration'],
        );
      }
      // Sanitizar valores null que podrían causar problemas
      mapToInsert.removeWhere((key, value) => value == null);

      batch.insert(
        'productos',
        mapToInsert,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> upsertProductoUnico(Map<String, dynamic> p) async {
    final db = await database;
    final mapToInsert = Map<String, dynamic>.from(p);
    if (mapToInsert['inventario_almacen'] != null) {
      mapToInsert['inventario_almacen'] = jsonEncode(
        mapToInsert['inventario_almacen'],
      );
    }
    if (mapToInsert['permitir_sin_stock'] != null) {
      mapToInsert['permitir_sin_stock'] =
          (mapToInsert['permitir_sin_stock'] == true) ? 1 : 0;
    }
    if (mapToInsert['es_servicio'] != null) {
      mapToInsert['es_servicio'] =
          (mapToInsert['es_servicio'] == true) ? 1 : 0;
    }
    if (mapToInsert['activo'] != null) {
      mapToInsert['activo'] = (mapToInsert['activo'] == true) ? 1 : 0;
    }
    if (mapToInsert['unit_configuration'] != null) {
      mapToInsert['unit_configuration'] = jsonEncode(
        mapToInsert['unit_configuration'],
      );
    }
    mapToInsert.removeWhere((key, value) => value == null);

    await db.insert(
      'productos',
      mapToInsert,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Elimina inmediatamente un producto del caché local.
  ///
  /// La eliminación remota ya fue validada y ejecutada por PostgreSQL mediante
  /// `eliminar_producto_seguro_v1`. Esto evita que el producto siga apareciendo
  /// en SQLite hasta la siguiente sincronización completa.
  Future<void> eliminarProductoPorId(int productoId) async {
    final db = await database;
    await db.delete('productos', where: 'id = ?', whereArgs: [productoId]);
  }

  Future<List<Producto>> getProductosOnline({
    required int start,
    required int end,
    required String orderColumn,
    required bool ascending,
  }) async {
    final db = await database;

    final limit = end - start + 1;
    final offset = start;

    final orderBy = '$orderColumn ${ascending ? 'ASC' : 'DESC'}';

    final result = await db.query(
      'productos',
      where: 'activo = 1',
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );

    return result.map((json) => _rowToProducto(json)).toList();
  }

  Future<List<Producto>> buscarProductos(String query) async {
    final db = await database;

    final result = await db.query(
      'productos',
      where:
          'activo = 1 AND (nombre LIKE ? OR codigo LIKE ? OR codigo_barras LIKE ?)',
      whereArgs: ['%$query%', '%$query%', '%$query%'],
      orderBy: 'nombre ASC',
    );

    return result.map((json) => _rowToProducto(json)).toList();
  }

  /// Permite saber si existe catálogo local sin abusar de una búsqueda vacía.
  Future<bool> tieneProductosEnCache({bool incluirInactivos = false}) async {
    final db = await database;
    final where = incluirInactivos ? '' : ' WHERE activo = 1';
    final count = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM productos$where'),
        ) ??
        0;
    return count > 0;
  }

  Future<List<ProductoBusqueda>> buscarProductosRapido(
    String query, {
    bool incluirInactivos = false,
  }) async {
    final db = await database;

    final queryTrimmed = query.trim();
    if (queryTrimmed.isEmpty) return [];

    final isActiveFilter = incluirInactivos ? "" : "AND p.activo = 1";

    final sql =
        '''
      SELECT p.*, pr.nombre as proveedor_nombre
      FROM productos p
      LEFT JOIN proveedores pr ON p.proveedor_id = pr.id
      WHERE (p.nombre LIKE ? OR p.codigo LIKE ? OR p.codigo_barras LIKE ?)
      $isActiveFilter
      ORDER BY 
        CASE 
          WHEN p.codigo = ? OR p.codigo_barras = ? THEN 1 
          WHEN p.nombre LIKE ? THEN 2
          WHEN p.nombre LIKE ? THEN 3
          ELSE 4 
        END ASC,
        p.nombre ASC
      LIMIT 30
    ''';

    final result = await db.rawQuery(sql, [
      '%$queryTrimmed%',
      '%$queryTrimmed%',
      '%$queryTrimmed%',
      queryTrimmed,
      queryTrimmed,
      queryTrimmed,
      '$queryTrimmed%',
    ]);

    final List<ProductoBusqueda> list = [];
    for (var row in result) {
      try {
        list.add(ProductoBusqueda.fromMap(Map<String, dynamic>.from(row)));
      } catch (e) {
        developer.log(
          "Error parseando producto desde SQLite (ID: ${row['id']}): $e",
          name: 'LocalDbService',
        );
      }
    }
    return list;
  }

  Producto _rowToProducto(Map<String, Object?> row) {
    final map = Map<String, dynamic>.from(row);
    if (map['inventario_almacen'] != null) {
      map['inventario_almacen'] = jsonDecode(
        map['inventario_almacen'] as String,
      );
    }
    if (map['permitir_sin_stock'] != null) {
      map['permitir_sin_stock'] = map['permitir_sin_stock'] == 1;
    }
    if (map['es_servicio'] != null) {
      map['es_servicio'] = map['es_servicio'] == 1;
    }
    return ProductoMapper.decode(map);
  }

  // --- almacenes Y PROVEEDORES ---

  Future<void> insertaralmacenes(List<Map<String, dynamic>> almacenes) async {
    final db = await database;
    final batch = db.batch();
    batch.delete('almacenes');
    const columnasPermitidas = {
      'id',
      'nombre',
      'direccion',
      'ubigeo',
      'departamento',
      'provincia',
      'distrito',
      'cod_local',
      'referencia',
      'updated_at',
      'activo',
    };

    for (var a in almacenes) {
      final mapToInsert = Map<String, dynamic>.from(a)
        ..removeWhere((key, _) => !columnasPermitidas.contains(key));
      if (mapToInsert['activo'] != null) {
        mapToInsert['activo'] = (mapToInsert['activo'] == true) ? 1 : 0;
      }
      batch.insert(
        'almacenes',
        mapToInsert,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, dynamic>>> getalmacenes() async {
    final db = await database;
    final result = await db.query(
      'almacenes',
      where: 'activo = 1',
      orderBy: 'id ASC',
    );
    return result.map((e) {
      final map = Map<String, dynamic>.from(e);
      map['activo'] = map['activo'] == 1;
      return map;
    }).toList();
  }

  Future<void> insertarProveedores(
    List<Map<String, dynamic>> proveedores,
  ) async {
    final db = await database;
    final batch = db.batch();
    batch.delete('proveedores');
    for (var p in proveedores) {
      batch.insert(
        'proveedores',
        p,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<Map<int, String>> getMarcas() async {
    final db = await database;
    final result = await db.query('proveedores', columns: ['id', 'nombre']);
    final Map<int, String> marcas = {};
    for (var item in result) {
      marcas[item['id'] as int] = item['nombre'] as String;
    }
    return marcas;
  }
}