abstract interface class DocumentDataGateway {
  Future<int> resolverCliente({
    required String ruc,
    required String nombre,
    required String direccion,
  });

  Future<List<Map<String, dynamic>>> cargarClientes();

  Future<Map<String, dynamic>?> consultarPersona({
    required String numero,
    required String tipo,
  });
}

class DocumentLookupException implements Exception {
  const DocumentLookupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Fachada neutral usada por widgets compartidos de `core`.
/// La implementación Supabase se conecta desde el composition root.
class DocumentDataAccess {
  DocumentDataAccess._();

  static DocumentDataGateway? _gateway;

  static void configure(DocumentDataGateway gateway) {
    _gateway = gateway;
  }

  static DocumentDataGateway get gateway {
    final current = _gateway;
    if (current == null) {
      throw StateError('DocumentDataGateway no fue configurado.');
    }
    return current;
  }
}
