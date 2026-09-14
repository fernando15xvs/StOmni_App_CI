import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:core_logic/core_logic.dart';

/// Expone el [DocumentDataGateway] configurado en el Composition Root
/// como un provider de Riverpod.
///
/// La implementación concreta (Supabase) se registra en
/// `app_dependencies.dart` mediante [DocumentDataAccess.configure].
/// Este provider es el punto único de acceso reactivo al gateway para
/// cualquier widget de la capa de presentación.
final documentDataGatewayProvider = Provider<DocumentDataGateway>((ref) {
  return DocumentDataAccess.gateway;
});
