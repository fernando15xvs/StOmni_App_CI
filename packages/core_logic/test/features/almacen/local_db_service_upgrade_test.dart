import 'package:core_logic/features/almacen/data/local_db_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test(
    'upgrade SQLite tolera unit_configuration ya existente',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;

      final databasesPath = await getDatabasesPath();
      final dbPath = join(databasesPath, 'ferreteria_cache_v4.db');
      await deleteDatabase(dbPath);
      addTearDown(() async => deleteDatabase(dbPath));

      final legacyDb = await openDatabase(
        dbPath,
        version: 8,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE productos (
              id INTEGER PRIMARY KEY,
              unidad_medida TEXT,
              unit_configuration TEXT
            )
          ''');
        },
      );
      await legacyDb.close();

      final service = LocalDbService();
      final upgradedDb = await service.database;

      expect(await upgradedDb.getVersion(), 10);

      final columns = await upgradedDb.rawQuery('PRAGMA table_info(productos)');
      final names = columns.map((row) => row['name']).toList();

      expect(
        names.where((name) => name == 'unit_configuration'),
        hasLength(1),
      );
      expect(names, contains('item_type'));
      expect(names, contains('es_servicio'));

      await upgradedDb.close();
    },
  );
}
