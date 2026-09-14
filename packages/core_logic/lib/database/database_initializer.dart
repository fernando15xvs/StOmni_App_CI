import 'database_initializer_stub.dart'
    if (dart.library.io) 'database_initializer_io.dart' as platform;

/// Inicializa únicamente la infraestructura de base de datos que corresponde
/// a la plataforma actual.
///
/// En Web usa una implementación vacía para evitar importar `dart:io` o FFI.
Future<void> initializeDatabaseForPlatform() {
  return platform.initializeDatabaseForPlatform();
}
